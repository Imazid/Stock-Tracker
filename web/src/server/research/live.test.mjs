import assert from "node:assert/strict";
import { test } from "node:test";

const origin = process.env.RESEARCH_TEST_ORIGIN;
const live = { skip: !origin, timeout: 90_000 };
async function get(path) {
  const response = await fetch(new URL(path, origin), { signal: AbortSignal.timeout(70_000) });
  assert.equal(response.status, 200, path);
  return response.json();
}
function instrument(id, suffix) {
  return `/api/markets/instruments/${encodeURIComponent(id)}/${suffix}`;
}

test("CIK, exchange-qualified search, and fund lookup resolve real listings", live, async () => {
  const queries = [["CIK:320193", "us:AAPL"], ["ASX:BHP", "asx:BHP"], ["SPY", "us:SPY"], ["ASX:IMU", "asx:IMU"]];
  for (const [query, id] of queries) {
    const result = await get(`/api/markets/search?q=${encodeURIComponent(query)}`);
    assert.ok(result.results.some((row) => row.id === id), query);
    if (query === "SPY") assert.equal(result.results.find((row) => row.id === id).assetClass, "etf");
  }
});

test("Apple's original 2025 annual revenue and SEC filing evidence survive an as-of cutoff", live, async () => {
  const report = await get(instrument("us:AAPL", "research?section=financials&period=annual&asOf=2025-12-01&q=RevenueFromContractWithCustomerExcludingAssessedTax"));
  const revenue = report.facts.find((row) => row.end === "2025-09-27" && row.unit === "USD");
  assert.equal(revenue?.value, 416_161_000_000);
  assert.ok(report.facts.every((row) => row.evidence.publishedAt <= "2025-12-01"));
  assert.match(revenue.evidence.url, /sec\.gov\/Archives\/edgar\/data\/320193\//);
  const filings = await get(instrument("us:AAPL", "research?section=events&asOf=2025-12-01&q=10-K"));
  const original = filings.events.find((row) => row.reportDate === "2025-09-27" && row.category === "10-K");
  assert.ok(original);
  const passages = await get(instrument("us:AAPL", `research/filing?accession=${original.id}&q=competition`));
  assert.ok(passages.passages.some((passage) => /competition/i.test(passage.text)));
});

test("a bank, a dividend payer, a recent listing and a renamed issuer return filing evidence", live, async () => {
  for (const id of ["us:JPM", "us:KO", "us:CRWV", "us:META"]) {
    const result = await get(instrument(id, "research?section=events&limit=3"));
    assert.ok(result.events.length > 0, id);
    assert.ok(result.events.every((row) => row.evidence.provider === "SEC EDGAR" && row.evidence.publishedAt));
  }
});

test("ASX chart uses AUD and the ASX research page does not substitute a US ADR", live, async () => {
  for (const id of ["asx:BHP", "asx:IMU"]) {
    const result = await get(instrument(id, "research?section=events"));
    assert.ok(result.links.some((row) => row.url.endsWith(`/${id.slice(4)}`)));
    assert.ok(result.events.every((event) => event.evidence.provider !== "SEC EDGAR"));
  }
  const chart = await get(instrument("asx:BHP", "candles?range=5D"));
  assert.equal(chart.currency, "AUD");
  assert.ok(chart.candles.length > 0 && chart.candles.every((row) => row.high >= row.low && row.close > 0));
  assert.ok(chart.source && chart.adjustment);
});

test("an inactive ticker and crypto show explicit coverage", live, async () => {
  const inactive = await get(instrument("us:TWTR", "research?section=financials"));
  assert.ok(inactive.coverage.length);
  assert.equal(inactive.facts.length, 0);
  const crypto = await get(instrument("crypto:BTC", "research?section=overview"));
  assert.equal(crypto.coverage[0].status, "not_applicable");
});

test("the one-action report includes dated evidence and named coverage gaps", live, async () => {
  const report = await get(instrument("us:AAPL", "research/report"));
  assert.equal(report.instrumentId, "us:AAPL");
  assert.ok(report.events.length > 0 && report.facts.length > 0);
  assert.ok(report.coverage.length > 0 && report.facts.every((fact) => fact.evidence.url));
});
