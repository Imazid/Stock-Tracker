// Prices for the eleven exchanges outside the US (ASX, London, Xetra, Paris, Amsterdam,
// SIX, Tokyo, Hong Kong, Singapore, KRX, NSE) from Yahoo Finance's chart endpoint: daily
// bars and the latest regular-session price, in the listing's own currency.
//
// A port of the app's `exchangeChart`, `exchangeDailyBars`, `exchangeQuote`,
// `normalisedCurrency`, `delay` and `provenance` (Stock Tracker/TradingMarketData.swift),
// so the phone and the server read the same numbers the same way:
//   - one GET per instrument: /v8/finance/chart/<SYMBOL>?interval=1d&range=<range>;
//   - minor units are converted (London's pence "GBp"/"GBX" ÷ 100 → GBP);
//   - a listing whose currency (after that) isn't the instrument's is refused, never mixed;
//   - the quote's time is `regularMarketTime`; without it there is no quote;
//   - every bar and quote is labelled `market("Yahoo Finance (<SHORT>, <n> min delayed)")`
//     with the delay Yahoo states for that exchange, so the risk engine judges freshness
//     against the real age of the price;
//   - the volume is the home exchange's own, counted as market-wide (a conservative
//     figure: a stock that also trades elsewhere is undercounted, never overcounted).
//
// MARKET DATA ONLY: read-only GETs, no key, no account, nothing about orders. The clock is
// never read: `now` comes from the caller. Failures are reasons in `failures`, in plain
// English; nothing is estimated or carried forward.

import {
  type Bar, type Instrument, instrumentID, makeBarSeries, marketProvenance, type DataProvenance, type Quote, type Timeframe,
  type Venue, venueDisplayName, venueShortName, venueYahooSuffix, yahooSymbol,
} from "../trading/market.ts";
import {
  type BarsResult, failureReason, finiteNumber, isRecord, type MarketDataProvider, ProviderError, type QuotesResult, uniqueInstruments,
} from "./provider.ts";

export interface YahooFinanceProviderOptions {
  fetch?: typeof fetch;
  /** Default "https://query1.finance.yahoo.com" (a local stand-in is allowed for tests). */
  baseURL?: string;
  /** Per attempt. Default 8000, as for Alpaca. */
  timeoutMs?: number;
  /** Default 3, as for Alpaca. */
  maxAttempts?: number;
  /** Doubles after every failed attempt. Default 300, as for Alpaca. */
  backoffMs?: number;
  sleep?: (ms: number) => Promise<void>;
  /** Requests in flight at once. Default 4. */
  concurrency?: number;
  /** One small event per HTTP attempt: path, attempt, status, time. Never a query string. */
  log?: (event: Record<string, unknown>) => void;
}

const YAHOO_HOST = "https://query1.finance.yahoo.com";
const CHART_PATH = "/v8/finance/chart/";
const SOURCE = "Yahoo Finance";
/** Yahoo serves its public endpoints to browsers; the app sends the same header. */
const USER_AGENT = "Mozilla/5.0";
const MAX_RETRY_AFTER_MS = 5_000;

/** The venues with a Yahoo suffix, which this provider prices. */
export const YAHOO_VENUES: readonly Venue[] = ["asx", "lse", "xetra", "euronextParis", "euronextAmsterdam", "six", "tse", "hkex", "sgx", "krx", "nse"];

/** How far behind each exchange Yahoo's free data runs, as Yahoo states it (the app's `delay`). */
export function yahooDelaySeconds(venue: Venue): number {
  switch (venue) {
    case "nse": return 0;
    case "six": return 30 * 60;
    case "asx": case "tse": case "krx": return 20 * 60;
    default: return 15 * 60;
  }
}

/** The app's `provenance(_:)`. */
export function yahooProvenance(venue: Venue): DataProvenance {
  const delay = yahooDelaySeconds(venue);
  const label = delay > 0 ? `Yahoo Finance (${venueShortName(venue)}, ${delay / 60} min delayed)` : `Yahoo Finance (${venueShortName(venue)})`;
  return marketProvenance(label, delay);
}

/** Yahoo quotes London in pence and a few others in minor units: the major currency and the factor to it. */
export function normalisedCurrency(reported: string): { code: string; factor: number } {
  switch (reported) {
    case "GBp": case "GBX": return { code: "GBP", factor: 0.01 };
    case "ZAc": case "ZAC": return { code: "ZAR", factor: 0.01 };
    case "ILA": return { code: "ILS", factor: 0.01 };
    default: return { code: reported, factor: 1 };
  }
}

/** Tickers go into URLs, so only ticker characters survive (the app's `clean`). */
export function cleanSymbol(symbol: string): string {
  return [...symbol.toUpperCase()].filter((c) => /[A-Z0-9.\-]/.test(c)).slice(0, 12).join("");
}

/** The app's chart range for a bar count. */
export function chartRange(count: number): string {
  return count > 250 ? (count > 500 ? "5y" : "2y") : "1y";
}

const noPrices = (instrument: Instrument) => new ProviderError(`No prices came back for ${instrument.symbol}.`);

function chartResult(body: unknown) {
  const chart = isRecord(body) && isRecord(body.chart) ? body.chart : undefined;
  return chart && Array.isArray(chart.result) && isRecord(chart.result[0]) ? chart.result[0] : undefined;
}

interface Chart {
  result: Record<string, unknown>;
  factor: number;
}

export class YahooFinanceProvider implements MarketDataProvider {
  readonly name = "yahoo";
  readonly #fetch: typeof fetch;
  readonly #baseURL: string;
  readonly #timeoutMs: number;
  readonly #maxAttempts: number;
  readonly #backoffMs: number;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #concurrency: number;
  readonly #log?: (event: Record<string, unknown>) => void;

  constructor(options: YahooFinanceProviderOptions = {}) {
    this.#fetch = options.fetch ?? ((input, init) => fetch(input, init));
    this.#baseURL = checkedBaseURL(options.baseURL ?? YAHOO_HOST);
    this.#timeoutMs = atLeast(options.timeoutMs, 1, 8_000);
    this.#maxAttempts = Math.floor(atLeast(options.maxAttempts, 1, 3));
    this.#backoffMs = atLeast(options.backoffMs, 0, 300);
    this.#sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.#concurrency = Math.floor(atLeast(options.concurrency, 1, 4));
    this.#log = options.log;
  }

  supports(instrument: Instrument): boolean {
    return YAHOO_VENUES.includes(instrument.venue) && instrument.assetClass !== "crypto" && venueYahooSuffix(instrument.venue) !== undefined;
  }

  async adjustedCloses(instrument: Instrument, start: number, end: number) {
    const symbol = yahooSymbol(instrument);
    const body = await this.#get(`${CHART_PATH}${encodeURIComponent(symbol)}`, [
      ["period1", String(start / 1000)], ["period2", String(end / 1000)],
      ["interval", "1d"], ["includeAdjustedClose", "true"],
    ]);
    const result = chartResult(body);
    const meta = result && isRecord(result.meta) ? result.meta : undefined;
    if (!result || !meta || typeof meta.currency !== "string" || typeof meta.symbol !== "string") throw noPrices(instrument);
    const { code, factor } = normalisedCurrency(meta.currency);
    if (code !== instrument.currency || meta.symbol.toUpperCase() !== symbol) {
      throw new ProviderError("The benchmark listing or quote currency could not be verified");
    }
    const indicators = isRecord(result.indicators) ? result.indicators : undefined;
    const adjusted = Array.isArray(indicators?.adjclose) && isRecord(indicators.adjclose[0]) ? indicators.adjclose[0].adjclose : undefined;
    if (!Array.isArray(result.timestamp) || !Array.isArray(adjusted)) return [];
    return result.timestamp.flatMap((time, index) => {
      const close = finiteNumber(adjusted[index]);
      return typeof time === "number" && Number.isFinite(time) && close !== undefined && close > 0
        ? [{ time: time * 1000, close: close * factor }] : [];
    });
  }

  async bars(instruments: Instrument[], timeframe: Timeframe, count: number, now: number): Promise<BarsResult> {
    const result: BarsResult = { series: {}, failures: {} };
    await this.#each(instruments, result.failures, async (instrument) => {
      if (timeframe !== "day") {
        throw new ProviderError(`Hourly bars aren't available for shares on the ${venueDisplayName(instrument.venue)}.`);
      }
      if (!(Number.isInteger(count) && count > 0)) throw new ProviderError("The number of bars must be a whole number above zero");
      const { result: chart, factor } = await this.#chart(instrument, chartRange(count));
      const stamps = chart.timestamp;
      const indicators = isRecord(chart.indicators) ? chart.indicators : undefined;
      const quote = indicators && Array.isArray(indicators.quote) && isRecord(indicators.quote[0]) ? indicators.quote[0] : undefined;
      if (!Array.isArray(stamps) || !stamps.every((stamp) => typeof stamp === "number") || quote === undefined) throw noPrices(instrument);
      const column = (name: string): (number | undefined)[] => Array.isArray(quote[name]) ? (quote[name] as unknown[]).map(finiteNumber) : [];
      const o = column("open"), h = column("high"), l = column("low"), c = column("close"), v = column("volume");
      const bars: Bar[] = [];
      for (let i = 0; i < stamps.length; i++) {
        if (!(i < o.length && i < h.length && i < l.length && i < c.length)) continue;
        const open = o[i], high = h[i], low = l[i], close = c[i];
        if (open === undefined || high === undefined || low === undefined || close === undefined) continue;
        bars.push({
          time: (stamps[i] as number) * 1_000, open: open * factor, high: high * factor, low: low * factor, close: close * factor,
          volume: i < v.length ? (v[i] ?? 0) : 0,
        });
      }
      // As the app does: the last `count` bars, labelled with the venue's delay. Home-exchange volume is market-wide.
      const series = makeBarSeries(instrument, "day", bars.slice(-count), yahooProvenance(instrument.venue), now, true);
      if (series.bars.length === 0) throw noPrices(instrument);
      result.series[instrumentID(instrument)] = series;
    });
    return result;
  }

  async quotes(instruments: Instrument[], _now: number): Promise<QuotesResult> {
    const result: QuotesResult = { quotes: {}, failures: {} };
    await this.#each(instruments, result.failures, async (instrument) => {
      const { result: chart, factor } = await this.#chart(instrument, "5d");
      const meta = isRecord(chart.meta) ? chart.meta : {};
      const last = finiteNumber(meta.regularMarketPrice);
      const stamp = finiteNumber(meta.regularMarketTime);
      if (last === undefined || !(last > 0) || stamp === undefined) throw noPrices(instrument);
      const quote: Quote = { instrumentID: instrumentID(instrument), last: last * factor, time: stamp * 1_000, provenance: yahooProvenance(instrument.venue) };
      const volume = finiteNumber(meta.regularMarketVolume);
      if (volume !== undefined) quote.dayVolume = volume;
      result.quotes[instrumentID(instrument)] = quote;
    });
    return result;
  }

  /** Runs `work` for each supported instrument, a few at a time; a failure is that instrument's alone. */
  async #each(instruments: Instrument[], failures: Record<string, string>, work: (instrument: Instrument) => Promise<void>): Promise<void> {
    const queue = uniqueInstruments(instruments).filter((instrument) => {
      if (this.supports(instrument)) return true;
      failures[instrumentID(instrument)] = "This market isn't supported by this data source";
      return false;
    });
    const worker = async () => {
      for (let instrument = queue.shift(); instrument !== undefined; instrument = queue.shift()) {
        try {
          await work(instrument);
        } catch (error) {
          failures[instrumentID(instrument)] = failureReason(error);
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(this.#concurrency, queue.length) }, worker));
  }

  /** One chart call, checked for the listing's currency (the app's `exchangeChart`). */
  async #chart(instrument: Instrument, range: string): Promise<Chart> {
    const symbol = cleanSymbol(yahooSymbol(instrument));
    if (symbol === "") throw noPrices(instrument);
    const body = await this.#get(`${CHART_PATH}${encodeURIComponent(symbol)}`, [["interval", "1d"], ["range", range]]);
    const result = chartResult(body);
    const meta = result && isRecord(result.meta) ? result.meta : undefined;
    if (result === undefined || meta === undefined || typeof meta.currency !== "string") throw noPrices(instrument);
    const { code, factor } = normalisedCurrency(meta.currency);
    if (code !== instrument.currency) {
      throw new ProviderError(`${instrument.symbol} is quoted in ${code} on the ${venueDisplayName(instrument.venue)}, not ${instrument.currency}, so it can't be practice traded here.`);
    }
    return { result, factor };
  }

  /** One GET, retried on a network error, a timeout, HTTP 429 and HTTP 5xx — the Alpaca client's rule. */
  async #get(path: string, query: [string, string][]): Promise<unknown> {
    const url = `${this.#baseURL}${path}?${new URLSearchParams(query).toString()}`;
    for (let attempt = 1; ; attempt++) {
      const outcome = await this.#attempt(url, attempt);
      if (outcome.error === undefined) return outcome.body;
      if (!outcome.error.retryable || attempt >= this.#maxAttempts) throw outcome.error;
      const backoff = this.#backoffMs * 2 ** (attempt - 1);
      await this.#sleep(Math.max(backoff, outcome.retryAfterMs ?? 0));
    }
  }

  async #attempt(url: string, attempt: number): Promise<{ body?: unknown; error?: ProviderError; retryAfterMs?: number }> {
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, this.#timeoutMs);
    const started = performance.now();
    const event: Record<string, unknown> = { event: "market_data_request", provider: this.name, path: CHART_PATH, symbols: 1, attempt };
    try {
      const response = await this.#fetch(url, {
        method: "GET",
        headers: { "User-Agent": USER_AGENT, "Accept": "application/json" },
        signal: controller.signal,
      });
      const status = response.status;
      event.status = status;
      if (!response.ok) {
        const retryAfterMs = retryAfter(response.headers.get("retry-after"));
        await response.body?.cancel().catch(() => {});
        return { error: new ProviderError(`${SOURCE} answered with an error (${status}).`, status, status === 429 || status >= 500), retryAfterMs };
      }
      const text = await response.text();
      try {
        return { body: JSON.parse(text) };
      } catch {
        event.error = "unreadable";
        return { error: new ProviderError(`${SOURCE} returned an unreadable response`, status) };
      }
    } catch {
      event.error = timedOut ? "timeout" : "network";
      return { error: new ProviderError(timedOut ? "The request timed out" : `${SOURCE} couldn't be reached`, undefined, true) };
    } finally {
      clearTimeout(timer);
      event.ms = Math.round(performance.now() - started);
      try {
        this.#log?.(event);
      } catch {
        // A broken logger must not cost anyone their prices.
      }
    }
  }
}

function checkedBaseURL(baseURL: string): string {
  let url: URL;
  try {
    url = new URL(baseURL);
  } catch {
    throw new ProviderError("The market data address isn't valid");
  }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) throw new ProviderError("The market data address must use https");
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

function atLeast(value: number | undefined, minimum: number, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= minimum ? value : fallback;
}

function retryAfter(header: string | null): number | undefined {
  if (header === null || !/^\s*\d+(\.\d+)?\s*$/.test(header)) return undefined;
  return Math.min(Number(header) * 1_000, MAX_RETRY_AFTER_MS);
}
