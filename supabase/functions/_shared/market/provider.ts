// Where the server gets real market data from. A provider answers two questions for a
// set of instruments — recent bars and the latest quote — and, when it can, a third: how
// much of the instrument trades in a day across the whole market.
//
// Rules every provider here follows:
//   - market data only: a provider never places, reads or even knows about orders;
//   - a price is real or it is absent. A failed or incomplete fetch is recorded as a
//     reason against that instrument ("nothing trades on these"); nothing is invented,
//     interpolated, carried forward or defaulted;
//   - `bars()` and `quotes()` do not reject for ordinary failures — the reason goes in
//     `failures`, in plain English, keyed like the data by `instrumentID()`;
//   - the clock is never read for data: `now` (ms since 1970) comes from the caller.

import {
  type BarSeries,
  emptySnapshot,
  type Instrument,
  instrumentID,
  type MarketSnapshot,
  type Quote,
  type Timeframe,
} from "../trading/market.ts";

export interface BarsResult {
  series: Record<string, BarSeries>;
  failures: Record<string, string>;
}

export interface QuotesResult {
  quotes: Record<string, Quote>;
  failures: Record<string, string>;
}

export interface MarketDataProvider {
  readonly name: string;
  /** False when this provider has no data for the instrument (e.g. ASX on Alpaca). */
  supports(instrument: Instrument): boolean;
  /** The most recent `count` bars per instrument, oldest first, keyed by instrumentID(). */
  bars(instruments: Instrument[], timeframe: Timeframe, count: number, now: number): Promise<BarsResult>;
  /** Latest quote per instrument, keyed by instrumentID(). */
  quotes(instruments: Instrument[], now: number): Promise<QuotesResult>;
  /**
   * Market-wide average daily traded value, in the instrument's currency, keyed by
   * instrumentID() — for instruments whose bars carry only one venue's volume. A missing
   * key means "not known"; it is never a guess. Never throws.
   */
  dollarVolume?(instruments: Instrument[], now: number): Promise<Record<string, number>>;
}

/** Anything that can say how much of an instrument trades in a day, market-wide. */
export interface DollarVolumeSource {
  dollarVolume(instruments: Instrument[], now: number): Promise<Record<string, number>>;
}

/**
 * A failure with a reason that is safe to show and to store: plain English, and never
 * any part of a credential, a header or a URL.
 */
export class ProviderError extends Error {
  readonly status?: number;
  readonly retryable: boolean;

  constructor(message: string, status?: number, retryable = false) {
    super(message);
    this.status = status;
    this.retryable = retryable;
    this.name = "ProviderError";
  }
}

/** What is recorded when something fails in a way no provider anticipated. */
export const UNEXPECTED_FAILURE = "The market data request failed";

/** The reason to record for a caught error. Only a ProviderError's own text is trusted. */
export function failureReason(error: unknown): string {
  return error instanceof ProviderError ? error.message : UNEXPECTED_FAILURE;
}

/**
 * Bars + quotes together. Mirrors the Swift `snapshot(for:timeframe:barCount:)` rule: a
 * bars failure is recorded as "Price history unavailable: <reason>"; a quote failure as
 * "Live quote unavailable: <reason>" only when there is no bars failure for that
 * instrument already.
 *
 * `dollarVolume` is filled only for instruments whose series says its volume is one
 * venue's slice (`volumeIsMarketWide === false`), from the provider's `dollarVolume()`
 * when it has one. No figure means the key is absent — liquidity is then unknown, which
 * the engine never treats as a small number.
 *
 * Never throws, and always returns all four maps.
 */
export async function snapshot(
  provider: MarketDataProvider,
  instruments: Instrument[],
  timeframe: Timeframe,
  barCount: number,
  now: number,
): Promise<MarketSnapshot> {
  const result = emptySnapshot();
  const wanted = uniqueInstruments(instruments);
  if (wanted.length === 0) return result;

  // Quotes don't wait for bars; the volume lookup has to (it depends on what the bars say).
  const quotesPending = settle(() => provider.quotes(wanted, now));
  const bars = await settle(() => provider.bars(wanted, timeframe, barCount, now));

  const oneVenueOnly: Instrument[] = [];
  for (const instrument of wanted) {
    const id = instrumentID(instrument);
    const series = bars.value === undefined ? undefined : own(bars.value.series, id);
    const barsFailure = bars.value === undefined ? bars.reason : own(bars.value.failures, id);
    if (isRecord(series) && barsFailure === undefined) {
      result.series[id] = series as unknown as BarSeries;
      if (series.volumeIsMarketWide === false) oneVenueOnly.push(instrument);
    } else {
      result.failures[id] = `Price history unavailable: ${reasonText(barsFailure)}`;
    }
  }

  const [quotes, volumes] = await Promise.all([quotesPending, knownDollarVolume(provider, oneVenueOnly, now)]);

  for (const instrument of wanted) {
    const id = instrumentID(instrument);
    const quote = quotes.value === undefined ? undefined : own(quotes.value.quotes, id);
    const quoteFailure = quotes.value === undefined ? quotes.reason : own(quotes.value.failures, id);
    if (quote !== undefined && quoteFailure === undefined) {
      result.quotes[id] = quote as Quote;
    } else if (result.failures[id] === undefined) {
      result.failures[id] = `Live quote unavailable: ${reasonText(quoteFailure)}`;
    }
  }
  for (const instrument of oneVenueOnly) {
    const id = instrumentID(instrument);
    const known = positiveNumber(own(volumes, id));
    if (known !== undefined) result.dollarVolume[id] = known;
  }
  return result;
}

/**
 * What the provider knows about market-wide traded value for these instruments. A
 * provider without the capability, one that rejects, or an answer that isn't an object
 * all come back as "nothing known".
 */
async function knownDollarVolume(provider: MarketDataProvider, instruments: Instrument[], now: number): Promise<unknown> {
  if (instruments.length === 0 || typeof provider.dollarVolume !== "function") return undefined;
  try {
    return await provider.dollarVolume(instruments, now);
  } catch {
    return undefined;
  }
}

/** A provider that answered with neither data nor a reason still must not look tradable. */
function reasonText(reason: unknown): string {
  return typeof reason === "string" && reason !== "" ? reason : "No data was returned";
}

async function settle<T>(work: () => Promise<T>): Promise<{ value?: T; reason?: string }> {
  try {
    const value = await work();
    if (typeof value !== "object" || value === null) return { reason: UNEXPECTED_FAILURE };
    return { value };
  } catch (error) {
    return { reason: failureReason(error) };
  }
}

// ---------------------------------------------------------------------------------------
// Helpers shared by the providers.

/** Each instrument once (the first time it appears), in the order given. */
export function uniqueInstruments(instruments: Instrument[]): Instrument[] {
  const seen = new Set<string>();
  const unique: Instrument[] = [];
  for (const instrument of instruments) {
    const id = instrumentID(instrument);
    if (seen.has(id)) continue;
    seen.add(id);
    unique.push(instrument);
  }
  return unique;
}

/**
 * Why a bars request can't be answered at all, or undefined when it can. These values
 * can arrive from a request body, so they are checked rather than trusted.
 */
export function barRequestProblem(timeframe: unknown, count: unknown, now: unknown): string | undefined {
  if (timeframe !== "hour" && timeframe !== "day") return "The bar size isn't one this data source knows";
  if (typeof count !== "number" || !Number.isInteger(count) || count < 1) return "The number of bars asked for isn't valid";
  if (typeof now !== "number" || !Number.isFinite(now)) return "The request time isn't valid";
  return undefined;
}

/** The series cut down to its most recent `count` bars. Nothing else about it changes. */
export function lastBars(series: BarSeries, count: number): BarSeries {
  if (series.bars.length <= count) return series;
  return { ...series, bars: series.bars.slice(series.bars.length - count) };
}

export function chunked<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let start = 0; start < items.length; start += size) chunks.push(items.slice(start, start + size));
  return chunks;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** A value the object itself holds — never one inherited from a prototype. */
export function own(record: unknown, key: string): unknown {
  return isRecord(record) && Object.hasOwn(record, key) ? record[key] : undefined;
}

/** The number, or undefined unless it is finite and above zero. */
export function positiveNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

export function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

const RFC3339 = /^(\d{4}-\d{2}-\d{2})[Tt](\d{2}:\d{2}:\d{2})(?:\.(\d+))?([Zz]|[+-]\d{2}:\d{2})$/;

/**
 * A venue timestamp ("2026-01-05T14:30:00.123456789Z") as milliseconds since 1970, or
 * undefined when it isn't a full RFC 3339 date-time. Feeds stamp to the nanosecond; the
 * fraction is cut to milliseconds. Anything looser ("0", a bare date, a number) is not a
 * time — `Date.parse` alone would happily turn some of those into a date.
 */
export function parseVenueTime(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const match = RFC3339.exec(value);
  if (match === null) return undefined;
  const fraction = match[3] === undefined ? "" : `.${match[3].slice(0, 3).padEnd(3, "0")}`;
  const zone = match[4].toUpperCase() === "Z" ? "Z" : match[4];
  const ms = Date.parse(`${match[1]}T${match[2]}${fraction}${zone}`);
  return Number.isFinite(ms) ? ms : undefined;
}
