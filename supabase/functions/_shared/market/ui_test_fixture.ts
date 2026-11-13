// Deterministic prices for the app's UI tests, identical to the app's offline
// `FixtureMarketData` (Stock Tracker/TradingMarketData.swift, #if DEBUG), so a UI test
// that runs against the local stack sees the same numbers as one that runs offline.
//
// Honoured only when the function's TRADING_ALLOW_FIXTURE_DATA flag is "1" and a request
// asks for `"fixture": "ui-test"`. Everything it hands out is labelled fixture("ui-test"),
// which the engine refuses unless that same flag is on: it can never pass for a real price.
//
// The formula, as in the app: a gentle climb with a wave on top, so trend rules fire.
//   close(i) = base × (1 + i × (0.0015 + drift) + sin(i / 6) × 0.02)
//   base     = 60,000 for crypto, 400 for MSFT, 200 for anything else
//   drift    = (sum of the symbol's Unicode scalar values mod 5) × 0.0002
// Bars sit on the venue's trading days before today (midnight in its own time zone),
// open at the previous close, high/low ±0.4%, volume 8,000,000. A quote is the 260th
// close with the bid and ask 1 bp either side, stamped `now`.

import { addCivilDays, civilDateInZone, instantInZone, isTradingDay, timeZone } from "../trading/calendar.ts";
import { type Bar, fixtureProvenance, type Instrument, instrumentID, type Quote, type Timeframe } from "../trading/market.ts";
import type { BarsResult, MarketDataProvider, QuotesResult } from "./provider.ts";
import { uniqueInstruments } from "./provider.ts";

/** The most bars one request may ask for (the scheduler asks for a few hundred at most). */
const MAX_BARS = 5_000;
const PROVENANCE = fixtureProvenance("ui-test");

/** The app's `closes(for:count:)`. */
export function uiTestCloses(instrument: Instrument, count: number): number[] {
  const base = instrument.assetClass === "crypto" ? 60_000 : (instrument.symbol === "MSFT" ? 400 : 200);
  let scalars = 0;
  for (const char of instrument.symbol) scalars += char.codePointAt(0)!;
  const drift = (scalars % 5) * 0.0002;
  const out: number[] = [];
  for (let i = 0; i < count; i++) out.push(base * (1 + i * (0.0015 + drift) + Math.sin(i / 6) * 0.02));
  return out;
}

/** The venue's trading days before the one `now` falls on, at local midnight, oldest first. */
function tradingDays(instrument: Instrument, count: number, now: number): number[] {
  const zone = timeZone(instrument.venue);
  const days: number[] = [];
  let day = civilDateInZone(zone, now);
  // Two years of calendar days hold far more trading days than any request; the bound only stops a runaway loop.
  for (let guard = 0; days.length < count && guard < count * 3 + 30; guard++) {
    day = addCivilDays(day, -1);
    const midnight = instantInZone(zone, day, 0, 0);
    if (isTradingDay(instrument.venue, midnight)) days.push(midnight);
  }
  return days.reverse();
}

export class UITestFixtureProvider implements MarketDataProvider {
  readonly name = "fixture";

  supports(_instrument: Instrument): boolean {
    return true;
  }

  bars(instruments: Instrument[], timeframe: Timeframe, count: number, now: number): Promise<BarsResult> {
    const result: BarsResult = { series: {}, failures: {} };
    for (const instrument of uniqueInstruments(instruments)) {
      const id = instrumentID(instrument);
      if (!(Number.isInteger(count) && count > 0 && count <= MAX_BARS)) {
        result.failures[id] = "The number of bars must be a whole number from 1 to 5000";
        continue;
      }
      const days = tradingDays(instrument, count, now);
      const values = uiTestCloses(instrument, count);
      const bars: Bar[] = values.map((close, i) => {
        const open = i === 0 ? close : values[i - 1];
        return { time: days[i], open, high: Math.max(open, close) * 1.004, low: Math.min(open, close) * 0.996, close, volume: 8_000_000 };
      });
      // As the app does: the series keeps the timeframe it was asked for, and the bars aren't tidied.
      result.series[id] = { instrument, timeframe, bars, provenance: PROVENANCE, fetchedAt: now, volumeIsMarketWide: true };
    }
    return Promise.resolve(result);
  }

  quotes(instruments: Instrument[], now: number): Promise<QuotesResult> {
    const result: QuotesResult = { quotes: {}, failures: {} };
    for (const instrument of uniqueInstruments(instruments)) {
      const last = uiTestCloses(instrument, 260)[259];
      result.quotes[instrumentID(instrument)] = {
        instrumentID: instrumentID(instrument), last, bid: last * 0.9999, ask: last * 1.0001, time: now, provenance: PROVENANCE,
      } satisfies Quote;
    }
    return Promise.resolve(result);
  }
}
