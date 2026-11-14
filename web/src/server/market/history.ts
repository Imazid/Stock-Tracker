// Longer price histories for backtests: daily bars (up to 10 years) or hourly bars (Yahoo
// serves ~730 days of 60-minute bars). Bars come back as the engine's BarSeries with
// `market` provenance — the backtester refuses anything else — plus a dataset reference
// (source, window, bar count, SHA-256 of the bars) so a result can be traced to its data.

import { sha256Hex } from "@engine/sha256.ts";
import { type Bar, type BarSeries, type Instrument, instrumentID, makeBarSeries, marketProvenance, type Timeframe } from "@engine/market.ts";
import { ALPACA_CRYPTO_SOURCE, ALPACA_IEX_SOURCE, alpacaSupports } from "./alpaca";
import { cached } from "./cache";
import { getJSON, UpstreamError } from "./http";
import { normaliseCurrency, YAHOO_SOURCE, yahooTicker } from "./yahoo";

export type HistoryWindow = "1y" | "2y" | "5y" | "10y";
export const HISTORY_WINDOWS: HistoryWindow[] = ["1y", "2y", "5y", "10y"];

export interface DatasetReference {
  instrumentId: string;
  source: string;
  timeframe: Timeframe;
  window: string;
  bars: number;
  firstBar?: string;
  lastBar?: string;
  currency: string;
  /** SHA-256 over the bars exactly as passed to the backtester. */
  sha256: string;
  fetchedAt: string;
  volumeIsMarketWide: boolean;
}

async function yahooBars(instrument: Instrument, timeframe: Timeframe, start: number, end: number): Promise<{ bars: Bar[]; currency?: string }> {
  // Hourly history is limited upstream to ~2 years.
  const interval = timeframe === "hour" ? "60m" : "1d";
  let lastError: unknown;
  for (const host of ["https://query1.finance.yahoo.com", "https://query2.finance.yahoo.com"]) {
    try {
      const body = (await getJSON(`${host}/v8/finance/chart/${encodeURIComponent(yahooTicker(instrument))}?period1=${Math.floor(start / 1000)}&period2=${Math.floor(end / 1000)}&interval=${interval}&includePrePost=false&events=div%2Csplits`,
        { label: "Yahoo Finance", timeoutMs: 15_000 })) as {
        chart?: { result?: { meta?: { currency?: string }; timestamp?: number[]; indicators?: { quote?: { open?: (number | null)[]; high?: (number | null)[]; low?: (number | null)[]; close?: (number | null)[]; volume?: (number | null)[] }[] } }[] | null };
      };
      const result = body.chart?.result?.[0];
      if (!result) throw new UpstreamError("Yahoo Finance has no history for that", 404);
      const { currency, divisor } = normaliseCurrency(result.meta?.currency);
      const ts = result.timestamp ?? [];
      const q = result.indicators?.quote?.[0] ?? {};
      const bars: Bar[] = [];
      for (let i = 0; i < ts.length; i++) {
        const o = q.open?.[i], h = q.high?.[i], l = q.low?.[i], c = q.close?.[i], v = q.volume?.[i];
        if (o == null || h == null || l == null || c == null) continue;
        bars.push({ time: ts[i] * 1000, open: o / divisor, high: h / divisor, low: l / divisor, close: c / divisor, volume: v != null && v >= 0 ? v : 0 });
      }
      return { bars, currency };
    } catch (error) {
      lastError = error;
      if (error instanceof UpstreamError && error.status === 404) throw error;
    }
  }
  throw lastError instanceof Error ? lastError : new UpstreamError("Yahoo Finance couldn't be reached");
}

async function alpacaBars(instrument: Instrument, timeframe: Timeframe, start: number, end: number): Promise<Bar[]> {
  const tf = timeframe === "hour" ? "1Hour" : "1Day";
  const headers = { "APCA-API-KEY-ID": process.env.ALPACA_DATA_KEY_ID ?? "", "APCA-API-SECRET-KEY": process.env.ALPACA_DATA_SECRET ?? "" };
  const out: Bar[] = [];
  let token: string | undefined;
  for (let page = 0; page < 20; page++) {
    const pair = `${instrument.symbol}/USD`;
    const bounds = `start=${encodeURIComponent(new Date(start).toISOString())}&end=${encodeURIComponent(new Date(end).toISOString())}`;
    let url = instrument.venue === "crypto"
      ? `https://data.alpaca.markets/v1beta3/crypto/us/bars?symbols=${encodeURIComponent(pair)}&timeframe=${tf}&${bounds}&limit=10000&sort=asc`
      : `https://data.alpaca.markets/v2/stocks/${encodeURIComponent(instrument.symbol)}/bars?timeframe=${tf}&${bounds}&feed=iex&adjustment=all&limit=10000&sort=asc`;
    if (token) url += `&page_token=${encodeURIComponent(token)}`;
    const body = (await getJSON(url, { label: "Alpaca", headers, timeoutMs: 15_000 })) as { bars?: { t: string; o: number; h: number; l: number; c: number; v: number }[] | Record<string, { t: string; o: number; h: number; l: number; c: number; v: number }[]> | null; next_page_token?: string | null };
    const list = Array.isArray(body.bars) ? body.bars : body.bars?.[pair] ?? [];
    for (const b of list) out.push({ time: Date.parse(b.t), open: b.o, high: b.h, low: b.l, close: b.c, volume: b.v });
    token = body.next_page_token ?? undefined;
    if (!token) break;
  }
  return out;
}

export function datasetReference(series: BarSeries, window: string): DatasetReference {
  const bars = series.bars;
  return {
    instrumentId: instrumentID(series.instrument),
    source: series.provenance.source,
    timeframe: series.timeframe,
    window,
    bars: bars.length,
    firstBar: bars[0] ? new Date(bars[0].time).toISOString() : undefined,
    lastBar: bars.length ? new Date(bars[bars.length - 1].time).toISOString() : undefined,
    currency: series.instrument.currency,
    sha256: sha256Hex(JSON.stringify(bars.map((b) => [b.time, b.open, b.high, b.low, b.close, b.volume]))),
    fetchedAt: new Date(series.fetchedAt).toISOString(),
    volumeIsMarketWide: series.volumeIsMarketWide,
  };
}

/** Real history for one instrument, or an error with the reasons. Cached for 10 minutes. */
export async function history(instrument: Instrument, timeframe: Timeframe, window: HistoryWindow, asOf: number, now: number): Promise<BarSeries> {
  const day = 86_400_000;
  const start = Math.floor(asOf / day) * day - Number.parseInt(window, 10) * 366 * day;
  const end = Math.ceil(asOf / 60_000) * 60_000;
  return cached(`backtest-history:${instrumentID(instrument)}:${timeframe}:${start}:${end}`, 600_000, async () => {
    const reasons: string[] = [];
    try {
      const earliestYahooHour = now - 729 * day;
      const yahooStart = timeframe === "hour" ? Math.max(start, earliestYahooHour) : start;
      if (yahooStart >= end) throw new UpstreamError("Yahoo no longer serves hourly prices for this period");
      const { bars, currency } = await yahooBars(instrument, timeframe, yahooStart, Math.min(end, now));
      const ccy = currency ?? instrument.currency;
      if (ccy !== instrument.currency) throw new UpstreamError(`Yahoo prices this in ${ccy}, not ${instrument.currency}`);
      const series = makeBarSeries(instrument, timeframe, bars, marketProvenance(YAHOO_SOURCE, instrument.venue === "crypto" ? 0 : 900), now,
        instrument.venue !== "crypto");
      if (series.bars.length === 0) throw new UpstreamError("Yahoo Finance returned no bars", 404);
      return series;
    } catch (error) {
      reasons.push(`Yahoo: ${error instanceof UpstreamError ? error.message : "request failed"}`);
    }
    if (alpacaSupports(instrument)) {
      try {
        const source = instrument.venue === "crypto" ? ALPACA_CRYPTO_SOURCE : ALPACA_IEX_SOURCE;
        const series = makeBarSeries(instrument, timeframe, await alpacaBars(instrument, timeframe, start, Math.min(end, now)), marketProvenance(source, 0), now, false);
        if (series.bars.length === 0) throw new UpstreamError("Alpaca returned no bars", 404);
        return series;
      } catch (error) {
        reasons.push(`Alpaca: ${error instanceof UpstreamError ? error.message : "request failed"}`);
      }
    }
    throw new HistoryError(instrumentID(instrument), reasons);
  });
}

export class HistoryError extends Error {
  constructor(readonly instrumentId: string, readonly reasons: string[]) {
    super(`No price history for ${instrumentId}: ${reasons.join("; ")}`);
    this.name = "HistoryError";
  }
}
