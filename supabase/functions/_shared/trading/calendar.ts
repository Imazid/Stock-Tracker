// Regular trading sessions. A port of TradingCore/Sources/TradingCore/MarketCalendar.swift
// with the same hours and holiday tables. Crypto never closes; each stock exchange follows
// its own calendar in its own time zone, and some Asian exchanges stop for lunch.
//
// Holiday tables come from each exchange's published calendar (US and ASX here, the others
// in exchange_holidays.ts) and need extending each year. Outside the years a table covers,
// the calendar still knows weekends and weekly hours but not holidays — `coversDate` says
// which. An unlisted holiday fails safe: no fresh quotes arrive, the risk engine refuses
// stale prices, and nothing trades.
//
// Time zones come from the runtime's own tz database through Intl (no clock is read:
// every instant is an argument).

import { ExchangeHolidays } from "./exchange_holidays.ts";
import {
  type Bar, type BarSeries, type InstrumentStats, type MarketSnapshot, measureStats, type Timeframe, timeframeSeconds, type Venue,
} from "./market.ts";

interface Segment { open: number; close: number }

interface Hours {
  timeZone: string;
  /** Trading segments in minutes after local midnight; two when there's a lunch break. */
  segments: Segment[];
  holidays: Set<string>;
  /** Early-close days → the minute trading ends that day. */
  earlyCloses: Map<string, number>;
  covered?: { lowerBound: number; upperBound: number };
}

/** "13:00" → 780. Reads the pieces the way Swift's `split` + `Int()` do. */
function minutes(hhmm: string): number | undefined {
  const parts = hhmm.split(":").filter((part) => /^[+-]?\d+$/.test(part)).map(Number);
  if (parts.length !== 2) return undefined;
  return parts[0] * 60 + parts[1];
}

function international(venue: Venue, timeZone: string, segments: [number, number][]): Hours {
  const earlyCloses = new Map<string, number>();
  for (const [day, time] of Object.entries(ExchangeHolidays.earlyCloses[venue] ?? {})) {
    const minute = minutes(time);
    if (minute !== undefined) earlyCloses.set(day, minute);
  }
  return {
    timeZone, segments: segments.map(([open, close]) => ({ open, close })),
    holidays: new Set(ExchangeHolidays.closures[venue] ?? []), earlyCloses, covered: ExchangeHolidays.coveredYears[venue],
  };
}

/** Years the US and ASX holiday tables cover. Other venues: see `coveredYearsFor`. */
export const coveredYears = { lowerBound: 2026, upperBound: 2027 };

const TABLE: Partial<Record<Venue, Hours>> = {
  us: {
    timeZone: "America/New_York",
    segments: [{ open: 9 * 60 + 30, close: 16 * 60 }],
    holidays: new Set([
      "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19",
      "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25",
      "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18",
      "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24",
    ]),
    earlyCloses: new Map([["2026-11-27", 13 * 60], ["2026-12-24", 13 * 60], ["2027-11-26", 13 * 60]]),
    covered: coveredYears,
  },
  asx: {
    timeZone: "Australia/Sydney",
    segments: [{ open: 10 * 60, close: 16 * 60 }],
    holidays: new Set([
      "2026-01-01", "2026-01-26", "2026-04-03", "2026-04-06", "2026-06-08", "2026-12-25", "2026-12-28",
      "2027-01-01", "2027-01-26", "2027-03-26", "2027-03-29", "2027-06-14", "2027-12-27", "2027-12-28",
    ]),
    earlyCloses: new Map([["2026-12-24", 14 * 60 + 10], ["2026-12-31", 14 * 60 + 10], ["2027-12-24", 14 * 60 + 10], ["2027-12-31", 14 * 60 + 10]]),
    covered: coveredYears,
  },
  // Continuous trading through the closing auction, local time.
  lse: international("lse", "Europe/London", [[8 * 60, 16 * 60 + 35]]),
  xetra: international("xetra", "Europe/Berlin", [[9 * 60, 17 * 60 + 35]]),
  euronextParis: international("euronextParis", "Europe/Paris", [[9 * 60, 17 * 60 + 35]]),
  euronextAmsterdam: international("euronextAmsterdam", "Europe/Amsterdam", [[9 * 60, 17 * 60 + 35]]),
  six: international("six", "Europe/Zurich", [[9 * 60, 17 * 60 + 30]]),
  tse: international("tse", "Asia/Tokyo", [[9 * 60, 11 * 60 + 30], [12 * 60 + 30, 15 * 60 + 30]]),
  hkex: international("hkex", "Asia/Hong_Kong", [[9 * 60 + 30, 12 * 60], [13 * 60, 16 * 60 + 10]]),
  sgx: international("sgx", "Asia/Singapore", [[9 * 60, 12 * 60], [13 * 60, 17 * 60 + 6]]),
  krx: international("krx", "Asia/Seoul", [[9 * 60, 15 * 60 + 30]]),
  nse: international("nse", "Asia/Kolkata", [[9 * 60 + 15, 15 * 60 + 30]]),
};

const DAY_MS = 86_400_000;

function hours(venue: Venue): Hours | undefined {
  return TABLE[venue];
}

// MARK: Civil dates

export interface CivilDate { year: number; month: number; day: number }
interface CivilTime extends CivilDate { hour: number; minute: number; second: number }

const formatters = new Map<string, Intl.DateTimeFormat>();

function civilTime(timeZone: string, t: number): CivilTime {
  if (timeZone === "UTC") {
    const d = new Date(t);
    return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate(),
      hour: d.getUTCHours(), minute: d.getUTCMinutes(), second: d.getUTCSeconds() };
  }
  let formatter = formatters.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat("en-US", {
      timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    formatters.set(timeZone, formatter);
  }
  const out = { year: 0, month: 0, day: 0, hour: 0, minute: 0, second: 0 };
  for (const part of formatter.formatToParts(new Date(t))) {
    if (part.type in out) (out as Record<string, number>)[part.type] = Number(part.value);
  }
  return out;
}

/** How far local time is ahead of UTC at instant `t`, in milliseconds. */
function offsetAt(timeZone: string, t: number): number {
  const c = civilTime(timeZone, t);
  const wholeSeconds = Math.floor(t / 1_000) * 1_000;
  return Date.UTC(c.year, c.month - 1, c.day, c.hour, c.minute, c.second) - wholeSeconds;
}

/** The instant a wall-clock time happens in a zone. */
function instantOf(timeZone: string, date: CivilDate, hour: number, minute: number): number {
  const wall = Date.UTC(date.year, date.month - 1, date.day, hour, minute, 0);
  if (timeZone === "UTC") return wall;
  let t = wall - offsetAt(timeZone, wall);
  const again = offsetAt(timeZone, t);
  if (wall - again !== t) t = wall - again;
  return t;
}

function addDays(date: CivilDate, days: number): CivilDate {
  const d = new Date(Date.UTC(date.year, date.month - 1, date.day + days));
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

/** 1 = Sunday … 7 = Saturday, as Foundation numbers them. */
function weekday(date: CivilDate): number {
  return new Date(Date.UTC(date.year, date.month - 1, date.day)).getUTCDay() + 1;
}

function compareCivil(a: CivilDate, b: CivilDate): number {
  return a.year - b.year || a.month - b.month || a.day - b.day;
}

function pad(n: number, width: number): string {
  return String(n).padStart(width, "0");
}

function keyOf(date: CivilDate): string {
  return `${pad(date.year, 4)}-${pad(date.month, 2)}-${pad(date.day, 2)}`;
}

/** The calendar date an instant falls on in a named zone. */
export function civilDateInZone(timeZone: string, t: number): CivilDate {
  const c = civilTime(timeZone, t);
  return { year: c.year, month: c.month, day: c.day };
}

/** The instant a wall-clock time on a calendar date happens in a named zone. */
export function instantInZone(timeZone: string, date: CivilDate, hour = 0, minute = 0): number {
  return instantOf(timeZone, date, hour, minute);
}

export const addCivilDays = (date: CivilDate, days: number): CivilDate => addDays(date, days);

/** "yyyy-MM-dd" for an instant in a named zone. */
export function dayKeyInZone(timeZone: string, t: number): string {
  return keyOf(civilTime(timeZone, t));
}

// MARK: Calendar

export interface Session { start: number; end: number }

/** The exchange's own time zone (UTC for crypto). */
export function timeZone(venue: Venue): string {
  return hours(venue)?.timeZone ?? "UTC";
}

/** First open and last close of a normal day, in minutes after local midnight; undefined for crypto. */
export function regularHours(venue: Venue): { timeZone: string; open: number; close: number } | undefined {
  const h = hours(venue);
  if (!h || h.segments.length === 0) return undefined;
  return { timeZone: h.timeZone, open: h.segments[0].open, close: h.segments[h.segments.length - 1].close };
}

/** Whether trading stops for lunch on a normal day. */
export function hasLunchBreak(venue: Venue): boolean {
  return (hours(venue)?.segments.length ?? 1) > 1;
}

/** The years this venue's holiday table is complete for; undefined when there is none. */
export function coveredYearsFor(venue: Venue): { lowerBound: number; upperBound: number } | undefined {
  return hours(venue)?.covered;
}

function isTradingCivilDay(h: Hours, date: CivilDate): boolean {
  const day = weekday(date);
  if (day < 2 || day > 6) return false;
  return !h.holidays.has(keyOf(date));
}

function segmentsOn(h: Hours, date: CivilDate): Session[] {
  if (!isTradingCivilDay(h, date)) return [];
  const cutoff = h.earlyCloses.get(keyOf(date));
  const out: Session[] = [];
  for (const segment of h.segments) {
    const close = cutoff === undefined ? segment.close : Math.min(segment.close, cutoff);
    if (!(close > segment.open)) continue;
    // Built from the wall-clock time so a daylight-saving change on the day can't shift the times.
    out.push({
      start: instantOf(h.timeZone, date, Math.floor(segment.open / 60), segment.open % 60),
      end: instantOf(h.timeZone, date, Math.floor(close / 60), close % 60),
    });
  }
  return out;
}

/** "yyyy-MM-dd" in the venue's own time zone (UTC for crypto). */
export function dayKey(venue: Venue, t: number): string {
  return dayKeyInZone(timeZone(venue), t);
}

/** Whether the holiday tables cover this date. Outside them, equity hours are a best guess. */
export function coversDate(venue: Venue, t: number): boolean {
  const h = hours(venue);
  if (!h) return true;
  if (!h.covered) return false;
  const year = civilTime(h.timeZone, t).year;
  return year >= h.covered.lowerBound && year <= h.covered.upperBound;
}

export function isTradingDay(venue: Venue, t: number): boolean {
  const h = hours(venue);
  if (!h) return true;
  return isTradingCivilDay(h, civilTime(h.timeZone, t));
}

/**
 * The trading segments on the venue-local day containing `t`, shortened on an early close;
 * empty when the venue is shut that day. Crypto returns the whole UTC day.
 */
export function segments(venue: Venue, t: number): Session[] {
  const h = hours(venue);
  if (!h) {
    const start = Math.floor(t / DAY_MS) * DAY_MS;
    return [{ start, end: start + DAY_MS }];
  }
  return segmentsOn(h, civilTime(h.timeZone, t));
}

function sessionOf(parts: Session[]): Session | undefined {
  if (parts.length === 0) return undefined;
  return { start: parts[0].start, end: parts[parts.length - 1].end };
}

/**
 * The regular session on the venue-local day containing `t`, from the first open to the
 * last close (lunch included); undefined when the venue is shut that day.
 */
export function session(venue: Venue, t: number): Session | undefined {
  return sessionOf(segments(venue, t));
}

export function isOpen(venue: Venue, t: number): boolean {
  if (venue === "crypto") return true;
  return segments(venue, t).some((part) => t >= part.start && t < part.end);
}

/** The next time trading starts strictly after `t` — after lunch counts (undefined for crypto). */
export function nextOpen(venue: Venue, t: number): number | undefined {
  const h = hours(venue);
  if (!h) return undefined;
  const today = civilTime(h.timeZone, t);
  for (let offset = 0; offset < 15; offset++) {
    const next = segmentsOn(h, addDays(today, offset)).find((part) => part.start > t);
    if (next) return next.start;
  }
  return undefined;
}

/** When the day's trading ends, for the session open at `t`, or the next one if shut. */
export function nextClose(venue: Venue, t: number): number | undefined {
  const h = hours(venue);
  if (!h) return undefined;
  const today = civilTime(h.timeZone, t);
  for (let offset = 0; offset < 15; offset++) {
    const s = sessionOf(segmentsOn(h, addDays(today, offset)));
    if (s && s.end > t) return s.end;
  }
  return undefined;
}

/**
 * A bar is complete once its period has ended. Signals only ever read complete bars:
 * today's daily bar keeps changing until the close, and acting on it would be trading
 * on a price that doesn't exist yet.
 */
export function isBarComplete(bar: Bar, timeframe: Timeframe, venue: Venue, now: number): boolean {
  if (timeframe === "hour") return now >= bar.time + timeframeSeconds(timeframe) * 1_000;
  if (venue === "crypto") return now >= bar.time + DAY_MS;
  // Daily equity bars are stamped on their session day (midnight or the open, exchange time).
  const s = session(venue, bar.time);
  if (!s) return now >= bar.time + DAY_MS;
  return now >= s.end;
}

/** The completed bars of a series, oldest first. */
export function completedBars(series: BarSeries, now: number): Bar[] {
  const bars = series.bars.slice();
  while (bars.length > 0 && !isBarComplete(bars[bars.length - 1], series.timeframe, series.instrument.venue, now)) {
    bars.pop();
  }
  return bars;
}

/** Trading days between two instants, used to judge whether a series has gone stale. */
export function tradingDays(venue: Venue, start: number, end: number): number {
  if (!(end > start)) return 0;
  const h = hours(venue);
  if (!h) return Math.trunc((end - start) / 1_000 / 86_400);
  let day: CivilDate = civilTime(h.timeZone, start);
  const last: CivilDate = civilTime(h.timeZone, end);
  let count = 0;
  while (compareCivil(day, last) < 0 && count < 400) {
    day = addDays(day, 1);
    if (isTradingCivilDay(h, day)) count += 1;
  }
  return count;
}

/**
 * Liquidity and volatility for each instrument with daily bars (`MarketSnapshot.stats` in
 * Swift). An instrument whose volume can't be trusted and has no market-wide figure gets
 * no stats at all — an unknown is reported as unknown, never as a small number.
 */
export function snapshotStats(snapshot: MarketSnapshot, now: number): Record<string, InstrumentStats> {
  const out: Record<string, InstrumentStats> = {};
  for (const [id, series] of Object.entries(snapshot.series)) {
    if (series.timeframe !== "day") continue;
    const measured = measureStats(completedBars(series, now));
    if (!measured) continue;
    if (series.volumeIsMarketWide) {
      out[id] = measured;
    } else {
      const known = snapshot.dollarVolume[id];
      if (known !== undefined && known > 0) out[id] = { averageDollarVolume: known, dailyVolatilityPct: measured.dailyVolatilityPct };
    }
  }
  return out;
}

export const MarketCalendar = {
  coveredYears, timeZone, regularHours, hasLunchBreak, coveredYearsFor, dayKey, coversDate, isTradingDay, segments, session, isOpen,
  nextOpen, nextClose, isBarComplete, completedBars, tradingDays, snapshotStats,
};
