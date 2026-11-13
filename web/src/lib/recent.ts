// Recently viewed instruments, per browser. Storage can be missing or blocked (private
// mode); every access is wrapped and the feature just stays empty then.

import type { InstrumentView } from "@/lib/market-types";

const KEY = "st-recent-instruments";
const MAX = 12;

export type RecentInstrument = Pick<InstrumentView, "id" | "symbol" | "name" | "venueShort" | "assetClass">;

export function readRecent(): RecentInstrument[] {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((x): x is RecentInstrument => typeof x === "object" && x !== null && typeof (x as RecentInstrument).id === "string").slice(0, MAX);
  } catch {
    return [];
  }
}

export function pushRecent(instrument: RecentInstrument): void {
  try {
    const next = [instrument, ...readRecent().filter((r) => r.id !== instrument.id)].slice(0, MAX);
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    // ignore
  }
}

export function clearRecent(): void {
  try {
    localStorage.removeItem(KEY);
  } catch {
    // ignore
  }
}
