// Yahoo Finance (unofficial v8 chart + v1 search). No key. The only working source for many
// non-US listings. Quirks handled here (see the repo CLAUDE.md "APIs" table):
//   * London quotes come in pence ("GBp"), Johannesburg in cents ("ZAc"), Tel Aviv in agorot
//     ("ILA"): normalised to the major unit;
//   * a throttled search answers 200 without a `quotes` key (a real no-match is `[]`), and
//     sometimes a real ticker comes back empty — both are re-asked on query2;
//   * bars can contain nulls (no trades in the interval): dropped, never filled in.

import { type Instrument, parseYahooSymbol, yahooSymbol, type Venue } from "../../../../supabase/functions/_shared/trading/market.ts";
import type { CandleView, ChartRange, VolumeScope } from "@/lib/market-types";
import { getJSON, UpstreamError } from "./http.ts";

const HOSTS = ["https://query1.finance.yahoo.com", "https://query2.finance.yahoo.com"];
export const YAHOO_SOURCE = "Yahoo Finance (unofficial)";
/** The symbol Yahoo knows this listing by, including its exchange or quote currency suffix. */
export const yahooTicker = (instrument: Instrument) => instrument.venue === "crypto" ? `${instrument.symbol}-USD` : yahooSymbol(instrument);

const MINOR_UNITS: Record<string, { major: string; divisor: number }> = {
  GBp: { major: "GBP", divisor: 100 },
  GBX: { major: "GBP", divisor: 100 },
  ZAc: { major: "ZAR", divisor: 100 },
  ILA: { major: "ILS", divisor: 100 },
};

export function normaliseCurrency(currency: string | undefined): { currency: string | undefined; divisor: number } {
  if (!currency) return { currency: undefined, divisor: 1 };
  const minor = MINOR_UNITS[currency];
  return minor ? { currency: minor.major, divisor: minor.divisor } : { currency: currency.toUpperCase(), divisor: 1 };
}

interface ChartMeta {
  symbol?: string;
  currency?: string;
  regularMarketPrice?: number;
  regularMarketTime?: number;
  chartPreviousClose?: number;
  previousClose?: number;
  regularMarketDayHigh?: number;
  regularMarketDayLow?: number;
  regularMarketVolume?: number;
  exchangeDataDelayedBy?: number;
  exchangeName?: string;
  fullExchangeName?: string;
  instrumentType?: string;
  longName?: string;
  shortName?: string;
}

interface ChartResult {
  meta: ChartMeta;
  timestamp?: number[];
  indicators?: {
    quote?: { open?: (number | null)[]; high?: (number | null)[]; low?: (number | null)[]; close?: (number | null)[]; volume?: (number | null)[] }[];
  };
}

export interface YahooChart {
  meta: ChartMeta;
  currency?: string;
  candles: CandleView[];
  /** Minutes Yahoo says the exchange feed is delayed by; undefined when it doesn't say. */
  delayMinutes?: number;
}

const INTERVALS: Record<ChartRange, { range: string; interval: string }> = {
  "1D": { range: "1d", interval: "5m" },
  "5D": { range: "5d", interval: "15m" },
  "1M": { range: "1mo", interval: "60m" },
  "3M": { range: "3mo", interval: "1d" },
  "6M": { range: "6mo", interval: "1d" },
  "1Y": { range: "1y", interval: "1d" },
  "5Y": { range: "5y", interval: "1wk" },
};

export function yahooInterval(range: ChartRange, crypto: boolean): { range: string; interval: string } {
  // Crypto "1D" means the trailing 24 hours, not since UTC midnight.
  if (crypto && range === "1D") return { range: "2d", interval: "5m" };
  return INTERVALS[range];
}

async function chart(ticker: string, query: URLSearchParams): Promise<ChartResult> {
  let lastError: unknown;
  for (const host of HOSTS) {
    const url = `${host}/v8/finance/chart/${encodeURIComponent(ticker)}?${query}`;
    try {
      const body = (await getJSON(url, { label: "Yahoo Finance" })) as { chart?: { result?: ChartResult[] | null; error?: { description?: string } | null } };
      const result = body.chart?.result?.[0];
      if (!result || !result.meta) {
        throw new UpstreamError(body.chart?.error?.description ? `Yahoo Finance: ${body.chart.error.description}` : "Yahoo Finance has no chart for that", 404);
      }
      return result;
    } catch (error) {
      lastError = error;
      // A 404 "no data" is an answer, not a hiccup: don't ask the second host.
      if (error instanceof UpstreamError && error.status === 404) throw error;
    }
  }
  throw lastError instanceof Error ? lastError : new UpstreamError("Yahoo Finance couldn't be reached");
}

function chartRange(range: string, interval: string) {
  return new URLSearchParams({ range, interval, includePrePost: "false", events: "div,splits" });
}


export async function yahooChart(instrument: Instrument, range: ChartRange): Promise<YahooChart> {
  const { range: r, interval } = yahooInterval(range, instrument.venue === "crypto");
  const result = await chart(yahooTicker(instrument), chartRange(r, interval));
  const { currency, divisor } = normaliseCurrency(result.meta.currency);
  const ts = result.timestamp ?? [];
  const q = result.indicators?.quote?.[0] ?? {};
  const candles: CandleView[] = [];
  for (let i = 0; i < ts.length; i++) {
    const o = q.open?.[i], h = q.high?.[i], l = q.low?.[i], c = q.close?.[i], v = q.volume?.[i];
    if (o == null || h == null || l == null || c == null) continue;
    if (!(o > 0 && h > 0 && l > 0 && c > 0) || h < l) continue;
    candles.push({ time: ts[i], open: o / divisor, high: h / divisor, low: l / divisor, close: c / divisor, volume: v != null && v >= 0 ? v : 0 });
  }
  // Yahoo occasionally repeats the last timestamp for the live bar.
  const deduped: CandleView[] = [];
  for (const c of candles) {
    if (deduped.length > 0 && deduped[deduped.length - 1].time === c.time) deduped[deduped.length - 1] = c;
    else if (deduped.length === 0 || c.time > deduped[deduped.length - 1].time) deduped.push(c);
  }
  let trimmed = deduped;
  if (instrument.venue === "crypto" && range === "1D" && deduped.length > 0) {
    const cutoff = deduped[deduped.length - 1].time - 24 * 3600;
    trimmed = deduped.filter((c) => c.time >= cutoff);
  }
  const delay = result.meta.exchangeDataDelayedBy;
  return { meta: result.meta, currency, candles: trimmed, delayMinutes: typeof delay === "number" ? delay : undefined };
}

export interface YahooQuote {
  last: number;
  previousClose?: number;
  dayHigh?: number;
  dayLow?: number;
  volume?: number;
  currency?: string;
  observedAt: number;
  delayMinutes?: number;
  name?: string;
  isEtf: boolean;
}

export async function yahooQuote(instrument: Instrument): Promise<YahooQuote> {
  // range=1d: the previous close is yesterday's (5d gave a 5-day "daily" change).
  const result = await chart(yahooTicker(instrument), chartRange("1d", "5m"));
  const m = result.meta;
  if (typeof m.regularMarketPrice !== "number" || !(m.regularMarketPrice > 0) || typeof m.regularMarketTime !== "number") {
    throw new UpstreamError("Yahoo Finance has no current price for that", 404);
  }
  const { currency, divisor } = normaliseCurrency(m.currency);
  const prev = m.chartPreviousClose ?? m.previousClose;
  return {
    last: m.regularMarketPrice / divisor,
    previousClose: typeof prev === "number" && prev > 0 ? prev / divisor : undefined,
    dayHigh: typeof m.regularMarketDayHigh === "number" ? m.regularMarketDayHigh / divisor : undefined,
    dayLow: typeof m.regularMarketDayLow === "number" ? m.regularMarketDayLow / divisor : undefined,
    volume: typeof m.regularMarketVolume === "number" ? m.regularMarketVolume : undefined,
    currency,
    observedAt: m.regularMarketTime * 1000,
    delayMinutes: typeof m.exchangeDataDelayedBy === "number" ? m.exchangeDataDelayedBy : undefined,
    name: m.longName ?? m.shortName,
    isEtf: m.symbol?.toUpperCase() === yahooTicker(instrument) && m.instrumentType === "ETF",
  };
}

export function yahooVolumeScope(instrument: Instrument): VolumeScope {
  return instrument.venue === "crypto" ? "aggregate" : "consolidated";
}

// MARK: - Search

interface SearchQuote {
  symbol?: string;
  shortname?: string;
  longname?: string;
  quoteType?: string;
  exchange?: string;
  exchDisp?: string;
}

const US_EXCHANGES = new Set(["NMS", "NGM", "NCM", "NYQ", "ASE", "PCX", "BTS", "NAS", "NYS", "PNK", "CBOE", "BATS"]);

export interface YahooSearchHit {
  symbol: string;
  venue: Venue;
  name: string;
  assetClass: "equity" | "etf" | "crypto";
  exchangeLabel?: string;
}

export async function yahooSearch(query: string): Promise<YahooSearchHit[]> {
  let lastError: unknown;
  for (const host of HOSTS) {
    const url = `${host}/v1/finance/search?q=${encodeURIComponent(query)}&quotesCount=15&newsCount=0&listsCount=0&enableFuzzyQuery=false`;
    try {
      const body = (await getJSON(url, { label: "Yahoo search" })) as { quotes?: SearchQuote[] };
      if (!Array.isArray(body.quotes)) {
        lastError = new UpstreamError("Yahoo search is throttled right now", 429, true);
        continue;
      }
      const hits = mapSearch(body.quotes);
      if (hits.length === 0 && host === HOSTS[0]) {
        // A real ticker sometimes comes back empty from query1; ask query2 before "no matches".
        lastError = undefined;
        continue;
      }
      return hits;
    } catch (error) {
      lastError = error;
    }
  }
  if (lastError) throw lastError;
  return [];
}

function mapSearch(quotes: SearchQuote[]): YahooSearchHit[] {
  const out: YahooSearchHit[] = [];
  for (const q of quotes) {
    if (!q.symbol) continue;
    const name = q.longname ?? q.shortname ?? q.symbol;
    const type = q.quoteType;
    if (type === "CRYPTOCURRENCY") {
      const m = /^([A-Z0-9]{2,10})-USD$/.exec(q.symbol.toUpperCase());
      if (m) out.push({ symbol: m[1], venue: "crypto", name: name.replace(/ USD$/, ""), assetClass: "crypto", exchangeLabel: "Crypto" });
      continue;
    }
    if (type !== "EQUITY" && type !== "ETF") continue;
    const assetClass = type === "ETF" ? "etf" : "equity";
    const parsed = parseYahooSymbol(q.symbol);
    if (parsed) {
      out.push({ symbol: parsed.symbol, venue: parsed.venue, name, assetClass, exchangeLabel: q.exchDisp });
      continue;
    }
    if (!q.symbol.includes(".") && q.exchange && US_EXCHANGES.has(q.exchange)) {
      out.push({ symbol: q.symbol.toUpperCase(), venue: "us", name, assetClass, exchangeLabel: q.exchDisp });
    }
    // Other exchanges (Toronto, São Paulo, ...) aren't venues the engine knows: left out
    // rather than guessed.
  }
  return out;
}
