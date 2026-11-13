// Deterministic test data and helpers for the engine tests. A port of
// TradingCore/Tests/TradingCoreTests/Fixtures.swift, so the Swift and TypeScript suites
// drive their engines with the same bars and quotes.
//
// Everything here is labelled as a fixture, so the engine refuses it unless a test
// switches `allowFixtureData` on.

import {
  addCivilDays, civilDateInZone, instantInZone, isTradingDay,
} from "../_shared/trading/calendar.ts";
import {
  type Bar, type BarSeries, type DataProvenance, emptySnapshot, fixtureProvenance, type Instrument, instrumentID, makeBarSeries,
  type MarketSnapshot, type Quote,
} from "../_shared/trading/market.ts";
import { asxStock, cryptoAsset, usETF, usStock } from "../_shared/trading/market.ts";
import { TradingEngine } from "../_shared/trading/engine.ts";
import * as Rounding from "../_shared/trading/rounding.ts";
import { makeSpec, Op, Rule, type StrategySpec } from "../_shared/trading/strategy.ts";

const NEW_YORK = "America/New_York";
const DAY = 86_400_000;

/** Tuesday 10 November 2026, 10:00 in New York (US market open, ASX closed). */
const now = Date.parse("2026-11-10T15:00:00Z");

function date(iso: string): number {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) throw new Error(`bad date ${iso}`);
  return t;
}

/** Midnight New York time on the US trading days before `end`, oldest first. */
function usTradingDays(count: number, before: number = now): number[] {
  const days: number[] = [];
  let day = civilDateInZone(NEW_YORK, before);
  while (days.length < count) {
    day = addCivilDays(day, -1);
    const midnight = instantInZone(NEW_YORK, day, 0, 0);
    if (isTradingDay("us", midnight)) days.push(midnight);
  }
  return days.reverse();
}

/** Daily bars from a list of closes. Each bar opens at the previous close. */
function dailyBars(closes: number[], days?: number[], volume = 5_000_000): Bar[] {
  const times = days ?? usTradingDays(closes.length);
  if (times.length !== closes.length) throw new Error("days and closes differ in length");
  return closes.map((close, i) => {
    const open = i === 0 ? close : closes[i - 1];
    return { time: times[i], open, high: Math.max(open, close) * 1.005, low: Math.min(open, close) * 0.995, close, volume };
  });
}

/** Daily crypto bars stamped at midnight UTC on consecutive days before `end`. */
function cryptoDays(count: number, before: number = now): number[] {
  const today = Math.floor(before / DAY) * DAY;
  const out: number[] = [];
  for (let back = count; back >= 1; back--) out.push(today - back * DAY);
  return out;
}

function series(instrument: Instrument, closes: number[], options: { days?: number[]; provenance?: DataProvenance; volume?: number } = {}): BarSeries {
  const times = options.days ?? (instrument.venue === "crypto" ? cryptoDays(closes.length) : usTradingDays(closes.length));
  return makeBarSeries(instrument, "day", dailyBars(closes, times, options.volume ?? 5_000_000), options.provenance ?? fixtureProvenance("test"), now);
}

function quote(instrument: Instrument, last: number,
  options: { spreadBps?: number | null; time?: number; provenance?: DataProvenance; dayVolume?: number } = {}): Quote {
  const spreadBps = options.spreadBps === undefined ? 2 : options.spreadBps;
  const out: Quote = { instrumentID: instrumentID(instrument), last, time: options.time ?? now, provenance: options.provenance ?? fixtureProvenance("test") };
  if (spreadBps !== null) {
    out.bid = Rounding.round(last * (1 - spreadBps / 20_000), 4);
    out.ask = Rounding.round(last * (1 + spreadBps / 20_000), 4);
  }
  if (options.dayVolume !== undefined) out.dayVolume = options.dayVolume;
  return out;
}

function engine(): TradingEngine {
  const e = new TradingEngine();
  e.state.accountPolicy.allowFixtureData = true;
  return e;
}

/** A flat series that then climbs: the 5-bar average crosses above the 20-bar one near the end. */
function risingCloses(options: { count?: number; base?: number; climbFrom?: number; step?: number } = {}): number[] {
  const count = options.count ?? 60, base = options.base ?? 100, climbFrom = options.climbFrom ?? 45, step = options.step ?? 1.5;
  const out: number[] = [];
  for (let i = 0; i < count; i++) out.push(i < climbFrom ? base : base + (i - climbFrom + 1) * step);
  return out;
}

/** A simple "close above the 20-day average" strategy. */
function aboveAverageSpec(universe: Instrument[], stopLossPct: number | null = 8): StrategySpec {
  return makeSpec({
    kind: "rules", title: "Above average", summary: "Test strategy", universe,
    entry: Rule.above(Op.close, Op.sma(20)), exit: Rule.below(Op.close, Op.sma(20)),
    protections: stopLossPct === null ? {} : { stopLossPct },
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 0,
  });
}

function snapshot(items: [Instrument, number[], number][], at: number = now): MarketSnapshot {
  const out = emptySnapshot();
  for (const [instrument, closes, last] of items) {
    out.series[instrumentID(instrument)] = series(instrument, closes);
    out.quotes[instrumentID(instrument)] = quote(instrument, last, { time: at });
  }
  return out;
}

export const Fx = {
  now, date,
  aapl: usStock("AAPL", "Apple"),
  msft: usStock("MSFT", "Microsoft"),
  spy: usETF("SPY", "S&P 500 ETF"),
  btc: cryptoAsset("BTC", "Bitcoin"),
  bhp: asxStock("BHP", "BHP Group"),
  usTradingDays, dailyBars, cryptoDays, series, quote, engine, risingCloses, aboveAverageSpec, snapshot,
};

// MARK: - Shared vectors

const vectorsURL = new URL("../../../TradingCore/Tests/Vectors/", import.meta.url);

// deno-lint-ignore no-explicit-any
export async function loadVectors(name: string): Promise<any> {
  return JSON.parse(await Deno.readTextFile(new URL(`${name}.json`, vectorsURL)));
}

/**
 * The first place two JSON-like values differ, or undefined when they match. Numbers must
 * be the very same double (including the sign of zero); null and a missing key are the same.
 */
export function firstDifference(actual: unknown, expected: unknown, path = "$"): string | undefined {
  const a = actual === null ? undefined : actual;
  const e = expected === null ? undefined : expected;
  if (a === undefined && e === undefined) return undefined;
  if (typeof a === "number" && typeof e === "number") {
    return Object.is(a, e) ? undefined : `${path}: got ${fmt(a)}, expected ${fmt(e)}`;
  }
  if (typeof a !== "object" || typeof e !== "object" || a === undefined || e === undefined) {
    return a === e ? undefined : `${path}: got ${fmt(a)}, expected ${fmt(e)}`;
  }
  if (Array.isArray(a) !== Array.isArray(e)) return `${path}: got ${fmt(a)}, expected ${fmt(e)}`;
  if (Array.isArray(a) && Array.isArray(e)) {
    if (a.length !== e.length) return `${path}: got ${a.length} items, expected ${e.length}`;
    for (let i = 0; i < a.length; i++) {
      const found = firstDifference(a[i], e[i], `${path}[${i}]`);
      if (found) return found;
    }
    return undefined;
  }
  const x = a as Record<string, unknown>, y = e as Record<string, unknown>;
  for (const key of Array.from(new Set([...Object.keys(x), ...Object.keys(y)])).sort()) {
    const found = firstDifference(x[key], y[key], `${path}.${key}`);
    if (found) return found;
  }
  return undefined;
}

function fmt(value: unknown): string {
  if (typeof value === "number" && Object.is(value, -0)) return "-0";
  const text = JSON.stringify(value);
  return text === undefined ? "nothing" : text.length > 240 ? `${text.slice(0, 240)}…` : text;
}

/** Collects mismatches so one run reports every broken case, not just the first. */
export class Mismatches {
  private readonly found: string[] = [];
  private checked = 0;

  check(label: string, actual: unknown, expected: unknown): void {
    this.checked += 1;
    const difference = firstDifference(actual, expected);
    if (difference) this.found.push(`${label} → ${difference}`);
  }

  assertNone(minimum = 1): void {
    if (this.checked < minimum) throw new Error(`Only ${this.checked} cases were checked; expected at least ${minimum}.`);
    if (this.found.length > 0) {
      const shown = this.found.slice(0, 12).join("\n  ");
      throw new Error(`${this.found.length} of ${this.checked} cases differ from the Swift vectors:\n  ${shown}`);
    }
  }

  get count(): number {
    return this.checked;
  }
}
