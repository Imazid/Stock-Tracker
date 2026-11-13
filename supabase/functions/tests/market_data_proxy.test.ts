import { assertEquals, assertExists } from "jsr:@std/assert@1";
import { alpacaRequest } from "../market-data-proxy/alpaca.ts";
import { fundamentalsRequest } from "../market-data-proxy/fundamentals.ts";


function request(path: string, query: Record<string, string> = {}) {
  const url = new URL("https://example.test/functions/v1/market-data-proxy");
  url.search = new URLSearchParams({ path, ...query }).toString();
  return url;
}

Deno.test("market data proxy only accepts Alpaca data routes and bounded query parameters", () => {
  const snapshot = alpacaRequest(request("/v2/stocks/snapshots", { symbols: "MSFT,AAPL,MSFT" }));
  assertEquals(snapshot?.href, "https://data.alpaca.markets/v2/stocks/snapshots?feed=iex&symbols=AAPL%2CMSFT");
  for (const path of ["https://example.test", "//example.test", "/v2/orders", "/v2/stocks/../bars", "/v2/stocks/AAPL%2F..%2Forders/snapshot"]) {
    assertEquals(alpacaRequest(request(path)), undefined, path);
  }
  assertEquals(alpacaRequest(request("/v2/stocks/snapshots", { symbols: "AAPL", feed: "sip" })), undefined);
  assertEquals(alpacaRequest(request("/v2/stocks/AAPL/snapshot", { token: "secret" })), undefined);
  const duplicate = request("/v2/stocks/AAPL/snapshot");
  duplicate.searchParams.append("path", "/v2/stocks/MSFT/snapshot");
  assertEquals(alpacaRequest(duplicate), undefined);
  assertExists(alpacaRequest(request("/v1beta3/crypto/us/snapshots", { symbols: "BTC/USD" })));
});

Deno.test("consolidated stock bars must end at least 15 minutes in the past", () => {
  const now = Date.parse("2026-11-12T15:00:00Z");
  const path = "/v2/stocks/AAPL/bars";
  const query = { start: "2026-11-01T00:00:00Z", timeframe: "1Day", limit: "10000", feed: "sip", adjustment: "all" };
  assertExists(alpacaRequest(request(path, { ...query, end: "2026-11-12T14:44:59Z" }), now));
  assertEquals(alpacaRequest(request(path, { ...query, end: "2026-11-12T14:59:00Z" }), now), undefined);
  assertEquals(alpacaRequest(request(path, { ...query, end: "2026-11-12T14:44:59Z", limit: "10001" }), now), undefined);
});

Deno.test("fundamentals routes keep credentials and provider addresses under server control", () => {
  const url = request("/api/v1/company-news", { provider: "finnhub", symbol: "AAPL", from: "2026-11-10", to: "2026-11-12" });
  const accepted = fundamentalsRequest(url);
  assertEquals(accepted?.target.origin, "https://finnhub.io");
  assertEquals(accepted?.auth, "X-Finnhub-Token");
  url.searchParams.set("token", "client-controlled");
  assertEquals(fundamentalsRequest(url), undefined);
  assertEquals(fundamentalsRequest(request("/query", { provider: "alpha", function: "FX_INTRADAY", symbol: "AAPL" })), undefined);
  assertEquals(fundamentalsRequest(request("/stable/profile", { provider: "fmp" })), undefined);
  assertEquals(fundamentalsRequest(request("/v2/company/profile", { provider: "fiscal", companyKey: "apple-inc" }))?.keyName, "FISCAL_AI_API_KEY");
});
