// Coinbase Advanced Trade adapter and its CDP JWT signing, against scripted responses shaped
// like Coinbase's documented payloads. Keys are generated in the test; no network.
// Run: npx -y deno test --allow-read supabase/functions/tests/brokers_*.test.ts

import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { buildJWT, bytesToBase64, importSigningKey, pemToPkcs8, sec1ToPkcs8 } from "../_shared/brokers/coinbase_auth.ts";
import { codeForFailure, coinbaseAdapter, normaliseFill, normaliseOrder } from "../_shared/brokers/coinbase.ts";
import { type AdapterContext, BrokerError, type BrokerOrderRequest } from "../_shared/brokers/types.ts";
import { type Handler, hang, MockFetch, respond } from "./brokers_mock.ts";

const KEY_NAME = "organizations/org-1111/apiKeys/key-2222";
const NOW = Date.parse("2026-11-13T02:00:00Z");

// MARK: - Key material made here, in the test

function pem(label: string, der: Uint8Array): string {
  const body = bytesToBase64(der).match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----\n`;
}

/** The SEC1 ECPrivateKey inside a PKCS#8 PrivateKeyInfo (the last OCTET STRING). */
function sec1FromPkcs8(pkcs8: Uint8Array): Uint8Array {
  // 30 len | 02 01 00 | 30 13 <algid> | 04 len <sec1>
  let at = 2 + (pkcs8[1] & 0x80 ? pkcs8[1] & 0x7f : 0); // outer header
  at += 3; // version
  at += 2 + pkcs8[at + 1]; // algorithm identifier
  assertEquals(pkcs8[at], 0x04);
  let length = pkcs8[at + 1];
  let start = at + 2;
  if (length & 0x80) {
    const n = length & 0x7f;
    length = 0;
    for (let i = 0; i < n; i++) length = (length << 8) | pkcs8[start + i];
    start += n;
  }
  return pkcs8.slice(start, start + length);
}

/** Adds the optional `[0] parameters` (the curve OID) to a SEC1 key, as OpenSSL writes it. */
function withParameters(sec1: Uint8Array, curveOID: number[]): Uint8Array {
  // 30 len | 02 01 01 | 04 20 <32 bytes> | rest...
  const privEnd = 2 + 3 + 2 + 32;
  const param = Uint8Array.of(0xa0, curveOID.length, ...curveOID);
  const content = new Uint8Array([...sec1.slice(2, privEnd), ...param, ...sec1.slice(privEnd)]);
  assert(content.length < 128);
  return Uint8Array.of(0x30, content.length, ...content);
}

const P256_OID = [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
const P384_OID = [0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22];

async function keyPair() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const sec1 = sec1FromPkcs8(pkcs8);
  return { pair, pkcs8, sec1, sec1PEM: pem("EC PRIVATE KEY", sec1), pkcs8PEM: pem("PRIVATE KEY", pkcs8) };
}

const KEYS = await keyPair();

function decodeSegment(segment: string): Record<string, unknown> {
  const base64 = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(segment.length / 4) * 4, "=");
  return JSON.parse(atob(base64));
}

function base64urlBytes(segment: string): Uint8Array<ArrayBuffer> {
  const base64 = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(segment.length / 4) * 4, "=");
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

async function verifyJWT(token: string, publicKey: CryptoKey): Promise<{ header: Record<string, unknown>; claims: Record<string, unknown> }> {
  const [h, c, s] = token.split(".");
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, base64urlBytes(s), new TextEncoder().encode(`${h}.${c}`));
  assert(valid, "JWT signature must verify with the matching public key");
  return { header: decodeSegment(h), claims: decodeSegment(c) };
}

function ctx(mock: MockFetch, extra: Partial<AdapterContext> = {}): AdapterContext {
  return {
    environment: "live",
    allowLive: true,
    credentials: { provider: "coinbase", keyName: KEY_NAME, privateKeyPEM: KEYS.sec1PEM },
    fetch: mock.fetch,
    now: () => NOW,
    timeoutMs: 50,
    ...extra,
  };
}

// MARK: - Auth

Deno.test("coinbase auth: SEC1 PEM is re-wrapped to PKCS#8 and signs a verifiable ES256 JWT", async () => {
  const key = await importSigningKey(KEYS.sec1PEM);
  const token = await buildJWT({ keyName: KEY_NAME, key, method: "POST", host: "api.coinbase.com", path: "/api/v3/brokerage/orders", nowMs: NOW, nonce: "abc123" });
  const { header, claims } = await verifyJWT(token, KEYS.pair.publicKey);
  assertEquals(header, { alg: "ES256", kid: KEY_NAME, nonce: "abc123", typ: "JWT" });
  const nbf = Math.floor(NOW / 1000);
  assertEquals(claims, { sub: KEY_NAME, iss: "cdp", nbf, exp: nbf + 120, uri: "POST api.coinbase.com/api/v3/brokerage/orders" });
});

Deno.test("coinbase auth: PKCS#8 PEM and \\n-escaped PEM both import", async () => {
  const fromPkcs8 = await importSigningKey(KEYS.pkcs8PEM);
  const escaped = KEYS.sec1PEM.replace(/\n/g, "\\n");
  const fromEscaped = await importSigningKey(escaped);
  for (const key of [fromPkcs8, fromEscaped]) {
    const token = await buildJWT({ keyName: KEY_NAME, key, method: "GET", host: "api.coinbase.com", path: "/api/v3/brokerage/accounts", nowMs: NOW });
    const { header } = await verifyJWT(token, KEYS.pair.publicKey);
    assertEquals(String(header.nonce).length, 32);
  }
});

Deno.test("coinbase auth: SEC1 with the curve parameter imports; another curve is refused", async () => {
  const withP256 = withParameters(KEYS.sec1, P256_OID);
  const key = await importSigningKey(pem("EC PRIVATE KEY", withP256));
  const token = await buildJWT({ keyName: KEY_NAME, key, method: "GET", host: "api.coinbase.com", path: "/x", nowMs: NOW });
  await verifyJWT(token, KEYS.pair.publicKey);
  const error = assertThrows(() => sec1ToPkcs8(withParameters(KEYS.sec1, P384_OID)), BrokerError);
  assertEquals(error.code, "invalid_request");
});

Deno.test("coinbase auth: our PKCS#8 wrapping matches what WebCrypto exports", () => {
  // WebCrypto's own PKCS#8 = AlgorithmIdentifier(ecPublicKey, P-256) + the same SEC1 body.
  assertEquals(sec1ToPkcs8(KEYS.sec1), KEYS.pkcs8);
  assertEquals(pemToPkcs8(KEYS.sec1PEM), KEYS.pkcs8);
});

Deno.test("coinbase auth: Ed25519 keys and garbage are refused with a clear reason", async () => {
  const ed = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const edPEM = pem("PRIVATE KEY", new Uint8Array(await crypto.subtle.exportKey("pkcs8", ed.privateKey)));
  const error = await assertRejects(() => importSigningKey(edPEM), BrokerError);
  assert(error.message.includes("ES256"));
  await assertRejects(() => importSigningKey("not a key"), BrokerError);
  await assertRejects(() => importSigningKey(pem("RSA PRIVATE KEY", Uint8Array.of(1, 2, 3))), BrokerError);
});

// MARK: - Orders

const BUY_BTC: BrokerOrderRequest = {
  clientOrderID: "intent-btc-1",
  symbol: "BTC-USD",
  assetClass: "crypto",
  side: "buy",
  type: "market",
  timeInForce: "ioc",
  notional: "100",
};

const SUCCESS = {
  success: true,
  success_response: { order_id: "11111111-2222-3333-4444-555555555555", product_id: "BTC-USD", side: "BUY", client_order_id: "intent-btc-1" },
  order_configuration: { market_market_ioc: { quote_size: "100" } },
};

Deno.test("coinbase: submit signs the request, sends client_order_id and one order_configuration", async () => {
  const mock = new MockFetch(respond(200, SUCCESS));
  const result = await coinbaseAdapter.submit(ctx(mock), BUY_BTC);
  assertEquals(mock.calls.length, 1);
  const call = mock.calls[0];
  assertEquals(call.url, "https://api.coinbase.com/api/v3/brokerage/orders");
  assertEquals(call.body, { client_order_id: "intent-btc-1", product_id: "BTC-USD", side: "BUY", order_configuration: { market_market_ioc: { quote_size: "100" } } });
  const token = call.headers.authorization.replace(/^Bearer /, "");
  const { claims } = await verifyJWT(token, KEYS.pair.publicKey);
  assertEquals(claims.uri, "POST api.coinbase.com/api/v3/brokerage/orders");
  assert(result.outcome === "accepted");
  assertEquals(result.order.providerOrderID, "11111111-2222-3333-4444-555555555555");
  assertEquals(result.order.status, "pending_new");
  assertEquals(result.order.notional, "100");
  assert(!JSON.stringify(call).includes("PRIVATE KEY"));
});

Deno.test("coinbase: an HTTP-200 error_response is a rejection with the provider's reason", async () => {
  const mock = new MockFetch(respond(200, {
    success: false,
    error_response: { error: "INSUFFICIENT_FUND", message: "Insufficient balance in source account", error_details: "", new_order_failure_reason: "INSUFFICIENT_FUND" },
  }));
  const result = await coinbaseAdapter.submit(ctx(mock), BUY_BTC);
  assert(result.outcome === "rejected");
  assertEquals(result.code, "insufficient_funds");
  assert(result.message.includes("INSUFFICIENT_FUND"));
  assertEquals(codeForFailure("DUPLICATE_CLIENT_ORDER_ID"), "duplicate_client_order_id");
  assertEquals(codeForFailure("PRODUCT_TRADING_HALTED"), "market_closed");
  assertEquals(codeForFailure("SOMETHING_NEW"), "invalid_request");
});

Deno.test("coinbase: a submit that times out is unknown after ONE request", async () => {
  const mock = new MockFetch(hang);
  const result = await coinbaseAdapter.submit(ctx(mock, { timeoutMs: 10 }), BUY_BTC);
  assertEquals(result.outcome, "unknown");
  assertEquals(mock.calls.length, 1);
});

Deno.test("coinbase: live orders are refused without allowLive — nothing is sent", async () => {
  const mock = new MockFetch();
  const live = ctx(mock, { allowLive: undefined });
  assertEquals((await assertRejects(() => coinbaseAdapter.submit(live, BUY_BTC), BrokerError)).code, "environment_refused");
  assertEquals((await assertRejects(() => coinbaseAdapter.cancel(live, "o1"), BrokerError)).code, "environment_refused");
  assertEquals((await assertRejects(() => coinbaseAdapter.replace!(live, "o1", { limitPrice: "1" }), BrokerError)).code, "environment_refused");
  assertEquals(mock.calls.length, 0);
});

Deno.test("coinbase: paper doesn't exist; the sandbox gets no keys", async () => {
  const mock = new MockFetch(respond(200, SUCCESS));
  const paper = await assertRejects(() => coinbaseAdapter.submit(ctx(mock, { environment: "paper" }), BUY_BTC), BrokerError);
  assertEquals(paper.code, "unsupported");
  const result = await coinbaseAdapter.submit(ctx(mock, { environment: "sandbox", allowLive: undefined }), BUY_BTC);
  assertEquals(result.outcome, "accepted");
  assertEquals(mock.calls.length, 1);
  assertEquals(mock.calls[0].url, "https://api-sandbox.coinbase.com/api/v3/brokerage/orders");
  assertEquals(mock.calls[0].headers.authorization, undefined);
});

Deno.test("coinbase: order configurations for each supported type", async () => {
  const cases: [Partial<BrokerOrderRequest>, Record<string, unknown>][] = [
    [{ type: "market", timeInForce: "fok", notional: undefined, quantity: "0.01" }, { market_market_fok: { base_size: "0.01" } }],
    [{ type: "limit", timeInForce: "gtc", limitPrice: "60000" }, { limit_limit_gtc: { quote_size: "100", limit_price: "60000", post_only: false } }],
    [{ type: "limit", timeInForce: "ioc", limitPrice: "60000" }, { sor_limit_ioc: { quote_size: "100", limit_price: "60000" } }],
    [{ type: "limit", timeInForce: "fok", limitPrice: "60000" }, { limit_limit_fok: { quote_size: "100", limit_price: "60000" } }],
    [
      { type: "stop_limit", timeInForce: "gtc", side: "sell", notional: undefined, quantity: "0.5", limitPrice: "55000", stopPrice: "56000" },
      { stop_limit_stop_limit_gtc: { base_size: "0.5", limit_price: "55000", stop_price: "56000", stop_direction: "STOP_DIRECTION_STOP_DOWN" } },
    ],
  ];
  for (const [change, expected] of cases) {
    const mock = new MockFetch(respond(200, SUCCESS));
    await coinbaseAdapter.submit(ctx(mock), { ...BUY_BTC, ...change });
    assertEquals((mock.calls[0].body as Record<string, unknown>).order_configuration, expected);
  }
});

Deno.test("coinbase: unsupported shapes are refused before sending", async () => {
  const mock = new MockFetch();
  const refused = async (change: Partial<BrokerOrderRequest>, code: string) => {
    const error = await assertRejects(() => coinbaseAdapter.submit(ctx(mock), { ...BUY_BTC, ...change }), BrokerError);
    assertEquals(error.code, code, JSON.stringify(change));
  };
  await refused({ timeInForce: "day" }, "unsupported");
  await refused({ type: "stop", stopPrice: "1" }, "unsupported");
  await refused({ type: "stop_limit", timeInForce: "gtc", limitPrice: "1", stopPrice: "1" }, "unsupported"); // notional stop-limit
  await refused({ assetClass: "us_equity", symbol: "AAPL" }, "unsupported");
  await refused({ symbol: "BTC/USD" }, "invalid_request");
  assertEquals(mock.calls.length, 0);
});

Deno.test("coinbase: preview maps estimates, warnings and errors", async () => {
  const mock = new MockFetch(respond(200, {
    order_total: "101.20", commission_total: "1.20", errs: ["PREVIEW_INSUFFICIENT_FUND"], warning: ["BIG_ORDER"],
    quote_size: "100", base_size: "0.0015384", best_bid: "64999.99", best_ask: "65000.01", preview_id: "p-1", slippage: "0.001",
  }));
  const preview = await coinbaseAdapter.preview!(ctx(mock, { allowLive: undefined }), BUY_BTC);
  assertEquals(preview, {
    estimatedQuantity: "0.0015384",
    estimatedNotional: "100",
    estimatedFee: "1.20",
    feeCurrency: "USD",
    warnings: ["BIG_ORDER"],
    errors: ["PREVIEW_INSUFFICIENT_FUND"],
  });
  assertEquals(mock.calls[0].url, "https://api.coinbase.com/api/v3/brokerage/orders/preview");
});

Deno.test("coinbase: cancel via batch_cancel; a duplicate cancel counts as accepted", async () => {
  const mock = new MockFetch(
    respond(200, { results: [{ success: true, failure_reason: "UNKNOWN_CANCEL_FAILURE_REASON", order_id: "o1" }] }),
    respond(200, { results: [{ success: false, failure_reason: "DUPLICATE_CANCEL_REQUEST", order_id: "o1" }] }),
    respond(200, { results: [{ success: false, failure_reason: "ORDER_IS_FULLY_FILLED", order_id: "o1" }] }),
  );
  assertEquals((await coinbaseAdapter.cancel(ctx(mock), "o1")).accepted, true);
  assertEquals(mock.calls[0].body, { order_ids: ["o1"] });
  assertEquals((await coinbaseAdapter.cancel(ctx(mock), "o1")).accepted, true);
  assertEquals((await coinbaseAdapter.cancel(ctx(mock), "o1")).accepted, false);
});

const OPEN_LIMIT = {
  order_id: "o-limit",
  product_id: "ETH-USD",
  user_id: "u",
  order_configuration: { limit_limit_gtc: { base_size: "0.5", limit_price: "2500.00", post_only: false } },
  side: "SELL",
  client_order_id: "intent-eth-1",
  status: "OPEN",
  time_in_force: "GOOD_UNTIL_CANCELLED",
  created_time: "2026-11-12T23:00:00Z",
  completion_percentage: "20",
  filled_size: "0.1",
  average_filled_price: "2500.00",
  number_of_fills: "1",
  filled_value: "250",
  pending_cancel: false,
  size_in_quote: false,
  total_fees: "1.5",
  order_type: "LIMIT",
  last_fill_time: "2026-11-12T23:05:00Z",
};

Deno.test("coinbase: order normalisation — OPEN with fills is partially filled", () => {
  const order = normaliseOrder(OPEN_LIMIT);
  assertEquals(order.status, "partially_filled");
  assertEquals(order.providerStatus, "OPEN");
  assertEquals(order.side, "sell");
  assertEquals(order.type, "limit");
  assertEquals(order.timeInForce, "gtc");
  assertEquals(order.quantity, "0.5");
  assertEquals(order.limitPrice, "2500.00");
  assertEquals(order.filledQuantity, "0.1");
  assertEquals(order.averageFillPrice, "2500.00");
  assertEquals(normaliseOrder({ ...OPEN_LIMIT, filled_size: "0" }).status, "accepted");
  assertEquals(normaliseOrder({ ...OPEN_LIMIT, status: "CANCEL_QUEUED" }).status, "pending_cancel");
  assertEquals(normaliseOrder({ ...OPEN_LIMIT, status: "FAILED" }).status, "rejected");
  assertEquals(normaliseOrder({ ...OPEN_LIMIT, status: "BRAND_NEW" }).status, "unknown");
});

Deno.test("coinbase: replace reads the order, edits once with price + size", async () => {
  const mock = new MockFetch(respond(200, { order: OPEN_LIMIT }), respond(200, { success: true, errors: [] }));
  const result = await coinbaseAdapter.replace!(ctx(mock), "o-limit", { limitPrice: "2600" });
  assert(result.outcome === "accepted");
  assertEquals(mock.calls[0].url, "https://api.coinbase.com/api/v3/brokerage/orders/historical/o-limit");
  assertEquals(mock.calls[1].body, { order_id: "o-limit", price: "2600", size: "0.5" });
  assertEquals(result.order.limitPrice, "2600");
  assertEquals(result.order.status, "pending_replace");
});

Deno.test("coinbase: an edit that times out is unknown after ONE edit request", async () => {
  const mock = new MockFetch(respond(200, { order: OPEN_LIMIT }), hang);
  const result = await coinbaseAdapter.replace!(ctx(mock, { timeoutMs: 10 }), "o-limit", { limitPrice: "2600" });
  assertEquals(result.outcome, "unknown");
  assertEquals(mock.calls.filter((c) => c.url.endsWith("/orders/edit")).length, 1);
});

Deno.test("coinbase: an edit refused by Coinbase is a rejection", async () => {
  const mock = new MockFetch(respond(200, { order: OPEN_LIMIT }), respond(200, { success: false, errors: [{ edit_failure_reason: "ONLY_LIMIT_ORDER_EDITS_SUPPORTED" }] }));
  const result = await coinbaseAdapter.replace!(ctx(mock), "o-limit", { quantity: "0.4" });
  assert(result.outcome === "rejected");
  assertEquals(result.code, "unsupported");
});

Deno.test("coinbase: findOrderByClientID pages recent orders (no server-side filter)", async () => {
  const other = { ...OPEN_LIMIT, order_id: "x", client_order_id: "someone-else" };
  const mock = new MockFetch(
    respond(200, { orders: [other], has_next: true, cursor: "c2", sequence: "0" }),
    respond(200, { orders: [OPEN_LIMIT], has_next: false, cursor: "" }),
    respond(200, { orders: [other], has_next: false, cursor: "" }),
  );
  const found = await coinbaseAdapter.findOrderByClientID(ctx(mock), "intent-eth-1");
  assertEquals(found?.providerOrderID, "o-limit");
  assert(mock.calls[1].url.includes("cursor=c2"));
  assertEquals(await coinbaseAdapter.findOrderByClientID(ctx(mock), "never-sent"), undefined);
});

Deno.test("coinbase: open orders query asks for OPEN, PENDING and QUEUED", async () => {
  const mock = new MockFetch(respond(200, { orders: [], has_next: false, cursor: "" }));
  const page = await coinbaseAdapter.orders(ctx(mock), { status: "open", limit: 50, since: "2026-11-01T00:00:00Z" });
  assertEquals(page, { items: [], cursor: undefined });
  const url = new URL(mock.calls[0].url);
  assertEquals(url.pathname, "/api/v3/brokerage/orders/historical/batch");
  assertEquals(url.searchParams.getAll("order_status"), ["OPEN", "PENDING", "QUEUED"]);
  assertEquals(url.searchParams.get("start_date"), "2026-11-01T00:00:00Z");
  // The JWT uri never includes the query string.
  const { claims } = await verifyJWT(mock.calls[0].headers.authorization.slice(7), KEYS.pair.publicKey);
  assertEquals(claims.uri, "GET api.coinbase.com/api/v3/brokerage/orders/historical/batch");
});

// MARK: - Accounts

const ACCOUNTS_PAGE_1 = {
  accounts: [
    {
      uuid: "a-usd", name: "USD Wallet", currency: "USD", available_balance: { value: "1500.25", currency: "USD" }, default: true, active: true,
      created_at: "2026-01-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z", deleted_at: null, type: "ACCOUNT_TYPE_FIAT", ready: true,
      hold: { value: "100.00", currency: "USD" }, retail_portfolio_id: "pf-1", platform: "ACCOUNT_PLATFORM_CONSUMER",
    },
    {
      uuid: "a-btc", name: "BTC Wallet", currency: "BTC", available_balance: { value: "0.00012345", currency: "BTC" }, default: false, active: true,
      deleted_at: null, type: "ACCOUNT_TYPE_CRYPTO", ready: true, hold: { value: "0.00000001", currency: "BTC" }, retail_portfolio_id: "pf-1",
    },
  ],
  has_next: true,
  cursor: "next-page",
  size: 2,
};

const ACCOUNTS_PAGE_2 = {
  accounts: [
    { uuid: "a-eth", name: "ETH Wallet", currency: "ETH", available_balance: { value: "0", currency: "ETH" }, active: true, type: "ACCOUNT_TYPE_CRYPTO", hold: { value: "0", currency: "ETH" }, retail_portfolio_id: "pf-1" },
    { uuid: "a-old", name: "Old", currency: "SOL", available_balance: { value: "3", currency: "SOL" }, active: false, type: "ACCOUNT_TYPE_CRYPTO", hold: { value: "0", currency: "SOL" } },
  ],
  has_next: false,
  cursor: "",
  size: 2,
};

Deno.test("coinbase: balances page through every account and add hold exactly", async () => {
  const mock = new MockFetch(respond(200, ACCOUNTS_PAGE_1), respond(200, ACCOUNTS_PAGE_2));
  const balances = await coinbaseAdapter.balances(ctx(mock));
  assertEquals(balances, [
    { providerAccountID: "pf-1", currency: "USD", total: "1600.25", available: "1500.25", reserved: "100" },
    { providerAccountID: "pf-1", currency: "BTC", total: "0.00012346", available: "0.00012345", reserved: "0.00000001" },
    { providerAccountID: "pf-1", currency: "ETH", total: "0", available: "0", reserved: "0" },
  ]);
  assert(mock.calls[1].url.includes("cursor=next-page"));
});

Deno.test("coinbase: positions are crypto wallets with a balance, with no invented values", async () => {
  const mock = new MockFetch(respond(200, ACCOUNTS_PAGE_1), respond(200, ACCOUNTS_PAGE_2));
  const positions = await coinbaseAdapter.positions(ctx(mock));
  assertEquals(positions, [{ providerAccountID: "pf-1", symbol: "BTC", assetClass: "crypto", quantity: "0.00012346", currency: "USD" }]);
});

Deno.test("coinbase: validate refuses a key that can transfer funds", async () => {
  const mock = new MockFetch(respond(200, { can_view: true, can_trade: true, can_transfer: true, portfolio_uuid: "pf-1", portfolio_type: "DEFAULT" }));
  const error = await assertRejects(() => coinbaseAdapter.validate(ctx(mock)), BrokerError);
  assertEquals(error.code, "forbidden");
  assert(/transfer/i.test(error.message));
});

Deno.test("coinbase: a view-only key connects read-only, scoped to its portfolio", async () => {
  const permissions = { can_view: true, can_trade: false, can_transfer: false, portfolio_uuid: "pf-1", portfolio_type: "DEFAULT" };
  const portfolios = { portfolios: [{ name: "Default", uuid: "pf-1", type: "DEFAULT", deleted: false }, { name: "Other", uuid: "pf-2", type: "CONSUMER", deleted: false }] };
  const permissionsResponse = respond(200, permissions);
  const portfoliosResponse = respond(200, portfolios);
  const respondToAccountRequest: Handler = (call, signal) => {
    const path = new URL(call.url).pathname;
    if (path.endsWith("/portfolios")) return portfoliosResponse(call, signal);
    assert(path.endsWith("/key_permissions"));
    return permissionsResponse(call, signal);
  };
  const mock = new MockFetch(permissionsResponse, respondToAccountRequest, respondToAccountRequest);
  const result = await coinbaseAdapter.validate(ctx(mock, { allowLive: undefined }));
  assertEquals(result.permissions, ["read"]);
  assertEquals(result.accounts.map((a) => a.providerAccountID), ["pf-1"]);
  assertEquals(result.accounts[0].label, "Coinbase – Default");
  assertEquals(result.accounts[0].tradingEnabled, false);
  assert(result.accounts[0].tradingBlockers[0].includes("view-only"));
});

Deno.test("coinbase: fills — entry_id is the id, commission the fee, quote-sized fills converted", () => {
  const base = {
    entry_id: "e-1", trade_id: "t-1", order_id: "o-1", trade_time: "2026-11-12T23:05:00Z", trade_type: "FILL", price: "40000",
    size: "0.0025", commission: "0.60", product_id: "BTC-USD", sequence_timestamp: "2026-11-12T23:05:00.1Z", liquidity_indicator: "TAKER",
    size_in_quote: false, user_id: "u", side: "BUY",
  };
  const fill = normaliseFill(base);
  assertEquals(fill, { providerFillID: "e-1", providerOrderID: "o-1", symbol: "BTC-USD", side: "buy", quantity: "0.0025", price: "40000", fee: "0.60", feeCurrency: "USD", executedAt: "2026-11-12T23:05:00Z" });
  // UNVERIFIED in Coinbase's docs: a quote-sized fill's `size` read as a quote amount.
  assertEquals(normaliseFill({ ...base, size: "100", size_in_quote: true }).quantity, "0.0025");
});

Deno.test("coinbase: fills page with the cursor until it's empty", async () => {
  const fill = { entry_id: "e-1", order_id: "o-1", trade_time: "2026-11-12T23:05:00Z", price: "40000", size: "0.1", commission: "1", product_id: "BTC-USD", side: "SELL", size_in_quote: false };
  const mock = new MockFetch(respond(200, { fills: [fill], cursor: "c-2" }), respond(200, { fills: [], cursor: "" }));
  const first = await coinbaseAdapter.fills(ctx(mock), { limit: 1 });
  assertEquals(first.cursor, "c-2");
  const second = await coinbaseAdapter.fills(ctx(mock), { limit: 1, cursor: first.cursor });
  assertEquals(second, { items: [], cursor: undefined });
  assert(mock.calls[1].url.includes("cursor=c-2"));
});

Deno.test("coinbase: capabilities by environment", () => {
  assertEquals(coinbaseAdapter.capabilities("paper").executionAvailable, false);
  const sandbox = coinbaseAdapter.capabilities("sandbox");
  assert(sandbox.notes[0].includes("static"));
  const live = coinbaseAdapter.capabilities("live");
  assertEquals(live.orders[0].timeInForce.market, ["ioc", "fok"]);
  assertEquals(live.orders[0].preview, true);
});
