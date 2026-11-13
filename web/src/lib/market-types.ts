// Shapes the market-data routes return. Shared by the route handlers (server) and the
// pages (client). Every price says where it came from, in which currency, when it was
// observed and how fresh it is — a number without those is never shown.

import type { AssetClass, Venue } from "@engine/market.ts";

export type DataStatus = "real_time" | "delayed" | "indicative";

/** How much of the market a candle's volume covers. */
export type VolumeScope = "consolidated" | "single_venue" | "aggregate" | "unknown";

export interface InstrumentView {
  /** Canonical id: `${venue}:${symbol}` (the engine's instrumentID). Tickers alone aren't unique. */
  id: string;
  symbol: string;
  name: string;
  assetClass: AssetClass;
  venue: Venue;
  venueName: string;
  venueShort: string;
  /** Currency the venue trades in. */
  currency: string;
  /** Crypto only: the pair we price ("BTC/USD"). */
  pair?: string;
}

export interface MarketStateView {
  venue: Venue;
  isOpen: boolean;
  /** False when the holiday tables don't cover today — open/closed is then a best guess. */
  calendarCovered: boolean;
  nextOpen?: string;
  nextClose?: string;
  /** "Open", "Closed · opens Mon 09:30 local", "Open 24/7". */
  label: string;
}

export interface QuoteView {
  instrumentId: string;
  last: number;
  previousClose?: number;
  change?: number;
  changePct?: number;
  bid?: number;
  ask?: number;
  dayHigh?: number;
  dayLow?: number;
  volume?: number;
  volumeScope: VolumeScope;
  /** Currency of every number in this quote (after GBp→GBP style normalisation). */
  currency: string;
  /** Human-readable source, e.g. "Yahoo Finance", "Alpaca (IEX feed)", "CoinGecko aggregate". */
  source: string;
  /** When the venue produced the price, ISO-8601 UTC. */
  observedAt: string;
  /** When we fetched it, ISO-8601 UTC. */
  fetchedAt: string;
  status: DataStatus;
  delayMinutes?: number;
  stale: boolean;
  staleReason?: string;
  notes: string[];
}

export interface CandleView {
  /** Bar start, seconds since 1970 UTC. */
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}

export type ChartRange = "1D" | "5D" | "1M" | "3M" | "6M" | "1Y" | "5Y";
export const CHART_RANGES: ChartRange[] = ["1D", "5D", "1M", "3M", "6M", "1Y", "5Y"];

export interface CandlesView {
  instrument: InstrumentView;
  range: ChartRange;
  /** Bar size, e.g. "5m", "1h", "1d", "1wk". */
  interval: string;
  intraday: boolean;
  candles: CandleView[];
  currency: string;
  source: string;
  status: DataStatus;
  delayMinutes?: number;
  /** Time of the newest bar, ISO-8601 UTC. */
  observedAt?: string;
  fetchedAt: string;
  adjustment: string;
  volumeScope: VolumeScope;
  notes: string[];
  market: MarketStateView;
}

export interface QuoteResponse {
  instrument: InstrumentView;
  quote: QuoteView;
  market: MarketStateView;
}

export interface InstrumentResponse {
  instrument: InstrumentView;
  market: MarketStateView;
  sources: { quotes: string[]; candles: string[] };
}

export interface SearchResult extends InstrumentView {
  /** Where the match came from: our curated catalog or the live search. */
  origin: "catalog" | "search";
  exchangeLabel?: string;
}

export interface SearchResponse {
  query: string;
  results: SearchResult[];
  /** Set when the live search couldn't be reached; catalog matches are still returned. */
  warning?: string;
}

export interface ApiErrorBody {
  error: { code: string; message: string; details?: Record<string, unknown> };
}
