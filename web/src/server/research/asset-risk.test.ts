import assert from "node:assert/strict";
import test from "node:test";
import { assetRisk } from "../../lib/asset-risk.ts";
import type { CandlesView, InstrumentView } from "../../lib/market-types.ts";

function history(venue: InstrumentView["venue"], fetchedAt: string, rows: [string, number][]): CandlesView {
  return {
    instrument: { id: `${venue}:TEST`, symbol: "TEST", name: "Test", assetClass: venue === "crypto" ? "crypto" : "equity",
      venue, venueName: venue, venueShort: venue, currency: "USD" },
    range: "3M", interval: "1d", intraday: false, currency: "USD", source: "Sample", status: "indicative",
    fetchedAt, adjustment: "Split-adjusted", volumeScope: "unknown", notes: [],
    market: { venue, isOpen: false, calendarCovered: true, label: "Closed" },
    candles: rows.map(([time, price]) => ({ time: Date.parse(time) / 1000, open: price, high: price, low: price, close: price, volume: 0 })),
  };
}

test("uses the greatest decline from a prior close and rejects the cached unfinished session", () => {
  const source = history("us", "2026-11-16T16:00:00Z", [
    ["2026-11-09T14:30:00Z", 100], ["2026-11-10T14:30:00Z", 150], ["2026-11-11T14:30:00Z", 75],
    ["2026-11-12T14:30:00Z", 200], ["2026-11-13T14:30:00Z", 120], ["2026-11-16T14:30:00Z", 20],
  ]);
  const result = assetRisk(source, Date.parse("2026-11-16T21:05:00Z"))!;
  assert.equal(result.sessions, 5);
  assert.equal(result.missingSessions, 0);
  assert.equal(result.missedRecentSessions, 1);
  assert.equal(result.maxDrawdownPct, 50);
  assert.equal(result.drawdownPeakDate, "2026-11-10");
  assert.equal(result.drawdownTroughDate, "2026-11-11");
  assert.equal(result.through, "2026-11-13");
  assert(Math.abs(result.priceChangePct! - 20) < 1e-10);
  assert.equal(result.dailyVolatilityPct, null);
});

test("volatility matches the sample standard deviation of 20 consecutive UTC crypto changes", () => {
  let price = 100;
  const days = Array.from({ length: 22 }, (_, index): [string, number] => {
    if (index > 0) price *= index % 2 === 0 ? 0.99 : 1.01;
    return [new Date(Date.UTC(2026, 9, 1 + index)).toISOString(), price];
  });
  const fetched = "2026-10-22T10:00:00Z";
  const result = assetRisk(history("crypto", fetched, [...days].reverse()), Date.parse(fetched))!;
  assert.equal(result.sessions, 21);
  assert.equal(result.volatilityFrom, "2026-10-01");
  assert.equal(result.through, "2026-10-21");
  assert.equal(result.missedRecentSessions, 0);
  assert(Math.abs(result.dailyVolatilityPct! - Math.sqrt(20 / 19)) < 1e-10);
  const missing = assetRisk(history("crypto", fetched, days.filter((_, i) => i !== 14)), Date.parse(fetched))!;
  assert.equal(missing.missingSessions, 1);
  assert.equal(missing.dailyVolatilityPct, null);
});

test("dates follow the venue and duplicate, nonpositive and future closes are excluded", () => {
  const fetched = "2026-11-14T18:00:00Z";
  const source = history("asx", fetched, [
    ["2026-11-10T23:00:00Z", 10], ["2026-11-12T00:00:00Z", 1], ["2026-11-12T04:00:00Z", 50],
    ["2026-11-12T23:00:00Z", 12], ["2026-11-13T23:00:00Z", 100],
    ["2026-11-09T23:00:00Z", 0], ["2026-11-16T01:00:00Z", 900],
  ]);
  const result = assetRisk(source, Date.parse(fetched))!;
  assert.equal(result.sessions, 2);
  assert.equal(result.missingSessions, 1);
  assert.equal(result.from, "2026-11-11");
  assert.equal(result.through, "2026-11-13");
  assert.equal(result.maxDrawdownPct, 0);
  assert.equal(assetRisk({ ...source, interval: "1h" }, Date.parse(fetched)), undefined);
});
