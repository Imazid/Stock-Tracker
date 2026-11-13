import assert from "node:assert/strict";
import { test } from "node:test";
import { annualMetrics, dcf, latestVersions, reportedOn, trailingFacts } from "../../lib/research-financials.ts";
import type { FinancialFact } from "../../lib/research-types.ts";
import { findSecListing, normalizeSecDirectory, normalizeSecFacts } from "./sec.ts";

const retrieval = "2026-11-14T01:00:00Z";
const fact = (tag: string, value: number, end: string, publishedAt: string, start?: string, period: FinancialFact["period"] = "annual"): FinancialFact => ({
  concept: `us-gaap:${tag}`, label: tag, value, statement: "income", unit: "USD", start, end, period,
  evidence: { url: "https://www.sec.gov/", provider: "SEC EDGAR", publishedAt, retrievedAt: retrieval, license: "public_filing" },
});

test("CIK is issuer-level and ambiguous tickers are rejected", () => {
  const list = normalizeSecDirectory({ fields: ["ticker", "exchange", "name", "cik"], data: [
    ["BRK-B", "NYSE", "Berkshire Hathaway", 1067983], ["AAPL", "Nasdaq", "Apple", 320193], ["AAPL", "Nasdaq", "Another filer", 456],
  ] });
  assert.equal(findSecListing(list, "BRK.B")?.cik, "0001067983");
  assert.equal(findSecListing(list, "AAPL"), undefined);
});

test("quarter classification uses duration, and missing amounts never become zero", () => {
  const payload = { facts: { "us-gaap": { NetIncomeLoss: { units: { USD: [
    { start: "2025-01-01", end: "2025-06-30", val: 15, filed: "2025-08-01", accn: "0000320193-25-000042", form: "10-Q" },
    { start: "2025-04-01", end: "2025-06-30", val: 0, filed: "2025-08-01", accn: "0000320193-25-000042", form: "10-Q" },
    { start: "2025-04-01", end: "2025-06-30", val: null, filed: "2025-08-01", accn: "0000320193-25-000042", form: "10-Q" },
  ] } } } } };
  const rows = normalizeSecFacts(payload, "0000320193", retrieval);
  assert.deepEqual(rows.map((row) => [row.period, row.value]), [["other", 15], ["quarter", 0]]);
  assert.match(rows[0].evidence.url, /000032019325000042\/0000320193-25-000042-index.htm$/);
});

test("publication cutoff excludes later restatements", () => {
  const rows = [
    fact("Assets", 110, "2024-12-31", "2026-03-01"),
    fact("Assets", 100, "2024-12-31", "2025-03-01"),
  ];
  assert.equal(latestVersions(reportedOn(rows, "2025-06-01"))[0].value, 100);
  assert.equal(latestVersions(reportedOn(rows, "2026-11-13"))[0].value, 110);
});

test("TTM combines comparable fiscal YTD observations and preserves citations", () => {
  const rows = [
    fact("Revenues", 120, "2025-12-31", "2026-02-01", "2025-01-01"),
    fact("Revenues", 40, "2026-03-31", "2026-05-01", "2026-01-01", "quarter"),
    fact("Revenues", 30, "2025-03-31", "2026-05-01", "2025-01-01", "quarter"),
  ];
  const [ttm] = trailingFacts(reportedOn(rows, "2026-08-01"));
  assert.equal(ttm.value, 130);
  assert.equal(ttm.inputs?.length, 3);
  assert.equal(ttm.end, "2026-03-31");
  assert.equal(trailingFacts(reportedOn(rows.slice(0, 2), "2026-08-01")).length, 0);
});

test("ratios use comparable currency and period and DCF validates assumptions", () => {
  const rows = [
    fact("Revenues", 100, "2025-12-31", "2026-02-01", "2025-01-01"),
    fact("NetIncomeLoss", 20, "2025-12-31", "2026-02-01", "2025-01-01"),
    { ...fact("GrossProfit", 50, "2025-12-31", "2026-02-01", "2025-01-01"), unit: "AUD" },
  ];
  assert.equal(annualMetrics(rows).find((row) => row.label === "Net margin")?.value, 20);
  assert.equal(annualMetrics(rows).some((row) => row.label === "Gross margin"), false);
  const assumptions = { cashFlow: 100, growth: 0, discount: 0.1, terminal: 0, netDebt: 0, shares: 10 };
  assert.ok(Math.abs(dcf(assumptions)! - 100) < 0.000001);
  assert.equal(dcf({ ...assumptions, terminal: 0.1 }), undefined);
});
