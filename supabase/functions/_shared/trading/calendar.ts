// Regular trading sessions. A port of TradingCore/Sources/TradingCore/MarketCalendar.swift
// with the same holiday tables. Crypto never closes; US and ASX equities follow their
// exchange calendars. The tables need extending each year — after the last listed year
// the calendar still knows weekends but not holidays, so `coversDate` says whether a
// date is inside them.
//
// Time zones come from the runtime's own tz database through Intl (no clock is read:
// every instant is an argument).

import { type Bar, type BarSeries, type Timeframe, timeframeSeconds, type Venue } from "./market.ts";

interface Hours {
  timeZone: string;
  open: number; // minutes after local midnight
  close: number;
  earlyClose: number;
  holidays: Set<string>;
  earlyCloses: Set<string>;
}

const US: Hours = {
  timeZone: "America/New_York",
  open: 9 * 60 + 30,
  close: 16 * 60,
  earlyClose: 13 * 60,
  holidays: new Set([
    "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19",
    "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25",
    "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18",
    "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24",
  ]),
  earlyCloses: new Set(["2026-11-27", "2026-12-24", "2027-11-26"]),
};

const ASX: Hours = {
  timeZone: "Australia/Sydney",
  open: 10 * 60,
  close: 16 * 60,
  earlyClose: 14 * 60 + 10,
  holidays: new Set([
    "2026-01-01", "2026-01-26", "2026-04-03", "2026-04-06", "2026-06-08", "2026-12-25", "2026-12-28",
    "2027-01-01", "2027-01-26", "2027-03-26", "2027-03-29", "2027-06-14", "2027-12-27", "2027-12-28",
  ]),
  earlyCloses: new Set(["2026-12-24", "2026-12-31", "2027-12-24", "2027-12-31"]),
};

/** Years the holiday tables cover. */
export const coveredYears = { lowerBound: 2026, upperBound: 2027 };

const DAY_MS = 86_400_000;

function hours(venue: Venue): Hours | undefined {
  switch (venue) {
    case "us": return US;
    case "asx": return ASX;
    case "crypto": return undefined;
  }
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

function isTradingCivilDay(h: Hours, date: CivilDate): boolean {
  const day = weekday(date);
  if (day < 2 || day > 6) return false;
  return !h.holidays.has(keyOf(date));
}

function sessionOn(h: Hours, date: CivilDate): Session | undefined {
  if (!isTradingCivilDay(h, date)) return undefined;
  const closeMinute = h.earlyCloses.has(keyOf(date)) ? h.earlyClose : h.close;
  // Built from the wall-clock time so a daylight-saving change on the day can't shift the open.
  return {
    start: instantOf(h.timeZone, date, Math.floor(h.open / 60), h.open % 60),
    end: instantOf(h.timeZone, date, Math.floor(closeMinute / 60), closeMinute % 60),
  };
}

/** "yyyy-MM-dd" in the venue's own time zone (UTC for crypto). */
export function dayKey(venue: Venue, t: number): string {
  return dayKeyInZone(hours(venue)?.timeZone ?? "UTC", t);
}

/** Whether the holiday tables cover this date. Outside them, equity hours are a best guess. */
export function coversDate(venue: Venue, t: number): boolean {
  const h = hours(venue);
  if (!h) return true;
  const year = civilTime(h.timeZone, t).year;
  return year >= coveredYears.lowerBound && year <= coveredYears.upperBound;
}

export function isTradingDay(venue: Venue, t: number): boolean {
  const h = hours(venue);
  if (!h) return true;
  return isTradingCivilDay(h, civilTime(h.timeZone, t));
}

/**
 * The regular session on the venue-local day containing `t`; undefined when the venue is
 * shut that day. Crypto returns the whole UTC day.
 */
export function session(venue: Venue, t: number): Session | undefined {
  const h = hours(venue);
  if (!h) {
    const start = Math.floor(t / DAY_MS) * DAY_MS;
    return { start, end: start + DAY_MS };
  }
  return sessionOn(h, civilTime(h.timeZone, t));
}

export function isOpen(venue: Venue, t: number): boolean {
  if (venue === "crypto") return true;
  const s = session(venue, t);
  if (!s) return false;
  return t >= s.start && t < s.end;
}

/** The next regular open strictly after `t` (undefined for crypto, which is always open). */
export function nextOpen(venue: Venue, t: number): number | undefined {
  const h = hours(venue);
  if (!h) return undefined;
  const today = civilTime(h.timeZone, t);
  for (let offset = 0; offset < 15; offset++) {
    const s = sessionOn(h, addDays(today, offset));
    if (s && s.start > t) return s.start;
  }
  return undefined;
}

/** When the session that is open at `t` ends, or the end of the next one if shut. */
export function nextClose(venue: Venue, t: number): number | undefined {
  const h = hours(venue);
  if (!h) return undefined;
  const today = civilTime(h.timeZone, t);
  for (let offset = 0; offset < 15; offset++) {
    const s = sessionOn(h, addDays(today, offset));
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

export const MarketCalendar = {
  coveredYears, dayKey, coversDate, isTradingDay, session, isOpen, nextOpen, nextClose, isBarComplete, completedBars, tradingDays,
};
