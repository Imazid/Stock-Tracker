// Canonical instruments. A ticker isn't globally unique ("BHP" trades in Sydney and
// London), so everything is keyed by the engine's instrumentID: `${venue}:${symbol}`.

import { MarketCalendar } from "@engine/calendar.ts";
import {
  type Instrument,
  makeInstrument,
  type Venue,
  VENUES,
} from "@engine/market.ts";
import { toView as clientToView } from "@/lib/instrument-view";
import { marketIndexes } from "@/lib/market-indexes";
import { marketCatalog } from "@/lib/market-catalog";
import type { InstrumentView, MarketStateView } from "@/lib/market-types";

const SYMBOL_PATTERN = /^[A-Z0-9][A-Z0-9.\-&]{0,19}$/;

export class BadInstrumentError extends Error {}

/** "us:AAPL" → Instrument. Throws BadInstrumentError for anything malformed. */
export function parseInstrumentID(raw: string, { allowIndex = false } = {}): Instrument {
  let decoded: string;
  try { decoded = decodeURIComponent(raw).trim(); }
  catch { throw new BadInstrumentError("That symbol isn't valid."); }
  const colon = decoded.indexOf(":");
  if (colon <= 0) throw new BadInstrumentError("An instrument id looks like venue:SYMBOL, e.g. us:AAPL.");
  const venue = decoded.slice(0, colon) as Venue;
  const symbol = decoded.slice(colon + 1).toUpperCase();
  if (!VENUES.includes(venue)) throw new BadInstrumentError(`Unknown venue "${decoded.slice(0, colon)}".`);
  if (allowIndex) {
    const index = marketIndexes.find((item) => item.venue === venue && item.symbol === symbol);
    if (index) return index;
  }
  if (!SYMBOL_PATTERN.test(symbol)) throw new BadInstrumentError("That symbol isn't valid.");
  const known = marketCatalog.find((instrument) => instrument.symbol === symbol && instrument.venue === venue);
  if (known) return known;
  return makeInstrument(symbol, venue === "crypto" ? "crypto" : "equity", venue);
}

export function toView(instrument: Instrument, nameOverride?: string): InstrumentView {
  const view = clientToView(instrument);
  return nameOverride && nameOverride.trim() !== "" ? { ...view, name: nameOverride } : view;
}

function localTime(t: number, timeZone?: string): string {
  return new Intl.DateTimeFormat("en-AU", {
    weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false, timeZone, timeZoneName: "short",
  }).format(new Date(t));
}

export function marketState(venue: Venue, now = Date.now()): MarketStateView {
  if (venue === "crypto") return { venue, isOpen: true, calendarCovered: true, label: "Open 24/7" };
  const covered = MarketCalendar.coversDate(venue, now);
  const isOpen = MarketCalendar.isOpen(venue, now);
  const nextOpen = MarketCalendar.nextOpen(venue, now);
  const nextClose = MarketCalendar.nextClose(venue, now);
  const tz = MarketCalendar.timeZone(venue);
  let label: string;
  if (isOpen) label = nextClose ? `Open · closes ${localTime(nextClose, tz)}` : "Open";
  else label = nextOpen ? `Closed · opens ${localTime(nextOpen, tz)}` : "Closed";
  if (!covered) label += " · holidays not checked for this market";
  return {
    venue,
    isOpen,
    calendarCovered: covered,
    nextOpen: nextOpen ? new Date(nextOpen).toISOString() : undefined,
    nextClose: nextClose ? new Date(nextClose).toISOString() : undefined,
    label,
  };
}
