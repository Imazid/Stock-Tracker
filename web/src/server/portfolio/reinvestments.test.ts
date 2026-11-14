import { strict as assert } from "node:assert";
import { test } from "node:test";
import type { Reinvestment } from "../../lib/portfolio-reinvestments.ts";
import type { StockSplit } from "../../lib/portfolio-splits.ts";
import { audReferences } from "./aud-rates.ts";
import { calculateLots, lotNumber, UNIT_DECIMALS } from "./lots.ts";
import { reinvestmentAcquisition } from "./reinvestments.ts";
import type { TransactionRow } from "./transactions.ts";

const record: Reinvestment = {
  id: "statement-record", holding_id: "holding", paid_on: "2026-06-30", acquired_on: "2026-07-01", currency: "AUD",
  dividend_amount: "20.5", reinvested_amount: "20.01", shares: "2.000000000000000001", basis_usd: null,
  franking_credit_aud: "2", statement_reference: "Statement", updated_at: "2026-07-01", portfolio_holdings: null,
};
const split: StockSplit = {
  id: "split", holding_id: "holding", effective_date: "2026-07-02", new_shares: 2, old_shares: 1,
  statement_reference: "", updated_at: "2026-07-02", portfolio_holdings: null,
  snaptrade_activity_id: null, snaptrade_activity_date: null, snaptrade_activity_label: null, snaptrade_activity_symbol: null,
};
const trade = (id: string, type: "Buy" | "Sell", transaction_date: string, shares: number): TransactionRow => ({
  id, type, transaction_date, holding_id: "holding", shares, price_per_share: 30, fees: 0, portfolio_holdings: null,
  trade_provenance: { source: "manual_trade", currency: "AUD", unitPrice: 40, fees: 0 },
});

test("reinvested shares use allotment day and total amount applied, preserving precision through a split and partial sale", async () => {
  const acquisition = reinvestmentAcquisition(record);
  const sale = trade("sale", "Sell", "2026-07-02T02:00:00Z", 2);
  const rates = await audReferences([acquisition, sale], new AbortController().signal, () => {
    assert.fail("AUD statements should use their original amounts");
  }, Date.parse("2026-07-03"));
  assert.equal(rates.get(acquisition.id)?.source, "AUD input");
  const before = calculateLots([acquisition], undefined, "2026-06-30");
  assert.deepEqual(before, []);
  const rows = calculateLots([acquisition, sale], undefined, undefined, new Map([[acquisition.id, "1"], ["sale", "1"]]), [split]);
  assert.equal(rows[0].kind, "Stock split");
  const [, match, open] = rows;
  assert.ok(!("split" in match) && !("split" in open));
  assert.equal(match.kind, "Sale match");
  assert.equal(match.purchase?.id, acquisition.id);
  assert.equal(match.purchaseCost, undefined);
  assert.equal(match.aud?.purchaseCost, 1000n);
  assert.equal(open.aud?.purchaseCost, 1001n);
  assert.equal(lotNumber(open.units, UNIT_DECIMALS), "2.000000000000000002");
});

test("a date-only reinvestment follows all timestamped trades on that Sydney day", () => {
  const acquisition = reinvestmentAcquisition({ ...record, currency: "USD", reinvested_amount: "10" });
  const earlier = trade("same day buy", "Buy", "2026-07-01T12:45:00Z", 1);
  const sameDay = trade("same day sale", "Sell", "2026-07-01T13:00:00Z", 2);
  const later = trade("later sale", "Sell", "2026-07-01T14:00:00Z", 1);
  const rows = calculateLots([acquisition, later, sameDay, earlier]);
  assert.deepEqual(rows.map((row) => row.kind), ["Sale match", "Unmatched sale", "Sale match", "Open lot"]);
  assert.equal(rows[0].purchase?.id, earlier.id);
  assert.equal(rows[2].purchase?.id, acquisition.id);
  assert.equal(rows[2].purchaseCost, 500n);
});

test("a foreign statement can supply USD basis without changing the original acquisition amount", () => {
  const acquisition = reinvestmentAcquisition({ ...record, shares: "2", basis_usd: "13.27" });
  const [open] = calculateLots([acquisition], undefined, undefined, new Map([[acquisition.id, "1"]]));
  assert.equal(open.purchaseCost, 1327n);
  assert.equal(open.aud?.purchaseCost, 2001n);
});
