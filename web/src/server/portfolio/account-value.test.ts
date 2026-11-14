import assert from "node:assert/strict";
import test from "node:test";
import { portfolioAccountValue } from "../../lib/portfolio-account-value.ts";

const usd = { paper: false, status: "available", syncedAt: "2026-11-12T06:00:00Z", netValue: { amount: "1000", currency: "USD" } };
const aud = { ...usd, syncedAt: "2026-11-13T06:00:00Z", netValue: { amount: "-500", currency: "AUD" } };

test("linked net value uses reported account totals, FX and only eligible account observations", () => {
  const accounts = [usd, aud, { ...usd, status: "disconnected" }, { ...usd, syncedAt: null }, { ...usd, paper: true }, { ...usd, netValue: null }];
  const rates = { USD: { AUD: { rate: "0.6", date: "2026-11-13" } }, AUD: {} };
  assert.deepEqual(portfolioAccountValue(accounts, "USD", rates), {
    total: 700, covered: 2, accounts: 5, oldestSync: usd.syncedAt, fxDates: ["2026-11-13"],
  });
  assert.equal(portfolioAccountValue(accounts, "USD").total, 1000);
  assert.equal(portfolioAccountValue(accounts, "AUD").covered, 1);
  assert.equal(portfolioAccountValue([{ ...usd, paper: true }], "USD").total, null);
});
