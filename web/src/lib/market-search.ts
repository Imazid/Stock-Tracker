import { VENUES, venueDisplayName } from "../../../supabase/functions/_shared/trading/market.ts";
import type { SearchResult } from "./market-types.ts";

export const assetTypes = [
  ["all", "All assets"], ["stocks", "Stocks"], ["etfs", "ETFs"], ["crypto", "Crypto"], ["indexes", "Indexes"],
] as const;
export type SearchAssetType = (typeof assetTypes)[number][0];
export const searchMarkets = VENUES.filter((venue) => venue !== "crypto").map((venue) => [venue, venueDisplayName(venue)] as const);
export type SearchMarket = (typeof searchMarkets)[number][0];
export type SearchFilters = { assetType: SearchAssetType; market: SearchMarket | "" };
export const allSearchFilters: SearchFilters = { assetType: "all", market: "" };
export const maxSearchLength = 64;

export function searchAssetType(value: unknown): SearchAssetType | undefined {
  return assetTypes.find(([key]) => key === value)?.[0];
}

export function searchMarket(value: unknown): SearchMarket | undefined {
  return searchMarkets.find(([key]) => key === value)?.[0];
}

export function parseSearchFilters(assetType: unknown, market: unknown): SearchFilters {
  const type = searchAssetType(assetType) ?? "all";
  return { assetType: type, market: type === "crypto" ? "" : searchMarket(market) ?? "" };
}

export function marketSearchParams(query: string, filters: SearchFilters) {
  const params = new URLSearchParams({ q: query });
  if (filters.assetType !== "all") params.set("assetType", filters.assetType);
  if (filters.market) params.set("market", filters.market);
  return params;
}

function matchesMarketSearch(result: SearchResult, filters: SearchFilters, includeIndexes: boolean) {
  if (filters.market && result.venue !== filters.market) return false;
  const index = result.symbol.startsWith("^");
  switch (filters.assetType) {
    case "stocks": return !index && result.assetClass === "equity";
    case "etfs": return result.assetClass === "etf";
    case "crypto": return result.assetClass === "crypto";
    case "indexes": return includeIndexes && index;
    default: return includeIndexes || !index;
  }
}

export function selectMarketSearchResults(results: Iterable<SearchResult>, filters: SearchFilters, includeIndexes: boolean,
  compare: (left: SearchResult, right: SearchResult) => number) {
  return [...results].filter((result) => matchesMarketSearch(result, filters, includeIndexes)).sort(compare).slice(0, 20);
}
