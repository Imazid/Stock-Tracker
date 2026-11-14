import assert from "node:assert/strict";
import test from "node:test";
import { portfolioMovement, portfolioUnusualMoves } from "./portfolio-movement.ts";
import type { QuoteView } from "./market-types";

const quote = (id: string, currency: string, last: number, previousClose?: number): QuoteView => ({
  instrumentId: id, currency, last, previousClose, stale: false, source: "Test",
  status: "delayed", observedAt: "2026-11-12T01:00:00Z", fetchedAt: "2026-11-12T01:15:00Z",
  volumeScope: "unknown", notes: [],
});

test("aggregates duplicate positions and keeps each currency separate", () => {
  const prices = new Map([["us:AAPL", quote("us:AAPL", "USD", 115, 110)], ["asx:BHP", quote("asx:BHP", "AUD", 40, 43)]]);
  const result = portfolioMovement([
    { shares: 2, instrument: { id: "us:AAPL", currency: "USD" } },
    { shares: 1, instrument: { id: "us:AAPL", currency: "USD" } },
    { shares: 2, instrument: { id: "asx:BHP", currency: "AUD" } },
  ], (id) => prices.get(id));
  assert.deepEqual(result.totals, [["AUD", -6], ["USD", 15]]);
  assert.equal(result.covered, 3);
  assert.equal(result.contributions[0].id, "us:AAPL");
});

test("excludes stale, missing and mismatched quotes from coverage", () => {
  const holding = { shares: 3, instrument: { id: "us:AAPL", currency: "USD" } };
  for (const price of [undefined, quote("us:AAPL", "USD", 115), quote("us:AAPL", "AUD", 115, 110),
    { ...quote("us:AAPL", "USD", 115, 110), stale: true }]) {
    assert.deepEqual(portfolioMovement([holding], () => price), { covered: 0, contributions: [], totals: [] });
  }
});

test("ranks unusually large moves by percentage, including the exact threshold and negative moves", () => {
  const prices = new Map([["us:AAPL", quote("us:AAPL", "USD", 105, 100)], ["asx:BHP", quote("asx:BHP", "AUD", 180, 200)],
    ["us:SPY", quote("us:SPY", "USD", 51, 50)], ["us:AMZN", { ...quote("us:AMZN", "USD", 200, 50), stale: true }]]);
  const rows = [...prices.values()].map(({ instrumentId: id, currency }) => ({ shares: id === "us:SPY" ? 1000 : 1, instrument: { id, currency } }));
  const movement = portfolioMovement(rows, (id) => prices.get(id));
  assert.deepEqual(portfolioUnusualMoves(movement.contributions).map(({ id, changePct }) => [id, changePct]), [
    ["asx:BHP", -10], ["us:AAPL", 5],
  ]);
});
