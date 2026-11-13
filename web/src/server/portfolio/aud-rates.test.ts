import { strict as assert } from "node:assert";
import { test } from "node:test";
import { audReferences } from "./aud-rates.ts";
import type { TransactionRow } from "./transactions.ts";

const header = "KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE";
const quote = (code: string, day: string, rate: string) => `EXR.D.${code}.EUR.SP00.A,D,${code},EUR,SP00,A,${day},${rate}`;

function transaction(id: string, currency?: string, date = "2026-01-02T13:00:00Z"): TransactionRow {
  return { id, holding_id: "holding", transaction_date: date, type: "Buy", shares: 1, price_per_share: 100, fees: 0,
    portfolio_holdings: null, trade_provenance: currency ? { source: "manual_trade", currency, unitPrice: 100, fees: 0 } : null };
}

test("AUD rates batch by year and choose the latest common day in Sydney", async () => {
  const input = [
    transaction("usd", "USD"), transaction("eur", "EUR"), transaction("aud", "AUD"), transaction("legacy"),
    transaction("historic", "USD", "1998-01-01T00:00:00Z"),
    transaction("future", "USD", "2027-01-01T00:00:00Z"),
    { ...transaction("snapshot", "AUD"), trade_provenance: { source: "broker_position" as const, currency: "AUD", unitPrice: 100 } },
  ];
  let calls = 0;
  const request = (async (url: URL) => {
    calls++;
    assert.equal(url.pathname, "/service/data/EXR/D.AUD+USD.EUR.SP00.A");
    assert.equal(url.searchParams.get("startPeriod"), "2025-12-25");
    assert.equal(url.searchParams.get("endPeriod"), "2026-01-04");
    assert.deepEqual([...url.searchParams.keys()], ["startPeriod", "endPeriod", "format", "detail"]);
    return new Response([header, quote("AUD", "2025-12-31", "1.7"), quote("USD", "2025-12-31", "1.1"),
      quote("AUD", "2026-01-02", "1.6"), quote("USD", "2026-01-04", "1.2")].join("\r\n"));
  }) as typeof fetch;
  const rates = await audReferences(input, new AbortController().signal, request, Date.parse("2026-01-04T00:00:00Z"));
  assert.equal(calls, 1);
  assert.deepEqual(rates.get("usd"), { source: "ECB reference", date: "2025-12-31", rate: "1.545454545455" });
  assert.deepEqual(rates.get("eur"), { source: "ECB reference", date: "2026-01-02", rate: "1.6" });
  assert.deepEqual(rates.get("aud"), { source: "AUD input", rate: "1" });
  assert.equal(rates.get("legacy")?.source, "Original currency missing");
  assert.equal(rates.get("snapshot")?.source, "Position snapshot");
  assert.equal(rates.get("historic")?.source, "No ECB reference rate");
  assert.equal(rates.get("future")?.source, "Trade date unavailable");
});

test("distinguishes missing rates and temporary lookup failures", async () => {
  const trade = transaction("missing", "USD");
  const signal = new AbortController().signal;
  const now = Date.parse("2026-01-04T00:00:00Z");
  for (const [status, source] of [[404, "No ECB reference rate"], [503, "ECB lookup unavailable"]] as const) {
    const rates = await audReferences([trade], signal, async () => new Response(null, { status }), now);
    assert.deepEqual(rates.get(trade.id), { source });
  }
});
