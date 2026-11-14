import assert from "node:assert/strict";
import test from "node:test";
import { snapshotHistory, statementHistory, type StatementPeriod } from "../../lib/portfolio-history.ts";

const today = Date.parse("2026-11-14");
const older: StatementPeriod = {
  starts_on: "2026-10-21", ends_on: "2026-11-08", opening_value_usd: "1000.00", closing_value_usd: "1100.00",
  deposits_usd: "0", withdrawals_usd: "0", investment_change_usd: "100.00", twr_factor: 1.1, twr_invested: true,
};
const latest: StatementPeriod = {
  starts_on: "2026-11-08", ends_on: "2026-11-14", opening_value_usd: "1100.00", closing_value_usd: "1770.00",
  deposits_usd: "500", withdrawals_usd: "50", investment_change_usd: "220.00", twr_factor: 1.2, twr_invested: true,
};

test("includes daily endpoints and leaves missing days empty", () => {
  const rows = [
    { snapshot_date: "2025-05-12", total_value: 10 },
    { snapshot_date: "2026-11-07", total_value: 900 },
    { snapshot_date: "2026-11-13", total_value: 0 },
    { snapshot_date: "2026-11-14", total_value: 1300 },
    { snapshot_date: "2026-11-15", total_value: 4000 },
    { snapshot_date: "2026-11-16", total_value: Infinity },
  ];
  assert.deepEqual(snapshotHistory(rows, today, "1D").map((p) => p.value), [0, 1300]);
  assert.deepEqual(snapshotHistory(rows, today, "1W").map((p) => p.value), [900, 0, 1300]);
  assert.deepEqual(snapshotHistory(rows, today, "ALL").map((p) => p.value), [10, 900, 0, 1300]);
});

test("links complete periods and keeps net transfers distinct from investment change", () => {
  const month = statementHistory([latest, older], today, "1M");
  assert.deepEqual(month.investment.map((p) => p.value), [0, 100, 320]);
  assert.deepEqual(month.transfers.map((p) => p.value), [0, 0, 450]);
  assert(Math.abs(month.timeWeighted! - 32) < 1e-10);
  assert.equal(month.periods, 2);
  assert.deepEqual(statementHistory([latest, older], today, "1W").investment.map((p) => p.value), [0, 220]);
  assert.equal(statementHistory([latest, older], today, "1D").periods, 0);
});

test("stops at gaps or inconsistent balances and preserves missing time-weighted return", () => {
  const missing = { ...latest, twr_factor: null, twr_invested: null };
  for (const earlier of [{ ...older, ends_on: "2026-11-07" }, { ...older, closing_value_usd: "1100.01" }]) {
    const result = statementHistory([missing, earlier], today, "ALL");
    assert.equal(result.periods, 1);
    assert.equal(result.timeWeighted, null);
    assert.equal(result.investment.at(-1)?.value, 220);
  }
  assert.equal(statementHistory([{ ...latest, twr_factor: 0 }, older], today, "ALL").timeWeighted, -100);
  const negative = statementHistory([{ ...latest, investment_change_usd: "-50.01", deposits_usd: "0", withdrawals_usd: "50" }], today, "ALL");
  assert.equal(negative.investment.at(-1)?.value, -50.01);
  assert.equal(negative.transfers.at(-1)?.value, -50);
});
