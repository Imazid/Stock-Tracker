// Alpaca Trading API adapter, against scripted responses shaped like Alpaca's documented
// payloads. No network.
// Run: npx -y deno test --allow-read supabase/functions/tests/brokers_*.test.ts

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { ALPACA_STATUS, alpacaAdapter, normaliseOrder } from "../_shared/brokers/alpaca.ts";
import { type AdapterContext, BrokerError, type BrokerOrderRequest } from "../_shared/brokers/types.ts";
import { hang, MockFetch, respond } from "./brokers_mock.ts";

const KEY_ID = "PKTESTKEYID123456";
const SECRET = "SECRETvalueThatMustNeverLeak";

function ctx(mock: MockFetch, extra: Partial<AdapterContext> = {}): AdapterContext {
  return { environment: "paper", credentials: { provider: "alpaca", keyID: KEY_ID, secretKey: SECRET }, fetch: mock.fetch, timeoutMs: 50, ...extra };
}

const ACCOUNT = {
  id: "904837e3-3b76-47ec-b432-046db621571b",
  account_number: "PA2KBX4X3M9W",
  status: "ACTIVE",
  crypto_status: "ACTIVE",
  currency: "USD",
  cash: "10000.55",
  buying_power: "40000.00",
  non_marginable_buying_power: "9500.55",
  equity: "12000.10",
  portfolio_value: "12000.10",
  trading_blocked: false,
  transfers_blocked: false,
  account_blocked: false,
  trade_suspended_by_user: false,
  pattern_day_trader: false,
  shorting_enabled: true,
  multiplier: "4",
};

const ORDER = {
  id: "61e69015-8549-4bfd-b9c3-01e75843f47d",
  client_order_id: "intent-abc-123",
  created_at: "2026-11-10T15:00:01.123456Z",
  updated_at: "2026-11-10T15:00:01.223456Z",
  submitted_at: "2026-11-10T15:00:01.100000Z",
  filled_at: null,
  asset_class: "us_equity",
  symbol: "AAPL",
  qty: "1.5",
  notional: null,
  filled_qty: "0",
  filled_avg_price: null,
  order_class: "",
  type: "market",
  order_type: "market",
  side: "buy",
  time_in_force: "day",
  limit_price: null,
  stop_price: null,
  status: "new",
  extended_hours: false,
};

const BUY_AAPL: BrokerOrderRequest = {
  clientOrderID: "intent-abc-123",
  symbol: "AAPL",
  assetClass: "us_equity",
  side: "buy",
  type: "market",
  timeInForce: "day",
  quantity: "1.5",
};

Deno.test("alpaca: account → normalised account and balance, decimal strings untouched", async () => {
  const mock = new MockFetch(respond(200, ACCOUNT), respond(200, ACCOUNT));
  const [account] = await alpacaAdapter.accounts(ctx(mock));
  assertEquals(account.providerAccountID, ACCOUNT.id);
  assertEquals(account.label, "Alpaca paper PA2KBX4X3M9W");
  assertEquals(account.status, "active");
  assertEquals(account.cash, "10000.55");
  assertEquals(account.buyingPower, "40000.00");
  assertEquals(account.tradingEnabled, true);
  assertEquals(account.tradingBlockers, []);
  assertEquals(mock.calls[0].url, "https://paper-api.alpaca.markets/v2/account");
  assertEquals(mock.calls[0].headers["apca-api-key-id"], KEY_ID);
  assertEquals(mock.calls[0].headers["apca-api-secret-key"], SECRET);

  const [balance] = await alpacaAdapter.balances(ctx(mock));
  // available = non-marginable buying power (no margin here); reserved = cash − available
  assertEquals(balance, { providerAccountID: ACCOUNT.id, currency: "USD", total: "10000.55", available: "9500.55", reserved: "500" });
});

Deno.test("alpaca: blocked account flags become blockers and disable trading", async () => {
  const mock = new MockFetch(respond(200, { ...ACCOUNT, status: "ACTION_REQUIRED", trading_blocked: true, pattern_day_trader: true }));
  const [account] = await alpacaAdapter.accounts(ctx(mock));
  assertEquals(account.tradingEnabled, false);
  assertEquals(account.status, "restricted");
  assertEquals(account.tradingBlockers.length, 3);
  assert(account.tradingBlockers.some((b) => b.includes("pattern day trader")));
});

Deno.test("alpaca: validate reports read+trade (Alpaca keys aren't scoped)", async () => {
  const mock = new MockFetch(respond(200, ACCOUNT));
  const result = await alpacaAdapter.validate(ctx(mock));
  assertEquals(result.permissions, ["read", "trade"]);
  assertEquals(result.accounts.length, 1);
});

Deno.test("alpaca: positions keep stocks and crypto, skip options", async () => {
  const positions = [
    { asset_id: "a", symbol: "AAPL", exchange: "NASDAQ", asset_class: "us_equity", avg_entry_price: "189.123456", qty: "2.5", side: "long", market_value: "500.25", cost_basis: "472.81", current_price: "200.10" },
    { asset_id: "b", symbol: "BTC/USD", exchange: "CRYPTO", asset_class: "crypto", avg_entry_price: "64000.5", qty: "0.00012345", side: "long", market_value: "8.10", cost_basis: "7.90", current_price: "65600" },
    { asset_id: "c", symbol: "AAPL261218C00200000", exchange: "", asset_class: "us_option", avg_entry_price: "3.1", qty: "1", side: "long", market_value: "310", cost_basis: "300", current_price: "3.1" },
  ];
  const mock = new MockFetch(respond(200, ACCOUNT), respond(200, positions));
  const result = await alpacaAdapter.positions(ctx(mock));
  assertEquals(result.map((p) => p.symbol), ["AAPL", "BTC/USD"]);
  assertEquals(result[1].quantity, "0.00012345");
  assertEquals(result[0].averageEntryPrice, "189.123456");
  assertEquals(result[0].providerAccountID, ACCOUNT.id);
});

Deno.test("alpaca: submit sends our client_order_id and decimal strings, once", async () => {
  const mock = new MockFetch(respond(200, ORDER));
  const result = await alpacaAdapter.submit(ctx(mock), BUY_AAPL);
  assertEquals(mock.calls.length, 1);
  const call = mock.calls[0];
  assertEquals(call.method, "POST");
  assertEquals(call.url, "https://paper-api.alpaca.markets/v2/orders");
  assertEquals(call.body, { symbol: "AAPL", side: "buy", type: "market", time_in_force: "day", client_order_id: "intent-abc-123", qty: "1.5" });
  assert(result.outcome === "accepted");
  assertEquals(result.order.status, "accepted"); // Alpaca "new" = routed
  assertEquals(result.order.providerStatus, "new");
  assertEquals(result.order.clientOrderID, "intent-abc-123");
  assertEquals(result.order.quantity, "1.5");
});

Deno.test("alpaca: a submit that times out is unknown after ONE request", async () => {
  const mock = new MockFetch(hang);
  const result = await alpacaAdapter.submit(ctx(mock, { timeoutMs: 10 }), BUY_AAPL);
  assertEquals(result.outcome, "unknown");
  assertEquals(mock.calls.length, 1);
});

Deno.test("alpaca: a submit answered 5xx is unknown after ONE request", async () => {
  const mock = new MockFetch(respond(504, { message: "gateway timeout" }));
  assertEquals((await alpacaAdapter.submit(ctx(mock), BUY_AAPL)).outcome, "unknown");
  assertEquals(mock.calls.length, 1);
});

Deno.test("alpaca: 403 on an order is insufficient buying power; 422 is invalid", async () => {
  const mock = new MockFetch(
    respond(403, { code: 40310000, message: "insufficient buying power" }),
    respond(422, { code: 42210000, message: "qty must be > 0" }),
    respond(422, { code: 40010001, message: "client_order_id must be unique" }),
  );
  const a = await alpacaAdapter.submit(ctx(mock), BUY_AAPL);
  assert(a.outcome === "rejected");
  assertEquals(a.code, "insufficient_funds");
  const b = await alpacaAdapter.submit(ctx(mock), BUY_AAPL);
  assert(b.outcome === "rejected");
  assertEquals(b.code, "invalid_request");
  const c = await alpacaAdapter.submit(ctx(mock), BUY_AAPL);
  assert(c.outcome === "rejected");
  assertEquals(c.code, "duplicate_client_order_id");
});

Deno.test("alpaca: live orders are refused without allowLive — nothing is sent", async () => {
  const mock = new MockFetch();
  const error = await assertRejects(() => alpacaAdapter.submit(ctx(mock, { environment: "live" }), BUY_AAPL), BrokerError);
  assertEquals(error.code, "environment_refused");
  await assertRejects(() => alpacaAdapter.cancel(ctx(mock, { environment: "live" }), ORDER.id), BrokerError);
  await assertRejects(() => alpacaAdapter.replace!(ctx(mock, { environment: "live" }), ORDER.id, { limitPrice: "10" }), BrokerError);
  assertEquals(mock.calls.length, 0);
});

Deno.test("alpaca: with allowLive the live host is used (reads never need it)", async () => {
  const mock = new MockFetch(respond(200, ORDER), respond(200, ACCOUNT));
  const result = await alpacaAdapter.submit(ctx(mock, { environment: "live", allowLive: true }), BUY_AAPL);
  assertEquals(result.outcome, "accepted");
  assertEquals(mock.calls[0].url, "https://api.alpaca.markets/v2/orders");
  await alpacaAdapter.accounts(ctx(mock, { environment: "live" }));
  assertEquals(mock.calls[1].url, "https://api.alpaca.markets/v2/account");
});

Deno.test("alpaca: requests outside the provider's rules are refused before sending", async () => {
  const mock = new MockFetch();
  const refused = async (request: BrokerOrderRequest, code: string) => {
    const error = await assertRejects(() => alpacaAdapter.submit(ctx(mock), request), BrokerError);
    assertEquals(error.code, code, request.clientOrderID);
  };
  await refused({ ...BUY_AAPL, clientOrderID: "notional-limit", quantity: undefined, notional: "100", type: "limit", limitPrice: "190" }, "unsupported");
  await refused({ ...BUY_AAPL, clientOrderID: "fraction-gtc", timeInForce: "gtc" }, "unsupported");
  await refused({ ...BUY_AAPL, clientOrderID: "stock-ioc", quantity: "1", timeInForce: "ioc" }, "unsupported");
  await refused({ ...BUY_AAPL, clientOrderID: "crypto-day", symbol: "BTC/USD", assetClass: "crypto", timeInForce: "day" }, "unsupported");
  await refused({ ...BUY_AAPL, clientOrderID: "crypto-stop", symbol: "BTC/USD", assetClass: "crypto", type: "stop", timeInForce: "gtc", stopPrice: "1" }, "unsupported");
  await refused({ ...BUY_AAPL, clientOrderID: "both", notional: "100" }, "invalid_request");
  await refused({ ...BUY_AAPL, clientOrderID: "float", quantity: "1e3" }, "invalid_request");
  await refused({ ...BUY_AAPL, clientOrderID: "limit-without-price", type: "limit" }, "invalid_request");
  await refused({ ...BUY_AAPL, clientOrderID: "bad id with spaces" }, "invalid_request");
  assertEquals(mock.calls.length, 0);
});

Deno.test("alpaca: crypto notional market order is accepted with gtc", async () => {
  const mock = new MockFetch(respond(200, { ...ORDER, symbol: "BTC/USD", asset_class: "crypto", qty: null, notional: "100", time_in_force: "gtc", status: "pending_new" }));
  const result = await alpacaAdapter.submit(ctx(mock), {
    clientOrderID: "btc-100",
    symbol: "BTC/USD",
    assetClass: "crypto",
    side: "buy",
    type: "market",
    timeInForce: "gtc",
    notional: "100",
  });
  assert(result.outcome === "accepted");
  assertEquals(mock.calls[0].body, { symbol: "BTC/USD", side: "buy", type: "market", time_in_force: "gtc", client_order_id: "btc-100", notional: "100" });
  assertEquals(result.order.status, "pending_new");
  assertEquals(result.order.notional, "100");
});

Deno.test("alpaca: findOrderByClientID uses the by_client_order_id path; 404 means no such order", async () => {
  const mock = new MockFetch(respond(200, ORDER), respond(404, { code: 40410000, message: "order not found" }));
  const found = await alpacaAdapter.findOrderByClientID(ctx(mock), "intent-abc-123");
  assertEquals(found?.providerOrderID, ORDER.id);
  assertEquals(mock.calls[0].url, "https://paper-api.alpaca.markets/v2/orders:by_client_order_id?client_order_id=intent-abc-123");
  assertEquals(await alpacaAdapter.findOrderByClientID(ctx(mock), "never-sent"), undefined);
});

Deno.test("alpaca: fills page with page_token and stop at `since`", async () => {
  const fill = (id: string, time: string) => ({
    activity_type: "FILL", id, cum_qty: "1", leaves_qty: "0", order_id: ORDER.id, order_status: "filled",
    price: "190.01", qty: "1", side: "buy", symbol: "AAPL", transaction_time: time, type: "fill",
  });
  const mock = new MockFetch(
    respond(200, [fill("20261110150001::a", "2026-11-10T15:00:01Z"), fill("20261110140001::b", "2026-11-10T14:00:01Z")]),
    respond(200, [fill("20261110130001::c", "2026-11-10T13:00:01Z")]),
    respond(200, [fill("20261110150001::a", "2026-11-10T15:00:01Z"), fill("20261109150001::z", "2026-11-09T15:00:01Z")]),
  );
  const first = await alpacaAdapter.fills(ctx(mock), { limit: 2 });
  assertEquals(first.items.map((f) => f.providerFillID), ["20261110150001::a", "20261110140001::b"]);
  assertEquals(first.cursor, "20261110140001::b");
  assert(mock.calls[0].url.includes("/v2/account/activities/FILL?direction=desc&page_size=2"));
  const second = await alpacaAdapter.fills(ctx(mock), { limit: 2, cursor: first.cursor });
  assert(mock.calls[1].url.includes("page_token=20261110140001%3A%3Ab"));
  assertEquals(second.items.length, 1);
  assertEquals(second.cursor, undefined);
  assertEquals(second.items[0].price, "190.01");
  // `since` is applied locally too (Alpaca's date filters use created_at, null on fills).
  const recent = await alpacaAdapter.fills(ctx(mock), { limit: 2, since: "2026-11-10T00:00:00Z" });
  assertEquals(recent.items.map((f) => f.providerFillID), ["20261110150001::a"]);
  assertEquals(recent.cursor, undefined);
});

Deno.test("alpaca: orders page back in time with `until`", async () => {
  const mock = new MockFetch(respond(200, [ORDER, { ...ORDER, id: "o2", submitted_at: "2026-11-09T15:00:00Z" }]));
  const page = await alpacaAdapter.orders(ctx(mock), { status: "all", limit: 2 });
  assertEquals(page.items.length, 2);
  assertEquals(page.cursor, "2026-11-09T15:00:00Z");
  assert(mock.calls[0].url.includes("/v2/orders?status=all&limit=2&direction=desc&nested=false"));
});

Deno.test("alpaca: cancel — 204 accepted, 422 no longer cancelable", async () => {
  const mock = new MockFetch(() => new Response(null, { status: 204 }), respond(422, { message: "order is not cancelable" }));
  assertEquals(await alpacaAdapter.cancel(ctx(mock), ORDER.id), { accepted: true });
  assertEquals(mock.calls[0].method, "DELETE");
  assertEquals((await alpacaAdapter.cancel(ctx(mock), ORDER.id)).accepted, false);
});

Deno.test("alpaca: replace PATCHes once and returns the new order; fractional qty refused", async () => {
  const mock = new MockFetch(respond(200, { ...ORDER, id: "new-id", replaces: ORDER.id, type: "limit", limit_price: "185.5", qty: "2" }));
  const result = await alpacaAdapter.replace!(ctx(mock), ORDER.id, { quantity: "2", limitPrice: "185.5" });
  assert(result.outcome === "accepted");
  assertEquals(result.order.providerOrderID, "new-id");
  assertEquals(mock.calls[0].method, "PATCH");
  assertEquals(mock.calls[0].body, { qty: "2", limit_price: "185.5" });
  const error = await assertRejects(() => alpacaAdapter.replace!(ctx(mock), ORDER.id, { quantity: "1.5" }), BrokerError);
  assertEquals(error.code, "invalid_request");
  assertEquals(mock.calls.length, 1);
});

Deno.test("alpaca: every documented status maps; unknown ones stay unknown", () => {
  for (const status of ["new", "partially_filled", "filled", "done_for_day", "canceled", "expired", "replaced", "pending_cancel", "pending_replace", "accepted", "pending_new", "accepted_for_bidding", "stopped", "rejected"]) {
    assert(ALPACA_STATUS[status] !== undefined, status);
  }
  assertEquals(normaliseOrder({ ...ORDER, status: "suspended" }).status, "unknown");
  assertEquals(normaliseOrder({ ...ORDER, status: "something_new" }).status, "unknown");
  assertEquals(normaliseOrder({ ...ORDER, status: "partially_filled", filled_qty: "0.5", filled_avg_price: "190.2" }).averageFillPrice, "190.2");
});

Deno.test("alpaca: sandbox isn't an Alpaca environment", async () => {
  const mock = new MockFetch();
  const error = await assertRejects(() => alpacaAdapter.accounts(ctx(mock, { environment: "sandbox" })), BrokerError);
  assertEquals(error.code, "unsupported");
});

Deno.test("alpaca: a 401 never echoes the secret", async () => {
  const mock = new MockFetch(respond(401, { code: 40110000, message: `request is not authorized for ${SECRET}` }));
  const error = await assertRejects(() => alpacaAdapter.accounts(ctx(mock)), BrokerError);
  assertEquals(error.code, "unauthorized");
  assert(!error.message.includes(SECRET));
});

Deno.test("alpaca: Coinbase credentials are refused", async () => {
  const mock = new MockFetch();
  const error = await assertRejects(
    () => alpacaAdapter.accounts({ environment: "paper", credentials: { provider: "coinbase", keyName: "k", privateKeyPEM: "p" }, fetch: mock.fetch }),
    BrokerError,
  );
  assertEquals(error.code, "invalid_request");
});
