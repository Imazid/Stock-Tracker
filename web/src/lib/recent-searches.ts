import { maxSearchLength, parseSearchFilters, type SearchFilters } from "./market-search.ts";

const key = "st-recent-searches";
const changed = "st-recent-searches-changed";
const limit = 6;

export type RecentSearch = SearchFilters & { query: string };

function identity({ query, assetType, market }: RecentSearch) {
  return JSON.stringify([query.toLowerCase(), assetType, market]);
}

export function searchHistorySnapshot() {
  try { return localStorage.getItem(key) ?? ""; }
  catch { return ""; }
}

export function parseRecentSearches(raw: string): RecentSearch[] {
  try {
    const saved: unknown = JSON.parse(raw);
    if (!Array.isArray(saved)) return [];
    const entries = new Map<string, RecentSearch>();
    for (const row of saved) {
      const query = typeof row?.query === "string" ? row.query.trim() : "";
      if (!query || query.length > maxSearchLength) continue;
      const entry = { query, ...parseSearchFilters(row.assetType, row.market) };
      const id = identity(entry);
      if (!entries.has(id)) entries.set(id, entry);
      if (entries.size === limit) break;
    }
    return [...entries.values()];
  } catch { return []; }
}

export function subscribeSearchHistory(notify: () => void) {
  const onStorage = (event: StorageEvent) => { if (event.key === key || event.key === null) notify(); };
  window.addEventListener(changed, notify);
  window.addEventListener("storage", onStorage);
  return () => {
    window.removeEventListener(changed, notify);
    window.removeEventListener("storage", onStorage);
  };
}

export function recordSearch(query: string, filters: SearchFilters) {
  const clean = query.trim();
  if (!clean || clean.length > maxSearchLength) return;
  const entry: RecentSearch = { query: clean, ...filters };
  try {
    const next = [entry, ...parseRecentSearches(searchHistorySnapshot()).filter((recent) => identity(recent) !== identity(entry))];
    localStorage.setItem(key, JSON.stringify(next.slice(0, limit)));
    window.dispatchEvent(new Event(changed));
  } catch { /* Search remains usable when browser storage is unavailable. */ }
}

export function clearSearchHistory() {
  try {
    localStorage.removeItem(key);
    window.dispatchEvent(new Event(changed));
  } catch { /* Search remains usable when browser storage is unavailable. */ }
}
