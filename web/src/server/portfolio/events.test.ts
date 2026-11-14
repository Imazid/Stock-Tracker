import assert from "node:assert/strict";
import test from "node:test";
import { portfolioEventGroup, upcomingEarnings } from "../../lib/portfolio-events.ts";
import type { Evidence, ResearchEvent } from "../../lib/research-types.ts";
import { fmpNews, fmpUpcomingEarnings } from "../research/licensed.ts";

const asOf = "2026-11-14T06:00:00Z";
const evidence: Evidence = { provider: "Provider", url: "https://example.com/filing", retrievedAt: asOf, license: "licensed" };

test("validates dates and exact listed symbols for expected earnings", () => {
  const rows = [
    { symbol: "AAPL", date: "2026-11-19", epsEstimated: 2.10, epsActual: null },
    { symbol: "AAPL", date: "2026-11-14" },
    { symbol: "AAPL", date: "2026-11-18", epsActual: 0 },
    { symbol: "AAPL", date: "2026-11-31" },
    { symbol: "AAPL", date: "2026-10-01" },
    { symbol: "AAPL", date: "2026-12-18" },
    { symbol: "AAPL.AX", date: "2026-11-21" },
  ];
  const events = upcomingEarnings(rows, "AAPL", "2026-11-14", "2026-12-14", evidence);
  assert.deepEqual(events.map(({ date }) => date), ["2026-11-19", "2026-11-14"]);
  assert(events.every(({ evidence: source }) => source === evidence));
  const group = portfolioEventGroup("earnings", 1, true, [{ symbol: "AAPL", instrumentId: "us:AAPL", events }], asOf);
  assert.deepEqual(group.items.map(({ event }) => event.date), ["2026-11-14", "2026-11-19"]);
});

test("keeps scoped evidence, ignores old or future news and distinguishes partial, restricted and empty feeds", () => {
  function article(id: string, date: string, url = evidence.url): ResearchEvent {
    return { id, date, category: "News", title: "Headline", evidence: { ...evidence, url } };
  }
  const group = portfolioEventGroup("news", 3, true, [
    { instrumentId: "us:AAPL", symbol: "AAPL", events: [
      article("old", "2026-11-06", "https://example.com/old"), article("future", "2026-11-15", "https://example.com/future"),
      article("first", "2026-11-12"), article("update", "2026-11-13"),
    ] },
    { instrumentId: "us:MSFT", symbol: "MSFT", events: [] },
  ], asOf);
  assert.equal(group.status, "partial");
  assert.equal(group.checked, 2);
  assert.deepEqual(group.items.map(({ event }) => event.id), ["update"]);
  assert.equal(portfolioEventGroup("filings", 1, false, [], asOf).status, "restricted");
  assert.equal(portfolioEventGroup("filings", 1, true, [], asOf).status, "unavailable");
  assert.equal(portfolioEventGroup("filings", 0, true, [], asOf).status, "not_applicable");
});

test("requests exact provider symbols and keeps provenance links free of credentials", async (t) => {
  const original = process.env.RESEARCH_FMP_API_KEY;
  process.env.RESEARCH_FMP_API_KEY = "test-credential";
  t.after(() => {
    if (original === undefined) delete process.env.RESEARCH_FMP_API_KEY;
    else process.env.RESEARCH_FMP_API_KEY = original;
  });
  t.mock.method(globalThis, "fetch", async (url: URL) => {
    assert.equal(url.host, "financialmodelingprep.com");
    assert.equal(url.searchParams.get("apikey"), "test-credential");
    if (url.pathname === "/stable/earnings") {
      assert.equal(url.searchParams.get("symbol"), "TEST.AX");
      return Response.json([{ symbol: "TEST.AX", date: "2026-11-18" }, { symbol: "TEST", date: "2026-11-18" }]);
    }
    assert.equal(url.pathname, "/stable/news/stock");
    assert.equal(url.searchParams.get("symbols"), "TEST.AX");
    const article = { title: "Example headline", publishedDate: "2026-11-12T06:00:00Z", symbol: "TEST.AX" };
    return Response.json([{ ...article, url: "https://example.com/news" }, { ...article, url: "javascript:alert(1)" }]);
  });
  const [earnings, news] = await Promise.all([fmpUpcomingEarnings("TEST.AX", "2026-11-14", "2026-12-14"), fmpNews("TEST.AX")]);
  assert.equal(earnings.length, 1);
  assert.equal(earnings[0].evidence.url, "https://site.financialmodelingprep.com/developer/docs/stable/earnings-company");
  assert.equal(news.length, 1);
  assert.equal(news[0].evidence.url, "https://example.com/news");
});
