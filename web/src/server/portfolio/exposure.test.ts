import assert from "node:assert/strict";
import test from "node:test";
import { portfolioExposure, portfolioInstrument, type PortfolioReferenceRates } from "../../lib/portfolio-exposure.ts";
import type { InstrumentView, QuoteResponse } from "../../lib/market-types.ts";
import { portfolioReferenceRates } from "./reference-rates.ts";

function instrument(venue: InstrumentView["venue"], symbol: string, currency: string): InstrumentView {
  return { id: `${venue}:${symbol}`, symbol, name: symbol, venue, venueName: venue, venueShort: venue.toUpperCase(),
    currency, assetClass: venue === "crypto" ? "crypto" : "equity" };
}

function quote(instrument: InstrumentView, last: number, observedAt = "2026-11-13T01:00:00Z"): QuoteResponse {
  return {
    instrument,
    market: { venue: instrument.venue, isOpen: false, calendarCovered: true, label: "Closed" },
    quote: { instrumentId: instrument.id, currency: instrument.currency, last, observedAt, fetchedAt: observedAt,
      stale: false, source: "Fixture", status: "delayed", volumeScope: "unknown", notes: [] },
  };
}

const rates: PortfolioReferenceRates = {
  AUD: { USD: { rate: "1.5", date: "2026-11-13" } },
  USD: { AUD: { rate: "0.666666666667", date: "2026-11-13" } },
};

test("combines accounts by listing and values each breakdown in the chosen reporting currency", () => {
  const bhp = instrument("asx", "BHP", "AUD");
  const adr = instrument("us", "BHP", "USD");
  const spy = instrument("us", "SPY", "USD");
  const btc = instrument("crypto", "BTC", "USD");
  const quotes = new Map([
    [bhp.id, quote(bhp, 50)], [adr.id, quote(adr, 60)],
    [spy.id, quote({ ...spy, assetClass: "etf" }, 300)],
    [btc.id, quote(btc, 80_000, "2026-11-13T05:00:00Z")],
  ]);
  const holdings = [
    { instrument: bhp, shares: 2 }, { instrument: bhp, shares: 3 }, { instrument: adr, shares: 1 },
    { instrument: spy, shares: 1 }, { instrument: btc, shares: 0.001 },
  ];
  const result = portfolioExposure(holdings, (id) => quotes.get(id), "AUD", rates);
  assert.equal(result.priced, 5);
  assert.equal(result.total, 910);
  assert.deepEqual(result.fxDates, ["2026-11-13"]);
  assert.deepEqual(result.listings.map(({ id, value }) => [id, value]), [
    [spy.id, 450], [bhp.id, 250], [btc.id, 120], [adr.id, 90],
  ]);
  assert.deepEqual(result.assets.map(({ id, value }) => [id, value]), [["etf", 450], ["equity", 340], ["crypto", 120]]);
  assert.deepEqual(result.countries.map(({ id, value }) => [id, value]), [["United States", 540], ["Australia", 250], ["Crypto markets", 120]]);
  assert.deepEqual(result.currencies.map(({ id, value }) => [id, value]), [["USD", 660], ["AUD", 250]]);
  assert.equal(result.oldestQuote, "2026-11-13T01:00:00.000Z");
  const usd = portfolioExposure(holdings, (id) => quotes.get(id), "USD", rates);
  assert(Math.abs(usd.total * 1.5 - result.total) < 0.00001);
  assert(Math.abs(usd.listings[0].weight - result.listings[0].weight) < 0.00001);
});

test("leaves unusable prices and missing conversions out of the denominator", () => {
  const aud = instrument("asx", "BHP", "AUD");
  const usd = instrument("us", "SPY", "USD");
  const holdings = [{ instrument: aud, shares: 2 }, { instrument: usd, shares: 1 }];
  const noFx = portfolioExposure(holdings, (id) => id === aud.id ? quote(aud, 5) : quote(usd, 10), "USD", undefined);
  assert.equal(noFx.priced, 1);
  assert.equal(noFx.missingRates, 1);
  assert.equal(noFx.listings[0].weight, 100);
  const excluded = portfolioExposure(holdings, (id) => id === aud.id
    ? quote({ ...aud, currency: "USD" }, 5)
    : { ...quote(usd, 10), quote: { ...quote(usd, 10).quote, stale: true } }, "USD", rates);
  assert.equal(excluded.priced, 0);
  assert.deepEqual(excluded.listings, []);
});

test("uses the latest shared ECB observation for each rate and omits unsupported data", async () => {
  const now = Date.parse("2026-11-14T03:00:00Z");
  const request = (async (url) => {
    assert.equal(new URL(String(url)).searchParams.get("startPeriod"), "2026-11-07");
    assert.equal(new URL(String(url)).searchParams.get("endPeriod"), "2026-11-14");
    return new Response([
      "KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE",
      "EXR.D.AUD.EUR.SP00.A,D,AUD,EUR,SP00,A,2026-11-12,1.8",
      "EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-11-12,1.2",
      "EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-11-13,1.1",
      "EXR.D.JPY.EUR.SP00.A,D,JPY,EUR,SP00,A,2026-11-13,176",
    ].join("\n"));
  }) as typeof fetch;
  const result = await portfolioReferenceRates(new AbortController().signal, request, now);
  assert.deepEqual(result.AUD.USD, { date: "2026-11-12", rate: "1.5" });
  assert.deepEqual(result.USD.JPY, { date: "2026-11-13", rate: "0.00625" });
  assert.deepEqual(result.USD.EUR, { date: "2026-11-13", rate: "1.1" });
  assert.equal(result.USD.CHF, undefined);
  await assert.rejects(portfolioReferenceRates(new AbortController().signal,
    (async () => new Response("unreadable")) as typeof fetch, now), /unreadable/);
});

test("uses the broker listing for bare international symbols and rejects conflicting listings", () => {
  const stock = { symbol: "VOD", name: "Vodafone", kind: "Stock" as const };
  assert.equal(portfolioInstrument({ ...stock, exchange: "XLON" })?.currency, "GBP");
  assert.equal(portfolioInstrument({ ...stock, symbol: "VOD.L", exchange: "LSE" })?.symbol, "VOD");
  assert.equal(portfolioInstrument({ ...stock, symbol: "VOD.L", exchange: "NASDAQ" }), null);
  assert.equal(portfolioInstrument({ ...stock, exchange: "Unmapped exchange" }), null);
  assert.equal(portfolioInstrument({ ...stock, symbol: "BRK.B", exchange: "NYSE" })?.symbol, "BRK.B");
  assert.equal(portfolioInstrument({ ...stock, symbol: "AAPL", exchange: null })?.venue, "us");
  assert.equal(portfolioInstrument({ ...stock, symbol: "UNMAPPED", exchange: null }), null);
});
