// The HTTP layer every adapter uses, the decimal helpers, and the provider registry.
// Run: npx -y deno test --allow-read supabase/functions/tests/brokers_*.test.ts

import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import * as Decimal from "../_shared/brokers/decimal.ts";
import { backoffMs, codeForStatus, errorFromResponse, read, retryAfterMs, sendOnce } from "../_shared/brokers/http.ts";
import { adapterFor, capabilitiesFor, isProviderID, PROVIDERS } from "../_shared/brokers/registry.ts";
import { type AdapterContext, BrokerError } from "../_shared/brokers/types.ts";
import { hang, MockFetch, networkError, respond } from "./brokers_mock.ts";

function ctx(mock: MockFetch, extra: Partial<AdapterContext> = {}): AdapterContext {
  return {
    environment: "paper",
    credentials: { provider: "alpaca", keyID: "PKTESTKEYID123", secretKey: "secret-value-abcdef" },
    fetch: mock.fetch,
    timeoutMs: 50,
    ...extra,
  };
}

const GET = { method: "GET" as const, url: "https://example.test/x", headers: {} };
const POST = { method: "POST" as const, url: "https://example.test/orders", headers: {}, body: { a: 1 } };

Deno.test("read: a 429 is retried after Retry-After, then succeeds", async () => {
  const mock = new MockFetch(respond(429, { message: "slow down" }, { "retry-after": "2" }), respond(200, { ok: true }));
  const sleeps: number[] = [];
  const response = await read(ctx(mock), GET, "Test", { sleep: (ms) => { sleeps.push(ms); return Promise.resolve(); } });
  assertEquals(response.status, 200);
  assertEquals(mock.calls.length, 2);
  assertEquals(sleeps, [2000]);
});

Deno.test("read: a 5xx is retried with full-jitter backoff", async () => {
  const mock = new MockFetch(respond(503, {}), respond(502, {}), respond(200, { ok: true }));
  const sleeps: number[] = [];
  const response = await read(ctx(mock), GET, "Test", { sleep: (ms) => { sleeps.push(ms); return Promise.resolve(); }, random: () => 0.5, baseDelayMs: 100 });
  assertEquals(response.status, 200);
  assertEquals(sleeps, [50, 100]); // 0.5 × 100, 0.5 × 200
});

Deno.test("read: network errors are retried, then reported as provider_unavailable", async () => {
  const mock = new MockFetch(networkError, networkError, networkError);
  const error = await assertRejects(() => read(ctx(mock), GET, "Test", { sleep: async () => {} }), BrokerError);
  assertEquals(error.code, "provider_unavailable");
  assertEquals(mock.calls.length, 3);
});

Deno.test("read: a timeout is retried like a network error", async () => {
  const mock = new MockFetch(hang, respond(200, { ok: true }));
  const response = await read(ctx(mock, { timeoutMs: 10 }), GET, "Test", { sleep: async () => {} });
  assertEquals(response.status, 200);
  assertEquals(mock.calls.length, 2);
});

Deno.test("read: a Retry-After longer than the cap is handed back, not waited out", async () => {
  const mock = new MockFetch(respond(429, {}, { "retry-after": "120" }));
  const response = await read(ctx(mock), GET, "Test", { sleep: () => Promise.reject(new Error("must not sleep")) });
  assertEquals(response.status, 429);
  assertEquals(mock.calls.length, 1);
  const error = errorFromResponse("Test", response);
  assertEquals(error.code, "rate_limited");
  assertEquals(error.details.retryAfterMs, 120_000);
});

Deno.test("read: a 4xx is returned at once (never retried)", async () => {
  const mock = new MockFetch(respond(422, { message: "bad" }));
  const response = await read(ctx(mock), GET, "Test", { sleep: () => Promise.reject(new Error("must not sleep")) });
  assertEquals(response.status, 422);
  assertEquals(mock.calls.length, 1);
});

Deno.test("sendOnce: a timeout is unknown after exactly one attempt", async () => {
  const mock = new MockFetch(hang);
  const outcome = await sendOnce(ctx(mock, { timeoutMs: 10 }), POST);
  assertEquals(outcome.kind, "unknown");
  assertEquals(mock.calls.length, 1);
});

Deno.test("sendOnce: a network error is unknown after exactly one attempt", async () => {
  const mock = new MockFetch(networkError);
  assertEquals((await sendOnce(ctx(mock), POST)).kind, "unknown");
  assertEquals(mock.calls.length, 1);
});

Deno.test("sendOnce: a 5xx is unknown (the provider may have acted)", async () => {
  const mock = new MockFetch(respond(503, { message: "busy" }));
  const outcome = await sendOnce(ctx(mock), POST);
  assertEquals(outcome.kind, "unknown");
  assertEquals(mock.calls.length, 1);
});

Deno.test("sendOnce: a 4xx is a definite answer", async () => {
  const mock = new MockFetch(respond(422, { message: "nope" }));
  const outcome = await sendOnce(ctx(mock), POST);
  assert(outcome.kind === "response");
  assertEquals(outcome.response.status, 422);
});

Deno.test("errors: codes by status, provider message kept, secrets scrubbed", () => {
  assertEquals(codeForStatus(401), "unauthorized");
  assertEquals(codeForStatus(403), "forbidden");
  assertEquals(codeForStatus(404), "not_found");
  assertEquals(codeForStatus(422), "invalid_request");
  assertEquals(codeForStatus(500), "provider_unavailable");
  const response = { status: 401, headers: new Headers(), text: "", body: { code: 40110000, message: "key PKTESTKEYID123 is not authorized" } };
  const error = errorFromResponse("Alpaca", response, ["PKTESTKEYID123"]);
  assertEquals(error.code, "unauthorized");
  assertEquals(error.details.providerCode, "40110000");
  assert(!error.message.includes("PKTESTKEYID123"));
  assert(error.message.includes("[redacted]"));
});

Deno.test("Retry-After: delta seconds and HTTP dates", () => {
  assertEquals(retryAfterMs(new Headers({ "retry-after": "3" })), 3000);
  const now = Date.parse("2026-11-13T00:00:00Z");
  assertEquals(retryAfterMs(new Headers({ "retry-after": "Fri, 13 Nov 2026 00:00:05 GMT" }), now), 5000);
  assertEquals(retryAfterMs(new Headers()), undefined);
});

Deno.test("backoff: full jitter stays under the capped exponential", () => {
  assertEquals(backoffMs(1, { random: () => 0.999, baseDelayMs: 100, maxDelayMs: 1000 }), 99);
  assertEquals(backoffMs(5, { random: () => 0.999, baseDelayMs: 100, maxDelayMs: 1000 }), 999);
  assertEquals(backoffMs(3, { random: () => 0 }), 0);
});

// MARK: - Decimal

Deno.test("decimal: exact sums, differences, comparisons", () => {
  assertEquals(Decimal.add("0.1", "0.2"), "0.3");
  assertEquals(Decimal.add("1.50", "2"), "3.5");
  assertEquals(Decimal.subtract("10", "10.000"), "0");
  assertEquals(Decimal.subtract("1", "2.5"), "-1.5");
  assertEquals(Decimal.compare("0.00012345", "0.0001234"), 1);
  assertEquals(Decimal.compare("2", "2.000"), 0);
  assertEquals(Decimal.max("-1", "0"), "0");
  assertEquals(Decimal.normalise("0012.3400"), "12.34");
  assertEquals(Decimal.normalise("-0.000"), "0");
});

Deno.test("decimal: division truncates at the scale and refuses zero", () => {
  assertEquals(Decimal.divide("100", "40000", 18), "0.0025");
  assertEquals(Decimal.divide("1", "3", 6), "0.333333");
  assertEquals(Decimal.divide("10.5", "0.25"), "42");
  assertThrows(() => Decimal.divide("1", "0"), RangeError);
});

Deno.test("decimal: validation and fractional detection", () => {
  assert(Decimal.isDecimal("123.45"));
  assert(!Decimal.isDecimal("1e5"));
  assert(!Decimal.isDecimal(12.5));
  assert(Decimal.isPositiveDecimal("0.0001"));
  assert(!Decimal.isPositiveDecimal("0"));
  assert(!Decimal.isPositiveDecimal("-1"));
  assert(Decimal.isFractional("1.5"));
  assert(!Decimal.isFractional("2.000"));
  assert(!Decimal.isFractional("7"));
});

// MARK: - Registry

Deno.test("registry: every provider has an adapter, an explanation and no transfer access", () => {
  assertEquals(PROVIDERS.map((p) => p.id), ["alpaca", "coinbase"]);
  for (const info of PROVIDERS) {
    assertEquals(adapterFor(info.id).provider, info.id);
    assert(info.permissions.read.length > 0 && info.permissions.trade.length > 0);
    assert(/transfer|withdraw/i.test(info.neverRequested));
  }
  assert(isProviderID("alpaca"));
  assert(!isProviderID("binance"));
});

Deno.test("registry: capabilities say what each environment can do", () => {
  assertEquals(capabilitiesFor("alpaca", "paper").executionAvailable, true);
  assertEquals(capabilitiesFor("alpaca", "sandbox").executionAvailable, false);
  assertEquals(capabilitiesFor("coinbase", "paper").executionAvailable, false);
  assertEquals(capabilitiesFor("coinbase", "sandbox").executionAvailable, true);
  for (const env of ["paper", "live", "sandbox"] as const) {
    for (const provider of ["alpaca", "coinbase"] as const) {
      for (const order of capabilitiesFor(provider, env).orders) {
        assertEquals(order.shortSelling, false);
        assertEquals(order.margin, false);
      }
    }
  }
});
