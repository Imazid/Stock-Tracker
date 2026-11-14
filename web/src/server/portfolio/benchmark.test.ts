import assert from "node:assert/strict";
import test from "node:test";
import { makeInstrument } from "../../../../supabase/functions/_shared/trading/market.ts";
import { yahooAdjustedCloses } from "../market/yahoo.ts";
import { benchmarkBoundary, benchmarkReturn, portfolioBenchmark, validBenchmarkPeriod } from "./benchmark.ts";

test("uses the last completed exchange session and rejects missing trading-day closes", () => {
  const closes = new Map([["2026-01-02", 101], ["2026-01-05", 105]]);
  assert.deepEqual(benchmarkBoundary("us", closes, "2026-01-04"), { session: "2026-01-02", close: 101 });
  assert.deepEqual(benchmarkBoundary("us", closes, "2026-01-05"), { session: "2026-01-05", close: 105 });
  assert.equal(benchmarkBoundary("us", closes, "2026-01-06"), undefined);
  assert.equal(benchmarkBoundary("us", closes, "2026-01-01"), undefined);
  assert.equal(validBenchmarkPeriod("2026-02-30", "2026-03-01"), false);
  assert.equal(validBenchmarkPeriod("2001-01-01", "2026-01-01"), false);
});

test("uses the adjusted prices and converts each Australian boundary to USD at its own rate", async () => {
  const now = Date.parse("2026-01-08T01:00:00Z");
  const rates = async (start: string, end: string) => {
    assert.equal(start, "2026-01-02");
    assert.equal(end, "2026-01-04");
    return [{ rate: "0.6", date: "2026-01-02" }, { rate: "0.66", date: "2026-01-04" }];
  };
  const closes = async () => [{ time: Date.parse("2026-01-01T23:00:00Z"), close: 100 }];
  const result = await portfolioBenchmark("STW", "2026-01-02", "2026-01-04", now, { closes, rates });
  assert.ok(result);
  assert.equal(result.start.session, "2026-01-02");
  assert.equal(result.end.session, "2026-01-02");
  assert.equal(result.end.fxDate, "2026-01-04");
  assert(Math.abs(result.returnPct - 10) < 1e-8);
  const missingFx = await portfolioBenchmark("STW", "2026-01-02", "2026-01-04", now, { closes, rates: async () => [] });
  assert.equal(missingFx, null);
  assert.equal(benchmarkReturn(100, NaN), undefined);
});

test("omits comparisons for incomplete current sessions and uses the US exchange date", async () => {
  const now = Date.parse("2026-01-06T02:00:00Z");
  let calls = 0;
  const closes = async () => {
    calls++;
    return [{ time: Date.parse("2026-01-02T14:30:00Z"), close: 100 }];
  };
  const rates = async () => { throw new Error("Unexpected FX request"); };
  assert.equal(await portfolioBenchmark("SPY", "2026-01-02", "2026-01-05", now, { closes, rates }), null);
  assert.equal(calls, 0);
  const result = await portfolioBenchmark("SPY", "2026-01-02", "2026-01-04", now, { closes, rates });
  assert.ok(result);
  assert.equal(result.returnPct, 0);
  assert.equal(calls, 1);
});

test("uses only positive adjusted closes and verifies the provider listing and currency", async (t) => {
  let symbol = "STW.AX";
  let currency = "AUD";
  t.mock.method(globalThis, "fetch", async (raw: string) => {
    const url = new URL(raw);
    assert.equal(url.pathname, "/v8/finance/chart/STW.AX");
    assert.equal(url.searchParams.get("includeAdjustedClose"), "true");
    return Response.json({ chart: { result: [{
      meta: { symbol, currency }, timestamp: [1, 2, 3, 4],
      indicators: { adjclose: [{ adjclose: [70, null, 72, -1] }], quote: [{ close: [80, 81, 82, 83] }] },
    }] } });
  });
  const instrument = makeInstrument("STW", "etf", "asx");
  assert.deepEqual(await yahooAdjustedCloses(instrument, 0, 5000), [{ time: 1000, close: 70 }, { time: 3000, close: 72 }]);
  symbol = "SPY";
  await assert.rejects(yahooAdjustedCloses(instrument, 0, 5000), /listing or quote currency/);
  symbol = "STW.AX";
  currency = "USD";
  await assert.rejects(yahooAdjustedCloses(instrument, 0, 5000), /listing or quote currency/);
});
