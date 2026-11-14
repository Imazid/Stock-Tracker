import assert from "node:assert/strict";
import test from "node:test";
import { unifiedAllocation, type PrivateAllocationBucket } from "../../lib/unified-allocation.ts";

test("unified allocation keeps the denominator and coverage aligned with dated marks and exchange rates", () => {
  const listed = { total: 600, fxDates: ["2026-11-13"], assets: [
    { id: "equity", label: "Listed shares", value: 280, weight: 280 / 6 },
    { id: "etf", label: "ETFs", value: 200, weight: 200 / 6 },
    { id: "crypto", label: "Crypto", value: 120, weight: 20 },
  ] };
  const buckets: PrivateAllocationBucket[] = [
    { asset_class: "Startup equity", currency: "USD", position_count: 2, valued_count: 1, stale_count: 1,
      carrying_value: "200", oldest_valuation: "2026-07-05" },
    { asset_class: "Startup equity", currency: "AUD", position_count: 1, valued_count: 1, stale_count: 0,
      carrying_value: "100", oldest_valuation: "2026-11-11" },
    { asset_class: "Private equity", currency: "ZAR", position_count: 2, valued_count: 1, stale_count: 1,
      carrying_value: "10000.50", oldest_valuation: "2026-03-02" },
    { asset_class: "Venture fund", currency: "CAD", position_count: 1, valued_count: 1, stale_count: 0,
      carrying_value: "0", oldest_valuation: "2026-09-16" },
  ];
  const exposure = unifiedAllocation(listed, buckets, "AUD", { USD: {}, AUD: { USD: { rate: "1.5", date: "2026-11-12" } } });
  assert.equal(exposure.total, 1000);
  assert.deepEqual(exposure.rows.map(({ label, value, weight }) => [label, value, Math.round(weight)]), [
    ["Startup equity", 400, 40], ["Listed shares", 280, 28], ["ETFs", 200, 20],
    ["Crypto", 120, 12], ["Venture fund", 0, 0],
  ]);
  assert.equal(exposure.positions, 6);
  assert.equal(exposure.valued, 3);
  assert.equal(exposure.stale, 1);
  assert.equal(exposure.missingMarks, 2);
  assert.equal(exposure.missingRates, 1);
  assert.equal(exposure.oldestValuation, "2026-07-05");
  assert.deepEqual(exposure.fxDates, ["2026-11-12", "2026-11-13"]);
});
