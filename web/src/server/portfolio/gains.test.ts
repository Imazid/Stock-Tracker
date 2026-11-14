import assert from "node:assert/strict";
import test from "node:test";
import type { InstrumentView, QuoteView } from "../../lib/market-types.ts";
import { unrealisedGains } from "../../lib/portfolio-gains.ts";
import type { StockSplit } from "../../lib/portfolio-splits.ts";
import type { StockTransfer, TransferHolding } from "../../lib/portfolio-transfers.ts";
import { portfolioGains } from "./gains.ts";
import type { TransactionRow } from "./transactions.ts";

function trade(id: string, holding_id: string, type: "Buy" | "Sell", shares: number, price_per_share: number, fees: number, day: string): TransactionRow {
  return { id, holding_id, type, shares, price_per_share, fees, transaction_date: day + "T00:00:00Z", portfolio_holdings: null };
}

test("summarises exact FIFO matches, partial sales and recorded fees once per transaction", () => {
  const buy = trade("buy", "one", "Buy", 2, 10, 1, "2026-08-01");
  const snapshot = { ...trade("snapshot", "one", "Buy", 1, 8, 200, "2026-08-03"),
    trade_provenance: { source: "broker_position" as const } };
  const sale = trade("sale", "one", "Sell", 3, 20, 3, "2026-08-04");
  const future = trade("future", "two", "Buy", 1, 99, 99, "2026-08-06");
  const fullBuy = trade("fullBuy", "closed", "Buy", 1, 20, 1, "2026-08-01");
  const fullSell = trade("fullSell", "closed", "Sell", 1, 15, 1, "2026-08-03");
  const result = portfolioGains("owner", "2026-08-05T04:00:00Z", {
    transactions: [buy, snapshot, sale, future, fullBuy, fullSell], acquisitions: [], transfers: [], splits: [],
  });
  assert.equal(result.realisedUsd, 10);
  assert.deepEqual([result.sales, result.matchedSales, result.partialSales], [2, 1, 1]);
  assert.deepEqual([result.feesUsd, result.tradeRecords, result.feeRecords], [6, 4, 4]);
  assert.deepEqual(result.open, {});
});

test("keeps transferred and split basis in the receiving holding, with incomplete basis and archived lots called out", () => {
  const source: TransferHolding = { id: "source", asset_symbol: "BHP", asset_exchange: "ASX", asset_kind: "Stock",
    date_added: "2026-07-01", deleted_at: "2026-08-03T00:00:00Z" };
  const destination = { ...source, id: "destination", deleted_at: null };
  const buy = { ...trade("sourceBuy", source.id, "Buy", 2, 10, 2, "2026-08-01"), portfolio_holdings: source };
  const transfer = {
    id: "move", from_holding_id: source.id, to_holding_id: destination.id, source, destination,
    sent_on: "2026-08-02", received_on: "2026-08-04", shares: "1", same_day_order: 1,
    from_account: "Sender", to_account: "Receiver", statement_reference: "", receiving_snapshot_id: null,
    receiving_snapshot: null, updated_at: "2026-08-04",
  } satisfies StockTransfer;
  const split = { id: "split", holding_id: destination.id, effective_date: "2026-08-05", new_shares: 2, old_shares: 1,
    statement_reference: "", updated_at: "2026-08-05", portfolio_holdings: null, snaptrade_activity_id: null,
    snaptrade_activity_date: null, snaptrade_activity_label: null, snaptrade_activity_symbol: null } satisfies StockSplit;
  const snapshot = { ...trade("snapshot", "unknown", "Buy", 1, 10, 0, "2026-08-01"),
    trade_provenance: { source: "csv_position" as const } };
  const ledger = { transactions: [buy, snapshot], acquisitions: [], transfers: [transfer], splits: [split] };
  const inTransit = portfolioGains("owner", "2026-08-03T04:00:00Z", ledger);
  assert.equal(inTransit.pendingTransfers, 1);
  assert.equal(inTransit.open.destination, undefined);
  const result = portfolioGains("owner", "2026-08-06T04:00:00Z", ledger);
  assert.equal(result.archivedLots, 1);
  assert.equal(result.pendingTransfers, 0);
  assert.deepEqual(result.open.destination, { units: "2", costUsd: 11, lastSplit: "2026-08-05" });
  assert.equal(result.open.source, undefined);
  assert.equal(result.open.unknown.costUsd, null);
});

test("values only reconciled open quantities with matching fresh quotes and USD conversion", () => {
  const instrument: InstrumentView = { id: "asx:BHP", name: "BHP", symbol: "BHP", venue: "asx",
    venueName: "ASX", venueShort: "ASX", currency: "AUD", assetClass: "equity" };
  const quote: QuoteView = { instrumentId: instrument.id, currency: "AUD", last: 15,
    observedAt: "2026-08-06T04:00:00Z", fetchedAt: "2026-08-06T04:00:00Z", stale: false,
    source: "Fixture", status: "delayed", volumeScope: "unknown", notes: [] };
  const holdings = [{ id: "covered", shares: 2, instrument }, { id: "mismatch", shares: 1, instrument },
    { id: "oldQuote", shares: 2, instrument }];
  const open = { covered: { units: "2", costUsd: 12 }, mismatch: { units: "2", costUsd: 12 },
    oldQuote: { units: "2", costUsd: 12, lastSplit: "2026-08-07" } };
  const result = unrealisedGains(holdings, open, () => quote, {
    USD: { AUD: { rate: "0.7", date: "2026-08-05" } }, AUD: {},
  });
  assert.equal(result.total, 9);
  assert.deepEqual([...result.byHolding], [["covered", 9]]);
  assert.deepEqual([result.basisMissing, result.pricesMissing, result.fxMissing], [1, 1, 0]);
  assert.deepEqual(result.fxDates, ["2026-08-05"]);
  assert.equal(unrealisedGains(holdings, open, () => ({ ...quote, stale: true }), undefined).total, null);
});
