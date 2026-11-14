import assert from "node:assert/strict";
import test from "node:test";
import { marketSearchParams, parseSearchFilters, selectMarketSearchResults } from "./market-search.ts";
import type { SearchResult } from "./market-types.ts";
import { parseRecentSearches } from "./recent-searches.ts";

const compare = (a: SearchResult, b: SearchResult) => a.symbol.localeCompare(b.symbol);

function result(symbol: string, venue: SearchResult["venue"], assetClass: SearchResult["assetClass"] = "equity"): SearchResult {
  return { id: `${venue}:${symbol}`, venue, symbol, assetClass, name: symbol,
    venueName: venue, venueShort: venue, currency: venue === "asx" ? "AUD" : "USD", origin: "catalog" };
}

test("filters market and asset type before ranking and capping the results", () => {
  const listing = result("XYZ", "asx", "etf");
  const input = Array.from({ length: 24 }, (_, index) => result(`A${index}`, "us", "etf")).concat(
    [result("A", "asx"), result("^AXJO", "asx"), listing, result("XYZ", "us", "etf")]);
  assert.equal(selectMarketSearchResults(input, parseSearchFilters("all", ""), true, compare).length, 20);
  assert.deepEqual(selectMarketSearchResults(input, parseSearchFilters("etfs", "asx"), true, compare), [listing]);
  assert.deepEqual(selectMarketSearchResults(input, parseSearchFilters("indexes", "asx"), true, compare).map(({ id }) => id), ["asx:^AXJO"]);
  assert.equal(selectMarketSearchResults(input, parseSearchFilters("indexes", ""), false, compare).length, 0);
});

test("keeps query punctuation and case-sensitive venue IDs in search links", () => {
  const filters = parseSearchFilters("stocks", "euronextParis");
  const params = marketSearchParams("A&B + C", filters);
  assert.equal(params.get("q"), "A&B + C");
  assert.equal(params.get("market"), "euronextParis");
  assert.equal(params.get("assetType"), "stocks");
  assert.deepEqual(parseSearchFilters("crypto", "asx"), { assetType: "crypto", market: "" });
});

test("reads only valid recent queries and preserves distinct listing filters", () => {
  const input = JSON.stringify([
    { query: " BHP ", assetType: "stocks", market: "asx" }, { query: "bhp", assetType: "stocks", market: "asx" },
    null, { query: "BHP", assetType: "stocks", market: "us" }, { query: "" },
  ]);
  assert.deepEqual(parseRecentSearches(input), [
    { query: "BHP", assetType: "stocks", market: "asx" }, { query: "BHP", assetType: "stocks", market: "us" },
  ]);
  assert.deepEqual(parseRecentSearches("broken storage"), []);
});
