import { assertEquals, assertExists } from "jsr:@std/assert@1";
import { type MarketDataProvider } from "../_shared/market/provider.ts";
import { UniverseCatalog } from "../_shared/trading/catalog.ts";
import { type Bar, instrumentID, makeBarSeries, marketProvenance } from "../_shared/trading/market.ts";
import { decodeAlpacaMovers, decodeTrendingCrypto, marketExplore, trackedStockMovers } from "../market-workspace/explore.ts";

const friday = Date.parse("2026-11-13T20:10:00Z");

Deno.test("market-wide US movers reject stale, future and invalid snapshots", () => {
  const sample = {
    market_type: "stocks",
    last_updated: "2026-11-13T20:02:08.155713157Z",
    gainers: [{ symbol: "AAPL", price: 110, percent_change: 10 }, { symbol: "BAD", price: 0, percent_change: 50 }],
    losers: [{ symbol: "MSFT", price: 92, percent_change: -8 }, { symbol: "AAPL", price: 99, percent_change: -1 }],
  };
  const result = decodeAlpacaMovers(sample, friday);
  assertExists(result);
  assertEquals(result.gainers.map(({ instrument }) => instrument.symbol), ["AAPL"]);
  assertEquals(result.losers.map(({ instrument }) => instrument.symbol), ["MSFT"]);
  assertEquals(result.observedAt, "2026-11-13T20:02:08.155Z");
  assertEquals(decodeAlpacaMovers({ ...sample, last_updated: "2026-11-12T20:02:08Z" }, friday), null);
  assertEquals(decodeAlpacaMovers({ ...sample, last_updated: "2026-11-13T20:30:00Z" }, friday), null);
});

Deno.test("tracked movers rank the same two completed ASX sessions with explicit coverage", async () => {
  const at = Date.parse("2026-11-16T01:00:00Z"); // Monday's regular session is still in progress.
  const bar = (date: string, close: number): Bar => ({
    time: Date.parse(date), open: close, high: close, low: close, close, volume: 1000,
  });
  const provider = (count: number): MarketDataProvider => ({
    name: "Test market",
    supports: () => true,
    quotes: () => Promise.resolve({ quotes: {}, failures: {} }),
    bars: () => Promise.resolve({
      failures: {},
      series: Object.fromEntries(UniverseCatalog.asxBlueChips.slice(0, count).map((item, i) => [
        instrumentID(item),
        makeBarSeries(item, "day", [
          bar("2026-11-12T00:00:00Z", 100),
          bar("2026-11-13T00:00:00Z", [107, 94, 102, 97][i] ?? 100),
          bar("2026-11-16T00:00:00Z", 500),
        ], marketProvenance("Test market"), at),
      ])),
    }),
  });
  const result = await trackedStockMovers(provider(4), "asx", at);
  assertExists(result);
  assertEquals(result.scope, "Last completed session · 4 of 8 tracked ASX stocks");
  assertEquals(result.observedAt, "2026-11-13T05:00:00.000Z");
  assertEquals(result.gainers.map(({ price }) => price), [107, 102]);
  assertEquals(result.losers.map(({ price }) => price), [94, 97]);
  assertEquals(await trackedStockMovers(provider(3), "asx", at), null);
});

Deno.test("crypto trends retain source order and match provider coin IDs, not ticker collisions", () => {
  const response = { coins: [
    { item: { id: "fake-bitcoin", name: "Fake", symbol: "BTC" } },
    { item: { id: "solana", name: "Solana", symbol: "SOL" } },
    { item: { id: "bitcoin", name: "Bitcoin", symbol: "btc" } },
    { item: { id: "solana", name: "Solana", symbol: "SOL" } },
  ] };
  const result = decodeTrendingCrypto(response, friday);
  assertEquals(result?.instruments.map(instrumentID), ["crypto:SOL", "crypto:BTC"]);
  assertEquals(decodeTrendingCrypto({ coins: [] }, friday)?.instruments, []);
  assertEquals(decodeTrendingCrypto({ error: "unavailable" }, friday), null);
});

Deno.test("one provider failure does not erase independent rankings", async () => {
  const provider: MarketDataProvider = {
    name: "Unavailable",
    supports: () => false,
    quotes: () => Promise.reject(new Error("offline")),
    bars: () => Promise.reject(new Error("offline")),
  };
  const result = await marketExplore(provider, () => undefined, friday, () =>
    Promise.resolve(Response.json({ coins: [{ item: { id: "bitcoin", symbol: "BTC", name: "Bitcoin" } }] })));
  assertEquals(result.us, null);
  assertEquals(result.asx, null);
  assertEquals(result.trending?.instruments.map(instrumentID), ["crypto:BTC"]);
});
