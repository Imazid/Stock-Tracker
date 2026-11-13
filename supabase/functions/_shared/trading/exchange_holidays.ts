// Full-day closures and early closes for the international venues, from each exchange's
// published calendar. A port of TradingCore/Sources/TradingCore/ExchangeHolidays.swift —
// which is a placeholder until the verified tables land, so this is too. With no table, a
// venue still knows its weekly hours, and an unlisted holiday fails safe (no fresh quotes
// arrive, so nothing trades).
//
// When the Swift tables are filled in, the shared calendar vectors will fail until the
// same days are added here.

import type { Venue } from "./market.ts";

export const ExchangeHolidays: {
  /** Venue → full-day closures, "yyyy-MM-dd" in the exchange's own time zone. */
  closures: Partial<Record<Venue, string[]>>;
  /** Venue → early-close days, "yyyy-MM-dd" → last trading time "HH:mm" local. */
  earlyCloses: Partial<Record<Venue, Record<string, string>>>;
  /** Venue → the years the tables above are complete for. */
  coveredYears: Partial<Record<Venue, { lowerBound: number; upperBound: number }>>;
} = {
  closures: {},
  earlyCloses: {},
  coveredYears: {},
};
