import { strict as assert } from "node:assert";
import { test } from "node:test";
import type { StockSplit } from "../../lib/portfolio-splits.ts";
import type { StockTransfer, TransferHolding } from "../../lib/portfolio-transfers.ts";
import { matchBrokerStockTransfers, type BrokerStockMovement } from "../../lib/broker-stock-transfers.ts";

test("matches unique broker legs to separate holdings and skips ambiguous, reversed and unlisted pairs", () => {
  const holding = (id: string, exchange = "ASX"): TransferHolding => ({
    id, asset_symbol: "BHP", asset_exchange: exchange, asset_kind: "Stock", date_added: "2026-01-01", deleted_at: null,
    broker_account: { account_id: id, label: id, institution: id, observed_at: "2026-07-03", tracking: true },
  });
  const movement = (accountId: string, direction: "sent" | "received", date: string): BrokerStockMovement => ({
    id: accountId + direction, date, stockTransfer: { accountId, direction, symbol: "BHP.AX", exchange: "XASX", shares: "2.25" },
  });
  const source = holding("source");
  const destination = holding("destination");
  const sent = movement(source.id, "sent", "2026-07-01");
  const received = movement(destination.id, "received", "2026-07-03");
  const holdings = [source, destination];
  const [match] = matchBrokerStockTransfers([sent, sent, received], holdings);
  assert.deepEqual(match.reference, { sentId: sent.id, receivedId: received.id, sentOn: sent.date, receivedOn: received.date,
    fromAccountId: source.id, toAccountId: destination.id, symbol: "BHP.AX", exchange: "XASX", shares: "2.25" });
  assert.deepEqual(matchBrokerStockTransfers([sent, received, movement("untracked", "received", "2026-07-04")], holdings), []);
  assert.deepEqual(matchBrokerStockTransfers([sent, received, movement("untracked", "sent", "2026-07-02")], holdings), []);
  assert.deepEqual(matchBrokerStockTransfers([sent, { ...received, date: "2026-06-30" }], holdings), []);
  assert.deepEqual(matchBrokerStockTransfers([sent, { ...received, date: "2026-07-09" }], holdings), []);
  assert.deepEqual(matchBrokerStockTransfers([sent, received], [source, holding("destination", "NYSE")]), []);
  assert.deepEqual(matchBrokerStockTransfers([sent, received], [...holdings, { ...source, id: "duplicate" }]), []);
});
import { calculateLots, lotNumber, UNIT_DECIMALS } from "./lots.ts";
import type { TransactionRow } from "./transactions.ts";

function holding(id: string, deleted_at: string | null = null): TransferHolding {
  return { id, asset_symbol: "BHP", asset_exchange: "ASX", asset_kind: "Stock", date_added: "2026-06-10", deleted_at };
}
const source = holding("source", "2026-07-02T00:00:00Z");
const destination = holding("destination");

function trade(id: string, day: string, type: "Buy" | "Sell", shares: number, price: number,
  position = source, fees = 0): TransactionRow {
  return {
    id, holding_id: position.id, portfolio_holdings: position, type, shares,
    transaction_date: day + "T00:00:00Z", price_per_share: price, fees,
    trade_provenance: { source: "manual_trade", currency: "AUD", unitPrice: price * 2, fees: fees * 2 },
  };
}

function transfer(values: Partial<StockTransfer> = {}): StockTransfer {
  return {
    id: "move", from_holding_id: source.id, to_holding_id: destination.id, source, destination,
    sent_on: "2026-07-01", received_on: "2026-07-03", shares: "2", same_day_order: 1,
    from_account: "Sender", to_account: "Receiver", statement_reference: "July statement",
    receiving_snapshot_id: null, receiving_snapshot: null, updated_at: "2026-07-05", ...values,
  };
}

function split(holdingId: string, day: string, newShares: number, oldShares: number): StockSplit {
  return {
    id: holdingId + day, holding_id: holdingId, effective_date: day, new_shares: newShares, old_shares: oldShares,
    statement_reference: "", updated_at: day, portfolio_holdings: null, snaptrade_activity_id: null,
    snaptrade_activity_date: null, snaptrade_activity_label: null, snaptrade_activity_symbol: null,
  };
}

const isTradeRow = (row: ReturnType<typeof calculateLots>[number]) => "transaction" in row;

test("moves prior FIFO lots and costs on the two statement dates, replacing one receiving snapshot", () => {
  const buy = trade("old", "2026-06-01", "Buy", 3, 10, source, 0.03);
  const recent = trade("recent", "2026-06-15", "Buy", 1, 25, destination);
  const received = trade("snapshot", "2026-07-03", "Buy", 2, 99, destination);
  received.trade_provenance = { source: "broker_position" };
  const sale = trade("sale", "2026-07-04", "Sell", 1.5, 30, destination);
  const recorded = transfer({ receiving_snapshot_id: received.id, receiving_snapshot: {
    id: received.id, holding_id: received.holding_id, transaction_date: received.transaction_date,
    type: "Buy", shares: 2, trade_provenance: received.trade_provenance, deleted_at: null,
  } });
  const trades = [sale, received, recent, buy];
  const aud = new Map([[buy.id, "1"], [sale.id, "1"], [recent.id, "1"]]);
  const before = calculateLots(trades, undefined, "2026-06-30", aud, [], [recorded]);
  assert.equal(before.filter(isTradeRow).reduce((total, row) => total + row.units!, 0n), 4n * 10n ** 18n);
  const transit = calculateLots(trades, undefined, "2026-07-02", aud, [], [recorded]);
  const moving = transit.find((row) => "transfer" in row);
  assert.equal(moving?.kind, "Transfer in transit");
  assert.deepEqual(moving?.usd, { gross: 2000n, fee: 2n });
  assert.deepEqual(moving?.aud, { gross: 4000n, fee: 4n });
  const after = calculateLots(trades, "2026-07-04", undefined, aud, [], [recorded]).filter(isTradeRow);
  assert.deepEqual(after.map((row) => [row.kind, row.transaction.holding_id, row.purchase?.id,
    lotNumber(row.units, UNIT_DECIMALS), row.purchaseCost, row.purchaseFee, row.transfers]), [
    ["Sale match", destination.id, "old", "1.5", 1500n, 2n, ["move"]],
    ["Archived holding lot", source.id, "old", "1", 1000n, 1n, undefined],
    ["Open lot", destination.id, "old", "0.5", 500n, 0n, ["move"]],
    ["Open lot", destination.id, "recent", "1", 2500n, 0n, undefined],
  ]);
  assert.equal(after[0].purchase?.transaction_date, buy.transaction_date);
  assert.equal(after[0].aud?.purchaseCost, 3000n);
  assert.ok(after.every((row) => row.purchase?.id !== received.id));
});

test("retains exact fractional split units across a chained same-day transfer", () => {
  const third = holding("third");
  const first = transfer({ received_on: "2026-07-01", shares: "1" });
  const next = transfer({ id: "next", source: destination, destination: third, from_holding_id: destination.id,
    to_holding_id: third.id, received_on: "2026-07-01", shares: "1", same_day_order: 2 });
  const rows = calculateLots([
    trade("one", "2026-06-01", "Buy", 1, 7),
    trade("two", "2026-06-02", "Buy", 2, 8),
    trade("sale", "2026-07-03", "Sell", 1, 50, third),
  ], undefined, undefined, undefined,
  [split(source.id, "2026-07-01", 1, 3), split(third.id, "2026-07-02", 2, 1)], [next, first]);
  const [a, b, open] = rows.filter(isTradeRow);
  assert.deepEqual([a.purchaseCost, b.purchaseCost, open.purchaseCost], [700n, 400n, 1200n]);
  assert.equal(a.units! + b.units!, 10n ** 18n);
  assert.equal(lotNumber(open.units, UNIT_DECIMALS), "1");
  assert.deepEqual(a.transfers, ["move", "next"]);
});

test("flags insufficient, mismatched and split-in-transit transfers before matching later sales", () => {
  const buy = trade("buy", "2026-06-01", "Buy", 2, 10);
  const sale = trade("sale", "2026-07-06", "Sell", 1, 20, destination);
  for (const [recorded, splits] of [
    [transfer({ shares: "3" }), []],
    [transfer({ receiving_snapshot_id: "changed" }), []],
    [transfer(), [split(source.id, "2026-07-02", 3, 1)]],
  ] as const) {
    const rows = calculateLots([buy, sale], undefined, undefined, undefined, splits, [recorded]);
    assert.ok(rows.some((row) => row.kind === "Unreconciled transfer"));
    assert.deepEqual(rows.filter(isTradeRow).map((row) => [row.kind, row.purchaseCost]), [["Unmatched sale", undefined]]);
  }
});
