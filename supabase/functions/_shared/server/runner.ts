// Gathers the market data an engine call needs, before the database transaction opens (so
// no lock is held while a price is fetched). Nothing here decides anything: it fetches,
// labels what failed, and hands the engine a snapshot. A missing price stays missing.

import { type MarketDataProvider, snapshot as fetchSnapshot } from "../market/index.ts";
import { snapshotStats } from "../trading/calendar.ts";
import {
  emptySnapshot, type Instrument, instrumentID, type InstrumentStats, isRealMarketData, type MarketSnapshot, type Quote, type Timeframe,
} from "../trading/market.ts";
import { TradingError } from "../trading/state.ts";
import { venueDisplayName } from "../trading/market.ts";

export interface MarketSource {
  provider: MarketDataProvider | null;
  /** True only when the function's TRADING_ALLOW_FIXTURE_DATA flag is "1". */
  allowFixtureData: boolean;
  /** Why there is no provider. */
  reason?: string;
}

function unique(instruments: Instrument[]): Instrument[] {
  const seen = new Set<string>();
  return instruments.filter((instrument) => {
    const id = instrumentID(instrument);
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

/** Bars and quotes for a set of instruments. With no provider every instrument is a recorded failure. */
export async function marketSnapshot(source: MarketSource, instruments: Instrument[], timeframe: Timeframe, barCount: number, now: number): Promise<MarketSnapshot> {
  const wanted = unique(instruments);
  if (wanted.length === 0) return emptySnapshot();
  if (!source.provider) {
    const out = emptySnapshot();
    for (const instrument of wanted) out.failures[instrumentID(instrument)] = `Price history unavailable: ${source.reason ?? "Market data isn't configured."}`;
    return out;
  }
  return await fetchSnapshot(source.provider, wanted, timeframe, barCount, now);
}

/** Latest quotes only. Instruments with no usable quote are simply absent. */
export async function latestQuotes(source: MarketSource, instruments: Instrument[], now: number): Promise<Quote[]> {
  const wanted = unique(instruments);
  if (wanted.length === 0 || !source.provider) return [];
  try {
    const result = await source.provider.quotes(wanted, now);
    return Object.values(result.quotes ?? {});
  } catch {
    return [];
  }
}

/**
 * Liquidity and volatility from a snapshot, by the same rule the engine applies inside an
 * agent run: only data the engine would accept is measured.
 */
export function usableStats(snapshot: MarketSnapshot, now: number, allowFixtureData: boolean): Record<string, InstrumentStats> {
  const usable: MarketSnapshot = { ...snapshot, series: {} };
  for (const [id, series] of Object.entries(snapshot.series)) {
    if (isRealMarketData(series.provenance) || (series.provenance.kind === "fixture" && allowFixtureData)) usable.series[id] = series;
  }
  return snapshotStats(usable, now);
}

/** Prices for a manual order or an approval: a quote and daily stats for the instrument, quotes for the rest. */
export async function marketForOrder(source: MarketSource, instrument: Instrument, others: Instrument[], now: number):
  Promise<{ quotes: Quote[]; stats: Record<string, InstrumentStats> }> {
  const [snapshot, rest] = await Promise.all([
    marketSnapshot(source, [instrument], "day", 30, now),
    latestQuotes(source, others.filter((other) => instrumentID(other) !== instrumentID(instrument)), now),
  ]);
  return { quotes: [...Object.values(snapshot.quotes), ...rest], stats: usableStats(snapshot, now, source.allowFixtureData) };
}

/** The part of a snapshot that concerns one agent's instruments. */
export function subset(snapshot: MarketSnapshot, instruments: Instrument[]): MarketSnapshot {
  const out = emptySnapshot();
  for (const instrument of instruments) {
    const id = instrumentID(instrument);
    if (snapshot.series[id]) out.series[id] = snapshot.series[id];
    if (snapshot.quotes[id]) out.quotes[id] = snapshot.quotes[id];
    if (snapshot.failures[id] !== undefined) out.failures[id] = snapshot.failures[id];
    if (snapshot.dollarVolume[id] !== undefined) out.dollarVolume[id] = snapshot.dollarVolume[id];
  }
  return out;
}

/**
 * The server can only run what it can price. An instrument on a venue the configured data
 * source doesn't cover is refused up front, with the reason, instead of failing every run.
 */
export function assertPriced(source: MarketSource, instruments: Instrument[]): void {
  if (!source.provider) return;
  const problems: string[] = [];
  for (const instrument of unique(instruments)) {
    if (!source.provider.supports(instrument)) {
      problems.push(`Prices for the ${venueDisplayName(instrument.venue)} aren't available on the server yet, so ${instrument.symbol} can't be traded here.`);
    }
  }
  if (problems.length > 0) throw TradingError.invalid(problems);
}
