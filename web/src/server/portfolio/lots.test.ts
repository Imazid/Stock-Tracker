import { strict as assert } from "node:assert";
import { test } from "node:test";
import { calculateLots, lotNumber, sydneyDate, UNIT_DECIMALS } from "./lots.ts";
import type { TransactionRow } from "./transactions.ts";

function trade(id: string, date: string, type: string, shares: number, price: number, fees = 0, holding = "first"): TransactionRow {
  return { id, holding_id: holding, transaction_date: date, type, shares, price_per_share: price, fees, portfolio_holdings: null };
}

test("snapshot and unknown-cost units stay in FIFO order without producing a basis", () => {
  const snapshot = { ...trade("snapshot", "2026-06-29T00:00:00Z", "Buy", 2, 12),
    trade_provenance: { source: "broker_position" as const, currency: "AUD", unitPrice: 18 } };
  const missing = { ...trade("missing", "2026-06-30T00:00:00Z", "Buy", 1, 0),
    trade_provenance: { source: "opening_position" as const } };
  const manual = { ...trade("buy", "2026-07-01T00:00:00Z", "Buy", 1, 15),
    trade_provenance: { source: "manual_trade" as const, currency: "AUD", unitPrice: 22.5 } };
  const sale = trade("sell", "2026-07-03T00:00:00Z", "Sell", 4, 25, 2);
  const rows = calculateLots([sale, manual, snapshot, missing]);
  assert.deepEqual(rows.map(row => [row.kind, row.purchase?.id, row.purchaseCost, row.saleFee, row.result]), [
    ["Unmatched sale", "snapshot", undefined, 100n, undefined],
    ["Unmatched sale", "missing", undefined, 50n, undefined],
    ["Sale match", "buy", 1500n, 50n, 950n],
  ]);
  assert.deepEqual(calculateLots([snapshot]).map(row => [row.kind, row.purchaseCost]), [["Position record", undefined]]);
});

test("FIFO retains acquisition IDs and allocates each cent exactly across sales and remaining units", () => {
  const result = calculateLots([
    trade("sale", "2026-07-04T00:00:00Z", "Sell", 4, 20, 0.05),
    trade("second", "2026-07-02T00:00:00Z", "Buy", 3, 12, 0.03),
    trade("first", "2026-06-30T00:00:00Z", "Buy", 2, 10, 0.01),
  ]);
  assert.deepEqual(result.map((row) => [row.kind, row.purchase?.id, row.purchaseCost, row.purchaseFee, row.saleProceeds, row.saleFee, row.result]), [
    ["Sale match", "first", 2000n, 1n, 4000n, 3n, 1996n],
    ["Sale match", "second", 2400n, 2n, 4000n, 2n, 1596n],
    ["Open lot", "second", 1200n, 1n, undefined, undefined, undefined],
  ]);
});

test("earlier sales consume lots and missing basis cannot use future purchases or a different holding", () => {
  const result = calculateLots([
    trade("old-buy", "2026-06-01T00:00:00Z", "Buy", 1, 10),
    trade("old-sell", "2026-06-02T00:00:00Z", "Sell", 1, 20),
    trade("unmatched", "2026-07-01T00:00:00Z", "Sell", 2, 20, 1),
    trade("foreign-lot", "2026-05-01T00:00:00Z", "Buy", 2, 10, 0, "second"),
    trade("future-buy", "2026-07-02T00:00:00Z", "Buy", 1, 10),
  ], "2026-07-01");
  assert.deepEqual(result.map((row) => [row.kind, row.transaction.id, row.units, row.result]), [
    ["Unmatched sale", "unmatched", 2_000_000_000_000_000_000n, undefined],
    ["Open lot", "foreign-lot", 2_000_000_000_000_000_000n, undefined],
    ["Open lot", "future-buy", 1_000_000_000_000_000_000n, undefined],
  ]);
});

test("uses Sydney financial-year boundaries, fractional units, and sale-first timestamp ties", () => {
  assert.equal(sydneyDate("2026-06-30T14:00:00Z"), "2026-07-01");
  assert.equal(sydneyDate("2026-01-02T13:00:00Z"), "2026-01-03");
  const result = calculateLots([
    trade("buy", "2026-06-30T13:59:59.999998Z", "Buy", 0.00000001, 1_000_000_000),
    trade("early-sale", "2026-06-30T13:59:59.999999Z", "Sell", 0.00000001, 500_000_000),
    trade("tie-buy", "2026-06-30T14:00:00.000001Z", "Buy", 0.1, 10.05),
    trade("tie-sale", "2026-06-30T14:00:00.000001Z", "Sell", 0.1, 12),
    trade("outside", "2026-07-01T14:00:00Z", "Buy", 1, 10),
  ], "2026-07-01", "2026-07-01");
  assert.deepEqual(result.map((row) => [row.kind, row.transaction.id]), [["Unmatched sale", "tie-sale"], ["Open lot", "tie-buy"]]);
  assert.equal(result[1].purchaseCost, 101n);
  assert.equal(lotNumber(result[1].units, UNIT_DECIMALS), "0.1");
  assert.equal(lotNumber(-25n, 2), "-0.25");
});

test("flags unusable history and stops calculating basis only for the affected holding", () => {
  const result = calculateLots([
    trade("bad-time", "infinity", "Buy", 1, 20),
    trade("purchase", "2026-06-01T00:00:00Z", "Buy", 1, 10),
    trade("sale", "2026-07-01T00:00:00Z", "Sell", 1, 20),
    trade("other", "2026-06-01T00:00:00Z", "Buy", 1, 10, 0, "second"),
  ], "2026-07-01");
  assert.deepEqual(result.map((row) => [row.kind, row.transaction.id, row.result]), [
    ["Invalid transaction", "bad-time", undefined],
    ["Unmatched sale", "sale", undefined],
    ["Open lot", "other", undefined],
  ]);
});

test("labels lots from archived holdings separately once the report reaches the archive date", () => {
  const purchase = trade("purchase", "2026-06-01T00:00:00Z", "Buy", 1, 10);
  purchase.portfolio_holdings = { asset_symbol: "XYZ", asset_exchange: null, asset_kind: "Stock", deleted_at: "2026-07-01T14:00:00Z" };
  assert.equal(calculateLots([purchase], undefined, "2026-07-01")[0].kind, "Open lot");
  assert.equal(calculateLots([purchase], undefined, "2026-07-02")[0].kind, "Archived holding lot");
  assert.equal(calculateLots([purchase])[0].kind, "Archived holding lot");
});
