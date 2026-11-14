import assert from "node:assert/strict";
import { test } from "node:test";
import type { PortfolioHolding } from "../../app/private-markets/private-data.ts";
import { privatePositionPerformance } from "../../app/private-markets/private-performance.ts";

const today = "2026-01-01";
const asOf = Date.parse("2025-12-31T15:00:00Z");
const mark = (value: number, day: string, revision: string | null = null) => ({
  id: day, value, valued_on: day, source: "Fund report", methodology: "NAV", provider_event_at: revision,
});
const position: PortfolioHolding = {
  id: "fund", name: "Venture fund fixture", asset_class: "Venture fund", currency: "AUD",
  units: 100, remaining_units: null, ownership_percent: null, settled_amount: 1_000, committed_amount: 2_000,
  settled_on: "2025-01-01", settlement_source: "Manager statement", last_disposition_on: null,
  disposition_revision_at: null, exit_source: null, commitment: { provider: "angellist", provider_reference: null },
  marks: [mark(1_250, today)], calls: [{ id: "pending", amount: 200, due_on: "2026-01-03", settled_on: null, source: "Call notice" }],
  distributions: [{ id: "receipt", amount: 250, received_on: today, source: "Receipt" }],
  cancelled_calls: [], dispositions: [],
};
const calculate = (holding: PortfolioHolding) => privatePositionPerformance(holding, today, asOf);

test("fund performance uses dated settled cash flows and excludes pending calls from deployed capital", () => {
  const { metrics, mark: selected } = calculate(position);
  assert.ok(metrics);
  assert.equal(selected?.valued_on, today);
  assert.equal(metrics.paid, 1_000);
  assert.equal(metrics.pending, 200);
  assert.equal(metrics.uncalled, 1_000);
  assert.equal(metrics.returned, 250);
  assert.equal(metrics.netGain, 500);
  assert.equal(metrics.multipleLabel, "TVPI");
  assert.equal(metrics.multiple, 1.5);
  assert.equal(metrics.dpi, 0.25);
  assert.ok(Math.abs(metrics.xirr! - 0.5) < 1e-10);
  assert.equal(metrics.unrealized, null);
});

test("later cash flows invalidate mark-based ratios and later contributions can invalidate XIRR", () => {
  const older = calculate({ ...position, marks: [mark(1_250, "2025-10-01")] });
  assert.ok(older.stale);
  assert.equal(older.metrics?.multiple, null);
  assert.equal(older.metrics?.xirr, null);
  assert.equal(older.metrics?.dpi, 0.25);
  const laterContribution = { id: "paid", source: "Call notice", amount: 100, due_on: today, settled_on: today };
  const irregular = calculate({
    ...position,
    distributions: [{ ...position.distributions[0], received_on: "2025-04-01" }],
    calls: [{ ...laterContribution, settled_on: "2025-06-01" }],
  });
  assert.equal(irregular.metrics?.xirr, null);
  assert.equal(irregular.metrics?.paid, 1_100);
  assert.equal(irregular.metrics?.netGain, 400);
});

test("dispositions require a valid mark revision or a confirmed full exit and reported cost basis", () => {
  const sale = { id: "sale", source: "Broker statement", sold_units: 70, net_proceeds: 800, disposed_cost: 700, settled_on: "2025-11-01" };
  const sold = {
    ...position, remaining_units: 30, last_disposition_on: sale.settled_on, disposition_revision_at: "2025-11-05T00:00:00Z",
    marks: [
      mark(900, today, "2026-01-01T00:00:00Z"),
      mark(850, "2025-12-20", "2025-11-04T00:00:00Z"),
      mark(550, "2025-12-09", "2025-12-09T00:00:00Z"),
    ],
    distributions: [], dispositions: [sale],
  };
  const { metrics, mark: selected } = calculate(sold);
  assert.equal(selected?.value, 550);
  assert.equal(metrics?.realized, 100);
  assert.equal(metrics?.unrealized, 250);
  assert.equal(metrics?.multipleLabel, "MOIC");
  assert.equal(metrics?.multiple, 1.35);
  const unknownBasis = calculate({ ...sold, dispositions: [{ ...sale, disposed_cost: null }] });
  assert.equal(unknownBasis.metrics?.realized, null);
  assert.equal(unknownBasis.metrics?.unrealized, null);
  const exited = calculate({ ...sold, remaining_units: 0, exit_source: "Final sale statement", marks: [] });
  assert.ok(exited.exited);
  assert.equal(exited.metrics?.unrealized, 0);
  assert.equal(exited.metrics?.multiple, 0.8);
});

test("activity lookahead, missing opening evidence and zero valuations remain distinct", () => {
  assert.equal(calculate({ ...position, calls: Array.from({ length: 101 }, () => position.calls[0]) }).metrics, null);
  assert.equal(calculate({ ...position, settled_on: null }).metrics, null);
  assert.equal(calculate({ ...position, last_disposition_on: "2025-11-01" }).completeActivity, false);
  const zero = calculate({ ...position, marks: [mark(0, today)] });
  assert.equal(zero.mark?.value, 0);
  assert.equal(zero.metrics?.netGain, -750);
});
