import assert from "node:assert/strict";
import test from "node:test";
import type { StockSpinOff } from "../../lib/portfolio-spin-offs.ts";
import type { StockTransfer, TransferHolding } from "../../lib/portfolio-transfers.ts";
import { portfolioGains } from "./gains.ts";
import { calculateLots, lotNumber, UNIT_DECIMALS } from "./lots.ts";
import type { TransactionRow } from "./transactions.ts";

const parent: TransferHolding = { id: "parent", asset_symbol: "BHP", asset_exchange: "ASX", asset_kind: "Stock",
  date_added: "2025-01-01", deleted_at: null };
const child: TransferHolding = { ...parent, id: "child", asset_symbol: "BSL" };
const action: StockSpinOff = {
  id: "action", parent_holding_id: parent.id, child_holding_id: child.id, parent, child,
  effective_on: "2025-02-03", parent_shares: "280", child_shares: "56",
  child_basis_pct_usd: "20", child_basis_pct_aud: "5.063", average_aud_basis: true,
  statement_reference: "Example with separate USD and AUD allocations", child_snapshot_id: null, child_snapshot: null, updated_at: "",
};

function trade(id: string, holding: TransferHolding, date: string, shares: number, price: number, fees = 0,
  type = "Buy"): TransactionRow {
  return { id, holding_id: holding.id, portfolio_holdings: holding, transaction_date: date + "T00:00:00Z",
    shares, price_per_share: price, fees, type,
    trade_provenance: { source: "manual_trade", currency: "AUD", unitPrice: price, fees } };
}

const purchases = [
  trade("parent-a", parent, "2025-01-01", 100, 5, 4),
  trade("parent-b", parent, "2025-01-02", 180, 11, 16),
];
const snapshot = { ...trade("snapshot", child, "2025-02-04", 56, 22),
  trade_provenance: { source: "broker_position" as const }, deleted_at: null };
const withSnapshot: StockSpinOff = {
  ...action, child_snapshot_id: snapshot.id, child_snapshot: { ...snapshot, shares: Number(snapshot.shares) },
};
const one = new Map(["parent-a", "parent-b", "sale", "parent-sale"].map((id) => [id, "1"]));

test("spins off USD by lot and the averaged AUD cost pool using separate confirmed allocations", () => {
  const before = calculateLots([...purchases, snapshot], undefined, "2025-02-02", one, [], [], [withSnapshot]);
  assert.equal(before.length, 2);
  const rows = calculateLots([...purchases, snapshot], undefined, undefined, one, [], [], [withSnapshot]);
  const event = rows.filter((row) => "spinOff" in row).find((row) => row.kind === "Stock spin-off");
  assert.deepEqual(event?.usd, { gross: 49600n, fee: 400n });
  assert.deepEqual(event?.aud, { gross: 12557n, fee: 101n });
  const open = rows.filter((row) => "transaction" in row).filter((row) => row.kind === "Open lot");
  assert.deepEqual(open.map((row) => ({
    holding: row.transaction.holding_id, source: row.purchase?.id, date: row.allottedOn,
    units: lotNumber(row.units, UNIT_DECIMALS), usd: row.purchaseCost, aud: row.aud?.purchaseCost,
  })), [
    { holding: "parent", source: "parent-a", date: undefined, units: "100", usd: 40000n, aud: 84087n },
    { holding: "parent", source: "parent-b", date: undefined, units: "180", usd: 158400n, aud: 151356n },
    { holding: "child", source: "parent-a", date: "2025-02-03", units: "20", usd: 10000n, aud: 4485n },
    { holding: "child", source: "parent-b", date: "2025-02-03", units: "36", usd: 39600n, aud: 8072n },
  ]);
  assert.equal(open.reduce((sum, row) => sum + row.aud!.purchaseCost! + row.aud!.purchaseFee!, 0n), 250000n);
  assert.equal(open.reduce((sum, row) => sum + row.purchaseCost! + row.purchaseFee!, 0n), 250000n);
});

test("applies before same-day sales, uses allotment FIFO order and keeps the source purchase evidence", () => {
  const beforeAllotment = trade("child-buy", child, "2025-01-15", 2, 8);
  const sale = trade("sale", child, "2025-02-03", 8, 20, 0, "Sell");
  const parentSale = trade("parent-sale", parent, "2025-02-03", 10, 10, 0, "Sell");
  const transactions = [...purchases, snapshot, beforeAllotment, sale, parentSale];
  const rows = calculateLots(transactions, "2025-02-03", "2025-02-03", one, [], [], [withSnapshot]);
  const matches = rows.filter((row) => "transaction" in row).filter((row) => row.kind === "Sale match");
  assert.deepEqual(matches.map((row) => [row.transaction.id, row.purchase?.id, row.spinOffs, row.allottedOn, row.result]), [
    ["parent-sale", "parent-a", ["action"], undefined, 5968n],
    ["sale", "child-buy", undefined, undefined, 2400n],
    ["sale", "parent-a", ["action"], "2025-02-03", 8976n],
  ]);
  const result = portfolioGains("owner", "2025-02-04T12:00:00Z", {
    transactions, acquisitions: [], splits: [], transfers: [], spinOffs: [withSnapshot],
  });
  assert.equal(result.sales, 2);
  assert.equal(result.realisedUsd, 173.44);
  assert.deepEqual(result.open.child, { units: "50", costUsd: 469.76, lastSplit: "2025-02-03" });
});

test("adds the exact statement units when lots have a repeating unit ratio and leaves unconfirmed USD basis blank", () => {
  const smallAction = { ...action, parent_shares: "3", child_shares: "1",
    child_basis_pct_usd: null, child_basis_pct_aud: "25", average_aud_basis: false };
  const buys = [trade("parent-a", parent, "2025-01-01", 1, 12), trade("parent-b", parent, "2025-01-02", 2, 20)];
  const rows = calculateLots([...buys, trade("sale", child, "2025-02-03", 1, 20, 0, "Sell")],
    undefined, undefined, one, [], [], [smallAction]);
  const matches = rows.filter((row) => "transaction" in row).filter((row) => row.kind === "Unmatched sale");
  assert.equal(matches.reduce((sum, row) => sum + row.units!, 0n), 10n ** 18n);
  assert.equal(matches.reduce((sum, row) => sum + row.aud!.result!, 0n), 700n);
  assert.ok(matches.every((row) => row.result === undefined));
  assert.equal(rows.filter((row) => "transaction" in row && row.kind === "Position record" && row.transaction.holding_id === parent.id).length, 2);
});

test("flags share discrepancies and double-claimed snapshots without calculating gains from them", () => {
  const sale = trade("sale", child, "2025-02-05", 3, 10, 0, "Sell");
  const rows = calculateLots([...purchases, snapshot, sale], undefined, undefined, one, [], [], [{ ...withSnapshot, parent_shares: "279" }]);
  assert.ok(rows.some((row) => row.kind === "Unreconciled spin-off"));
  assert.ok(rows.some((row) => row.kind === "Unmatched sale"));
  assert.ok(rows.every((row) => row.kind !== "Open lot"));
  const unlinked = calculateLots([...purchases, snapshot, sale], undefined, undefined, one, [], [], [action]);
  assert.ok(unlinked.some((row) => row.kind === "Unreconciled spin-off"));
  assert.ok(unlinked.every((row) => row.kind !== "Sale match"));
  const sendingChild = { ...child, id: "sending-child" };
  const transfer: StockTransfer = {
    id: "transfer", from_holding_id: sendingChild.id, source: sendingChild, to_holding_id: child.id, destination: child,
    shares: "56", sent_on: "2025-02-01", received_on: "2025-02-04", from_account: "Sending", to_account: "Receiving",
    same_day_order: 1, statement_reference: "Other record", updated_at: "", receiving_snapshot_id: snapshot.id,
    receiving_snapshot: withSnapshot.child_snapshot,
  };
  const shared = calculateLots([...purchases, snapshot, sale], undefined, undefined, one, [], [transfer], [withSnapshot]);
  assert.ok(shared.some((row) => row.kind === "Unreconciled spin-off"));
  assert.ok(shared.some((row) => row.kind === "Unreconciled transfer"));
  assert.ok(shared.every((row) => row.kind !== "Sale match"));
});

test("reconciles the displayed parent quantity after a repeating split and carries basis through a child transfer", () => {
  const source = trade("parent-a", parent, "2025-01-01", 1, 120);
  const split = { id: "parent-split", holding_id: parent.id, effective_date: "2025-02-03",
    new_shares: 1, old_shares: 3, statement_reference: "Reverse split", updated_at: "", portfolio_holdings: parent,
    snaptrade_activity_id: null, snaptrade_activity_date: null, snaptrade_activity_label: null, snaptrade_activity_symbol: null };
  const smallAction = { ...action, parent_shares: "0.333333333333333333", child_shares: "0.5", child_basis_pct_usd: "20" };
  const receiver = { ...child, id: "receiver" };
  const moved: StockTransfer = {
    id: "transfer", from_holding_id: child.id, source: child, to_holding_id: receiver.id, destination: receiver,
    shares: "0.5", sent_on: "2025-02-04", received_on: "2025-02-05", from_account: "Sending", to_account: "Receiving",
    same_day_order: 1, statement_reference: "Transferred child shares", updated_at: "", receiving_snapshot_id: null, receiving_snapshot: null,
  };
  const sale = trade("sale", receiver, "2025-02-06", 0.5, 80, 0, "Sell");
  const rows = calculateLots([source, sale], undefined, undefined, one, [split], [moved], [smallAction]);
  const match = rows.filter((row) => "transaction" in row).find((row) => row.kind === "Sale match");
  assert.deepEqual([match?.purchase?.id, match?.allottedOn, match?.spinOffs, match?.transfers, match?.result],
    ["parent-a", "2025-02-03", ["action"], ["transfer"], 1600n]);
});
