// Canned market data for tests. Everything it hands out is stamped with a provenance of
// kind "fixture", which the trading engine refuses unless its own test-only switch is on
// — so this can never be mistaken for a real price, whatever numbers it is loaded with.
//
// The data arrives from a JSON request body, so its shape is checked rather than
// trusted: a series or quote that isn't exactly well-formed is treated as missing (the
// instrument gets a failure), never repaired.

import {
  type Bar,
  type DataProvenance,
  fixtureProvenance,
  type Instrument,
  instrumentID,
  makeBarSeries,
  type Quote,
  type Timeframe,
} from "../trading/market.ts";
import {
  barRequestProblem,
  type BarsResult,
  finiteNumber,
  isRecord,
  lastBars,
  type MarketDataProvider,
  positiveNumber,
  type QuotesResult,
  uniqueInstruments,
} from "./provider.ts";

export interface FixtureSeries {
  timeframe: Timeframe;
  bars: Bar[];
  /**
   * False to play a feed whose volume is one venue's slice (Alpaca crypto, IEX). Left
   * out, the volume counts as the whole market's.
   */
  volumeIsMarketWide?: boolean;
}

export interface FixtureQuote {
  last: number;
  bid?: number;
  ask?: number;
  time: number;
  dayVolume?: number;
}

/** Series, quotes and dollar volumes are keyed by instrument id ("us:AAPL"). */
export interface FixtureData {
  series?: Record<string, FixtureSeries>;
  quotes?: Record<string, FixtureQuote>;
  /** Market-wide average daily traded value, for `dollarVolume()` to hand back. */
  dollarVolume?: Record<string, number>;
  source?: string;
}

interface StoredSeries {
  timeframe: Timeframe;
  bars: Bar[];
  volumeIsMarketWide: boolean;
}

export class FixtureDataProvider implements MarketDataProvider {
  readonly name = "fixture";
  readonly #series = new Map<string, StoredSeries>();
  readonly #quotes = new Map<string, FixtureQuote>();
  readonly #dollarVolume = new Map<string, number>();
  readonly #provenance: DataProvenance;

  constructor(data: FixtureData) {
    const input: unknown = data;
    const source = isRecord(input) && typeof input.source === "string" && input.source !== "" ? input.source : "fixture";
    this.#provenance = fixtureProvenance(source);
    if (!isRecord(input)) return;
    if (isRecord(input.series)) {
      for (const [id, raw] of Object.entries(input.series)) {
        const series = readSeries(raw);
        if (series !== undefined) this.#series.set(id, series);
      }
    }
    if (isRecord(input.quotes)) {
      for (const [id, raw] of Object.entries(input.quotes)) {
        const quote = readQuote(raw);
        if (quote !== undefined) this.#quotes.set(id, quote);
      }
    }
    if (isRecord(input.dollarVolume)) {
      for (const [id, raw] of Object.entries(input.dollarVolume)) {
        const value = positiveNumber(raw);
        if (value !== undefined) this.#dollarVolume.set(id, value);
      }
    }
  }

  supports(_instrument: Instrument): boolean {
    return true;
  }

  bars(instruments: Instrument[], timeframe: Timeframe, count: number, now: number): Promise<BarsResult> {
    const result: BarsResult = { series: {}, failures: {} };
    const problem = barRequestProblem(timeframe, count, now);
    for (const instrument of uniqueInstruments(instruments)) {
      const id = instrumentID(instrument);
      if (problem !== undefined) {
        result.failures[id] = problem;
        continue;
      }
      const stored = this.#series.get(id);
      const series = stored === undefined || stored.timeframe !== timeframe
        ? undefined
        : makeBarSeries(instrument, timeframe, stored.bars.map((bar) => ({ ...bar })), this.#provenance, now, stored.volumeIsMarketWide);
      if (series === undefined || series.bars.length === 0) {
        result.failures[id] = `No fixture price history for ${instrument.symbol}`;
      } else {
        result.series[id] = lastBars(series, count);
      }
    }
    return Promise.resolve(result);
  }

  quotes(instruments: Instrument[], _now: number): Promise<QuotesResult> {
    const result: QuotesResult = { quotes: {}, failures: {} };
    for (const instrument of uniqueInstruments(instruments)) {
      const id = instrumentID(instrument);
      const stored = this.#quotes.get(id);
      if (stored === undefined) {
        result.failures[id] = `No fixture quote for ${instrument.symbol}`;
        continue;
      }
      const quote: Quote = { instrumentID: id, last: stored.last, time: stored.time, provenance: this.#provenance };
      if (stored.bid !== undefined) quote.bid = stored.bid;
      if (stored.ask !== undefined) quote.ask = stored.ask;
      if (stored.dayVolume !== undefined) quote.dayVolume = stored.dayVolume;
      result.quotes[id] = quote;
    }
    return Promise.resolve(result);
  }

  /** The fixture's own figures for the instruments asked about; nothing for the rest. */
  dollarVolume(instruments: Instrument[], _now: number): Promise<Record<string, number>> {
    const known: Record<string, number> = {};
    for (const instrument of uniqueInstruments(instruments)) {
      const id = instrumentID(instrument);
      const value = this.#dollarVolume.get(id);
      if (value !== undefined) known[id] = value;
    }
    return Promise.resolve(known);
  }
}

/** A well-formed series, or undefined. One bad bar spoils the series: no silent gaps. */
function readSeries(raw: unknown): StoredSeries | undefined {
  if (!isRecord(raw)) return undefined;
  if (raw.timeframe !== "hour" && raw.timeframe !== "day") return undefined;
  if (!Array.isArray(raw.bars)) return undefined;
  // Left out (or null) means the usual case; anything else that isn't true or false is
  // a mistake, and guessing which was meant would decide whether the volume is trusted.
  const marketWide = raw.volumeIsMarketWide;
  if (marketWide !== undefined && marketWide !== null && typeof marketWide !== "boolean") return undefined;
  const bars: Bar[] = [];
  for (const item of raw.bars) {
    if (!isRecord(item)) return undefined;
    const time = finiteNumber(item.time);
    const open = finiteNumber(item.open);
    const high = finiteNumber(item.high);
    const low = finiteNumber(item.low);
    const close = finiteNumber(item.close);
    const volume = finiteNumber(item.volume);
    if (time === undefined || open === undefined || high === undefined || low === undefined || close === undefined || volume === undefined) {
      return undefined;
    }
    bars.push({ time, open, high, low, close, volume });
  }
  return { timeframe: raw.timeframe, bars, volumeIsMarketWide: marketWide !== false };
}

/** A well-formed quote, or undefined. An optional field may be left out or null. */
function readQuote(raw: unknown): FixtureQuote | undefined {
  if (!isRecord(raw)) return undefined;
  const last = positiveNumber(raw.last);
  const time = finiteNumber(raw.time);
  if (last === undefined || time === undefined) return undefined;
  const quote: FixtureQuote = { last, time };
  for (const field of ["bid", "ask", "dayVolume"] as const) {
    const value = raw[field];
    if (value === undefined || value === null) continue;
    const number = finiteNumber(value);
    if (number === undefined || number < 0) return undefined;
    quote[field] = number;
  }
  return quote;
}
