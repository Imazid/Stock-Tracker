// Instruments and market data. A port of TradingCore/Sources/TradingCore/Market.swift.
//
// Conventions for the whole port:
//   - every time is a number of milliseconds since 1970 (what TradingCodec writes);
//   - JSON shapes match Swift's Codable output, so a value stored by the server decodes
//     on the phone and the shared vectors compare directly;
//   - an absent optional is `undefined`, never `null`;
//   - nothing here reads the clock or the network.

import { lookupInstrument } from "./catalog.ts";

export type AssetClass = "equity" | "etf" | "crypto";
export const ASSET_CLASSES: AssetClass[] = ["equity", "etf", "crypto"];

export type MarketRegion = "americas" | "europe" | "asiaPacific" | "crypto";

export function regionDisplayName(region: MarketRegion): string {
  switch (region) {
    case "americas": return "Americas";
    case "europe": return "Europe";
    case "asiaPacific": return "Asia-Pacific";
    case "crypto": return "Crypto";
  }
}

/** Where an instrument trades. It decides the trading calendar and the currency. */
export type Venue =
  | "us" | "asx" | "crypto"
  | "lse" | "xetra" | "euronextParis" | "euronextAmsterdam" | "six"
  | "tse" | "hkex" | "sgx" | "krx" | "nse";
export const VENUES: Venue[] = ["us", "asx", "crypto", "lse", "xetra", "euronextParis", "euronextAmsterdam", "six", "tse", "hkex", "sgx", "krx", "nse"];

interface VenueFacts {
  currency: string;
  /** Reads after "The": "The London market is closed." */
  displayName: string;
  /** The badge shown next to a ticker. */
  shortName: string;
  country: string;
  region: MarketRegion;
  /** The suffix Yahoo Finance puts on a listing here ("VOD.L"); undefined where prices come from elsewhere. */
  yahooSuffix?: string;
}

const VENUE_FACTS: Record<Venue, VenueFacts> = {
  us: { currency: "USD", displayName: "US market", shortName: "US", country: "United States", region: "americas" },
  asx: { currency: "AUD", displayName: "ASX", shortName: "ASX", country: "Australia", region: "asiaPacific", yahooSuffix: ".AX" },
  crypto: { currency: "USD", displayName: "Crypto", shortName: "Crypto", country: "Global", region: "crypto" },
  lse: { currency: "GBP", displayName: "London market", shortName: "LSE", country: "United Kingdom", region: "europe", yahooSuffix: ".L" },
  xetra: { currency: "EUR", displayName: "Frankfurt market (Xetra)", shortName: "XETRA", country: "Germany", region: "europe", yahooSuffix: ".DE" },
  euronextParis: { currency: "EUR", displayName: "Paris market", shortName: "PARIS", country: "France", region: "europe", yahooSuffix: ".PA" },
  euronextAmsterdam: { currency: "EUR", displayName: "Amsterdam market", shortName: "AMS", country: "Netherlands", region: "europe", yahooSuffix: ".AS" },
  six: { currency: "CHF", displayName: "Swiss market", shortName: "SIX", country: "Switzerland", region: "europe", yahooSuffix: ".SW" },
  tse: { currency: "JPY", displayName: "Tokyo market", shortName: "TSE", country: "Japan", region: "asiaPacific", yahooSuffix: ".T" },
  hkex: { currency: "HKD", displayName: "Hong Kong market", shortName: "HKEX", country: "Hong Kong", region: "asiaPacific", yahooSuffix: ".HK" },
  sgx: { currency: "SGD", displayName: "Singapore market", shortName: "SGX", country: "Singapore", region: "asiaPacific", yahooSuffix: ".SI" },
  krx: { currency: "KRW", displayName: "Korean market", shortName: "KRX", country: "South Korea", region: "asiaPacific", yahooSuffix: ".KS" },
  nse: { currency: "INR", displayName: "Indian market (NSE)", shortName: "NSE", country: "India", region: "asiaPacific", yahooSuffix: ".NS" },
};

export const venueCurrency = (venue: Venue): string => VENUE_FACTS[venue].currency;
export const venueDisplayName = (venue: Venue): string => VENUE_FACTS[venue].displayName;
export const venueShortName = (venue: Venue): string => VENUE_FACTS[venue].shortName;
export const venueCountry = (venue: Venue): string => VENUE_FACTS[venue].country;
export const venueRegion = (venue: Venue): MarketRegion => VENUE_FACTS[venue].region;
export const venueYahooSuffix = (venue: Venue): string | undefined => VENUE_FACTS[venue].yahooSuffix;

/** The venue and bare ticker behind a Yahoo symbol: "VOD.L" → (lse, "VOD"). */
export function parseYahooSymbol(yahooSymbol: string): { venue: Venue; symbol: string } | undefined {
  const upper = yahooSymbol.toUpperCase();
  for (const venue of VENUES) {
    const suffix = venueYahooSuffix(venue);
    if (suffix === undefined || !upper.endsWith(suffix) || !(upper.length > suffix.length)) continue;
    return { venue, symbol: upper.slice(0, upper.length - suffix.length) };
  }
  return undefined;
}

export interface Instrument {
  symbol: string;
  name: string;
  assetClass: AssetClass;
  venue: Venue;
  currency: string;
}

export function instrumentID(instrument: Instrument): string {
  return `${instrument.venue}:${instrument.symbol}`;
}

export function makeInstrument(symbol: string, assetClass: AssetClass, venue: Venue, name = "", currency?: string): Instrument {
  const upper = symbol.toUpperCase();
  return { symbol: upper, name: name === "" ? upper : name, assetClass, venue, currency: currency ?? venueCurrency(venue) };
}

export const usStock = (symbol: string, name = ""): Instrument => makeInstrument(symbol, "equity", "us", name);
export const usETF = (symbol: string, name = ""): Instrument => makeInstrument(symbol, "etf", "us", name);
export const asxStock = (symbol: string, name = ""): Instrument => makeInstrument(symbol, "equity", "asx", name);
export const cryptoAsset = (symbol: string, name = ""): Instrument => makeInstrument(symbol, "crypto", "crypto", name);
/** A share or fund listed on an exchange outside the US. */
export const listed = (symbol: string, venue: Venue, name = "", etf = false): Instrument =>
  makeInstrument(symbol, etf ? "etf" : "equity", venue, name);

/** The symbol Yahoo Finance knows this listing by ("VOD.L"); the bare symbol where Yahoo isn't the price source. */
export const yahooSymbol = (instrument: Instrument): string => instrument.symbol + (venueYahooSuffix(instrument.venue) ?? "");

/**
 * Lenient decoding, so a hand-written or AI-drafted strategy can give just a symbol and
 * an asset class. Anything left out is filled in from what was given. Throws on a shape
 * that isn't an instrument at all.
 */
export function decodeInstrument(raw: unknown): Instrument {
  if (typeof raw !== "object" || raw === null) throw new Error("An asset must be an object with a symbol.");
  const value = raw as Record<string, unknown>;
  if (typeof value.symbol !== "string") throw new Error("An asset needs a symbol.");
  const symbol = value.symbol.trim().toUpperCase();
  const assetClass = value.assetClass === undefined || value.assetClass === null ? undefined : value.assetClass;
  if (assetClass !== undefined && !ASSET_CLASSES.includes(assetClass as AssetClass)) throw new Error(`Unknown asset class "${String(assetClass)}".`);
  const venue = value.venue === undefined || value.venue === null ? undefined : value.venue;
  if (venue !== undefined && !VENUES.includes(venue as Venue)) throw new Error(`Unknown venue "${String(venue)}".`);
  const known = lookupInstrument(symbol, venue as Venue | undefined);
  const resolvedClass = (assetClass as AssetClass | undefined) ?? known?.assetClass ?? "equity";
  const resolvedVenue = (venue as Venue | undefined) ?? known?.venue ?? (resolvedClass === "crypto" ? "crypto" : "us");
  const name = typeof value.name === "string" ? value.name : known?.name ?? "";
  const currency = typeof value.currency === "string" ? value.currency : undefined;
  return makeInstrument(symbol, resolvedClass, resolvedVenue, name, currency);
}

/** What an execution venue will accept for one instrument. */
export interface InstrumentRules {
  quantityIncrement: number;
  minQuantity: number;
  minNotional: number;
  priceIncrement: number;
  fractionable: boolean;
}

export type Timeframe = "hour" | "day";
export const TIMEFRAMES: Timeframe[] = ["hour", "day"];

export function timeframeSeconds(timeframe: Timeframe): number {
  return timeframe === "hour" ? 3_600 : 86_400;
}

export function barName(timeframe: Timeframe): string {
  return timeframe === "day" ? "daily" : "hourly";
}

/**
 * Where a number came from. Trading code only accepts `market`; fixtures exist for tests
 * and are refused everywhere else, and `synthetic` is refused always.
 */
export interface DataProvenance {
  kind: "market" | "fixture" | "synthetic";
  source: string;
  /** How far behind the exchange the feed runs (0 = real time). */
  delaySeconds: number;
}

export const marketProvenance = (source: string, delaySeconds = 0): DataProvenance => ({ kind: "market", source, delaySeconds });
export const fixtureProvenance = (name: string): DataProvenance => ({ kind: "fixture", source: name, delaySeconds: 0 });
export const syntheticProvenance: DataProvenance = { kind: "synthetic", source: "synthetic", delaySeconds: 0 };

export function isRealMarketData(provenance: DataProvenance): boolean {
  return provenance.kind === "market";
}

export interface Bar {
  /** Start of the bar. */
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}

export function isValidBar(bar: Bar): boolean {
  return [bar.open, bar.high, bar.low, bar.close].every((x) => Number.isFinite(x) && x > 0) &&
    bar.high >= bar.low && Number.isFinite(bar.volume) && bar.volume >= 0;
}

export interface BarSeries {
  instrument: Instrument;
  timeframe: Timeframe;
  /** Oldest first. */
  bars: Bar[];
  provenance: DataProvenance;
  fetchedAt: number;
  /**
   * False when the volumes cover one venue only (a single exchange's slice of the market).
   * Such volumes say nothing about how liquid the asset is, so they are never used to
   * measure liquidity.
   */
  volumeIsMarketWide: boolean;
}

/** Builds a series the way Swift's initialiser does: invalid bars dropped, oldest first. */
export function makeBarSeries(instrument: Instrument, timeframe: Timeframe, bars: Bar[], provenance: DataProvenance, fetchedAt: number,
  volumeIsMarketWide = true): BarSeries {
  const kept = bars.filter(isValidBar).map((bar, index) => ({ bar, index }));
  kept.sort((a, b) => a.bar.time - b.bar.time || a.index - b.index);
  return { instrument, timeframe, bars: kept.map((entry) => entry.bar), provenance, fetchedAt, volumeIsMarketWide };
}

export interface Quote {
  instrumentID: string;
  last: number;
  bid?: number;
  ask?: number;
  /** When the venue produced this price (not when we fetched it). */
  time: number;
  provenance: DataProvenance;
  /**
   * A market-wide daily volume in units (today's, or a typical day's), when one is known.
   * The simulator uses it to decide how much of a large order can fill at once. Leave it
   * out rather than pass one venue's slice of the market.
   */
  dayVolume?: number;
}

/** A usable bid and ask: both present, positive and not crossed. */
export function hasTwoSidedMarket(quote: Quote): boolean {
  if (quote.bid === undefined || quote.ask === undefined) return false;
  return quote.bid > 0 && quote.ask > 0 && quote.ask >= quote.bid;
}

export function quoteMid(quote: Quote): number {
  if (!hasTwoSidedMarket(quote)) return quote.last;
  return (quote.bid! + quote.ask!) / 2;
}

/** Spread in basis points of the mid; undefined without a two-sided market. */
export function quoteSpreadBps(quote: Quote): number | undefined {
  const mid = quoteMid(quote);
  if (!hasTwoSidedMarket(quote) || !(mid > 0)) return undefined;
  return (quote.ask! - quote.bid!) / mid * 10_000;
}

/** Age in seconds at `now`. */
export function quoteAge(quote: Quote, now: number): number {
  return (now - quote.time) / 1_000;
}

/** Liquidity and volatility of an instrument, measured from real daily bars. */
export interface InstrumentStats {
  averageDollarVolume: number;
  /** Standard deviation of daily returns, in percent. */
  dailyVolatilityPct: number;
}

/** From the last `lookback` completed daily bars; undefined when there are too few. */
export function measureStats(bars: Bar[], lookback = 20): InstrumentStats | undefined {
  if (bars.length < lookback + 1) return undefined;
  const window = bars.slice(bars.length - (lookback + 1));
  let dollarVolume = 0;
  for (const bar of window.slice(window.length - lookback)) dollarVolume += bar.close * bar.volume;
  dollarVolume /= lookback;
  const returns: number[] = [];
  for (let i = 1; i < window.length; i++) {
    if (window[i - 1].close > 0) returns.push(window[i].close / window[i - 1].close - 1);
  }
  if (returns.length < 2) return undefined;
  let sum = 0;
  for (const r of returns) sum += r;
  const mean = sum / returns.length;
  let squares = 0;
  for (const r of returns) squares += (r - mean) * (r - mean);
  const variance = squares / (returns.length - 1);
  return { averageDollarVolume: dollarVolume, dailyVolatilityPct: Math.sqrt(variance) * 100 };
}

/**
 * Everything an agent run or an order needs to know about the market, gathered up front
 * so the decision code itself never touches the network.
 */
export interface MarketSnapshot {
  series: Record<string, BarSeries>;
  quotes: Record<string, Quote>;
  /** Instruments whose data could not be loaded, with the reason. Nothing trades on these. */
  failures: Record<string, string>;
  /**
   * Market-wide average daily traded value, for instruments whose bars carry only one
   * venue's volume (crypto, mostly). Read by `snapshotStats` in calendar.ts.
   */
  dollarVolume: Record<string, number>;
}

export function emptySnapshot(): MarketSnapshot {
  return { series: {}, quotes: {}, failures: {}, dollarVolume: {} };
}
