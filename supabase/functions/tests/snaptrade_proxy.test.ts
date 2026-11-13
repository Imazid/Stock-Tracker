// SnapTrade gateway. Every test runs on an injected fetch: nothing touches the network.
//
//   npx -y deno test --no-check=remote supabase/functions/tests/snaptrade_proxy.test.ts

import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  buildSignedRequest,
  handleSnapTradeRequest,
  scrubSecrets,
  type SnapTradeProxyDeps,
  type SnapTradeUserRecord,
  type SnapTradeUserStore,
} from "../_shared/snaptrade/proxy.ts";

const USER = "11111111-1111-1111-1111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";
const ACCOUNT = "33333333-3333-3333-3333-333333333333";
const NOW = 1_700_000_000_000;
const CONFIG = { clientId: "TESTCLIENT", consumerKey: "consumer-key-for-tests", baseUrl: "https://snaptrade.test" };

class MemoryStore implements SnapTradeUserStore {
  rows = new Map<string, SnapTradeUserRecord>();
  get(userId: string) {
    return Promise.resolve(this.rows.get(userId) ?? null);
  }
  save(userId: string, record: SnapTradeUserRecord) {
    this.rows.set(userId, record);
    return Promise.resolve();
  }
  remove(userId: string) {
    this.rows.delete(userId);
    return Promise.resolve();
  }
}

interface Seen {
  url: URL;
  method: string;
  headers: Headers;
  body: string | null;
}

function harness(respond: (seen: Seen) => Response, store = new MemoryStore()) {
  const calls: Seen[] = [];
  const deps: SnapTradeProxyDeps = {
    config: CONFIG,
    store,
    now: () => NOW,
    fetch: ((input: string | URL | Request, init?: RequestInit) =>
      Promise.resolve().then(() => {
        const seen: Seen = {
          url: new URL(String(input)),
          method: init?.method ?? "GET",
          headers: new Headers(init?.headers),
          body: typeof init?.body === "string" ? init.body : null,
        };
        calls.push(seen);
        return respond(seen);
      })) as typeof fetch,
  };
  return { deps, calls, store };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.test("signatures match independently computed HMAC-SHA256 vectors (openssl)", async () => {
  const get = await buildSignedRequest(CONFIG, "GET", "/accounts", { userId: `st-${USER}`, userSecret: "sek-ret" }, null, NOW);
  assertEquals(new Headers(get.init.headers).get("Signature"), "hNRBX9sG//IHcb78H+H/eX2lxERXgas8PkYpTyvTkmo=");
  assertEquals(
    get.url,
    `https://snaptrade.test/api/v1/accounts?clientId=TESTCLIENT&timestamp=1700000000&userId=st-${USER}&userSecret=sek-ret`,
  );
  const post = await buildSignedRequest(CONFIG, "POST", "/snapTrade/login", { userId: `st-${USER}`, userSecret: "sek-ret" }, { connectionType: "read" }, NOW);
  assertEquals(new Headers(post.init.headers).get("Signature"), "zPbjO/fO92i9RlAJ+BVqPHaMsAAeutnWvRlpvFpqytY=");
  assertEquals(post.init.body, '{"connectionType":"read"}');
});

Deno.test("register: SnapTrade user is derived from the signed-in user and the secret never leaves the server", async () => {
  const { deps, calls, store } = harness(() => json(200, { userId: `st-${USER}`, userSecret: "fresh-secret" }));
  const res = await handleSnapTradeRequest(USER, { operation: "registerUser" }, deps);
  assertEquals(res.status, 201);
  assertFalse(JSON.stringify(res.body).includes("fresh-secret"));
  assertEquals(store.rows.get(USER), { snapTradeUserId: `st-${USER}`, userSecret: "fresh-secret" });
  assertEquals(calls[0].url.pathname, "/api/v1/snapTrade/registerUser");
  assertEquals(JSON.parse(calls[0].body!), { userId: `st-${USER}` });

  const again = await handleSnapTradeRequest(USER, { operation: "registerUser" }, deps);
  assertEquals(again.status, 200);
  assertEquals(calls.length, 1, "already registered: no second upstream call");
});

Deno.test("a device cannot choose whose SnapTrade identity is used", async () => {
  const store = new MemoryStore();
  store.rows.set(USER, { snapTradeUserId: `st-${USER}`, userSecret: "mine" });
  store.rows.set(OTHER, { snapTradeUserId: `st-${OTHER}`, userSecret: "theirs" });
  const { deps, calls } = harness(() => json(200, []), store);
  await handleSnapTradeRequest(USER, { operation: "listAccounts", params: { userId: `st-${OTHER}`, userSecret: "theirs" } }, deps);
  assertEquals(calls[0].url.searchParams.get("userId"), `st-${USER}`);
  assertEquals(calls[0].url.searchParams.get("userSecret"), "mine");
});

Deno.test("only allowlisted operations exist; raw paths and unknown operations are refused", async () => {
  const { deps, calls } = harness(() => json(200, {}));
  for (const body of [
    { operation: "listUsers" },
    { operation: "placeOrder" },
    { path: "/snapTrade/listUsers" },
    "not-an-object",
    null,
  ]) {
    const res = await handleSnapTradeRequest(USER, body, deps);
    assertEquals(res.status, 400);
  }
  assertEquals(calls.length, 0);
});

Deno.test("connection portals are read-only unless the server enables trading connections", async () => {
  const store = new MemoryStore();
  store.rows.set(USER, { snapTradeUserId: `st-${USER}`, userSecret: "s" });
  const { deps, calls } = harness(() => json(200, { redirectURI: "https://app.snaptrade.com/x", sessionId: "abc" }), store);

  const read = await handleSnapTradeRequest(USER, { operation: "loginLink", params: { broker: "ALPACA", connectionPortalVersion: "v3", immediateRedirect: false } }, deps);
  assertEquals(read.status, 200);
  assertEquals(JSON.parse(calls[0].body!), { broker: "ALPACA", connectionPortalVersion: "v3", connectionType: "read", immediateRedirect: false });
  assertEquals((await handleSnapTradeRequest(USER, { operation: "loginLink", params: { connectionPortalVersion: "v9" } }, deps)).status, 400);

  const trade = await handleSnapTradeRequest(USER, { operation: "loginLink", params: { connectionType: "trade" } }, deps);
  assertEquals(trade.status, 403);
  assertEquals((trade.body as { error: { code: string } }).error.code, "TRADE_CONNECTIONS_DISABLED");

  const redirect = await handleSnapTradeRequest(USER, { operation: "loginLink", params: { customRedirect: "https://evil.example" } }, deps);
  assertEquals(redirect.status, 400);
  assertEquals(calls.length, 1, "refused requests never reach SnapTrade");
});

Deno.test("account ids are validated before they reach a URL path", async () => {
  const store = new MemoryStore();
  store.rows.set(USER, { snapTradeUserId: `st-${USER}`, userSecret: "s" });
  const { deps, calls } = harness(() => json(200, []), store);
  const bad = await handleSnapTradeRequest(USER, { operation: "accountHoldings", params: { accountId: "../../snapTrade/listUsers" } }, deps);
  assertEquals(bad.status, 400);
  const ok = await handleSnapTradeRequest(USER, { operation: "accountPositions", params: { accountId: ACCOUNT } }, deps);
  assertEquals(ok.status, 200);
  assertEquals(calls.map((c) => c.url.pathname), [`/api/v1/accounts/${ACCOUNT}/positions`]);
});

Deno.test("legacy Keychain identities are verified with SnapTrade before being stored", async () => {
  const rejected = harness(() => json(401, { detail: "Unable to verify signature sent", code: "1076" }));
  const r1 = await handleSnapTradeRequest(USER, { operation: "importLegacyUser", params: { snapTradeUserId: "old-user", userSecret: "old-secret-123" } }, rejected.deps);
  assertEquals(r1.status, 422);
  assertEquals(rejected.store.rows.size, 0);

  const accepted = harness(() => json(200, []));
  const r2 = await handleSnapTradeRequest(USER, { operation: "importLegacyUser", params: { snapTradeUserId: "old-user", userSecret: "old-secret-123" } }, accepted.deps);
  assertEquals(r2.status, 201);
  assertEquals(accepted.store.rows.get(USER), { snapTradeUserId: "old-user", userSecret: "old-secret-123" });
  assertEquals(accepted.calls[0].url.pathname, "/api/v1/authorizations");
});

Deno.test("upstream errors are mapped and never echo the user secret", async () => {
  const store = new MemoryStore();
  store.rows.set(USER, { snapTradeUserId: `st-${USER}`, userSecret: "top-secret" });
  const { deps } = harness(() => json(500, { detail: "boom for userSecret=top-secret" }), store);
  const res = await handleSnapTradeRequest(USER, { operation: "listAccounts" }, deps);
  assertEquals(res.status, 502);
  assertFalse(JSON.stringify(res.body).includes("top-secret"));

  const down = harness(() => {
    throw new TypeError("network down");
  }, store);
  assertEquals((await handleSnapTradeRequest(USER, { operation: "listAccounts" }, down.deps)).status, 504);
});

Deno.test("deleteUser forgets the stored identity only after SnapTrade confirms", async () => {
  const store = new MemoryStore();
  store.rows.set(USER, { snapTradeUserId: `st-${USER}`, userSecret: "s" });
  const failing = harness(() => json(500, {}), store);
  await handleSnapTradeRequest(USER, { operation: "deleteUser" }, failing.deps);
  assert(store.rows.has(USER));
  const ok = harness(() => json(200, { status: "deleted" }), store);
  assertEquals((await handleSnapTradeRequest(USER, { operation: "deleteUser" }, ok.deps)).status, 200);
  assertFalse(store.rows.has(USER));
  assertEquals(ok.calls[0].url.searchParams.get("userSecret"), null, "deleteUser is signed with userId only");
});

Deno.test("refuses without a verified user or server configuration", async () => {
  const { deps } = harness(() => json(200, {}));
  assertEquals((await handleSnapTradeRequest("", { operation: "status" }, deps)).status, 401);
  const unconfigured = { ...deps, config: { clientId: "", consumerKey: "" } };
  assertEquals((await handleSnapTradeRequest(USER, { operation: "status" }, unconfigured)).status, 503);
});

Deno.test("scrubSecrets removes userSecret at any depth", () => {
  assertEquals(scrubSecrets({ a: [{ userSecret: "x", keep: 1 }], UserSecret: "y" }), { a: [{ keep: 1 }] });
});

Deno.test("activity uses the signed root endpoint and offers only eligible dated USD cash flows", async () => {
  const store = new MemoryStore();
  store.rows.set(USER, { snapTradeUserId: `st-${USER}`, userSecret: "mine" });
  const row = {
    id: "broker-transaction",
    trade_date: "2026-01-15T23:05:00-05:00",
    currency: { code: "USD" },
    symbol: null,
    amount: 620.05,
    type: "CONTRIBUTION",
  };
  const { deps, calls } = harness(() => json(200, {
    data: [
      row,
      row,
      { ...row, id: "withdrawal", type: "WITHDRAWAL", amount: -22.99 },
      { ...row, id: "cad", currency: { code: "CAD" } },
      { ...row, id: "wrong-sign", amount: -10 },
      { ...row, id: "asset", symbol: { symbol: "AAPL" }, units: 2 },
      { ...row, id: "over-precision", amount: 0.0001 },
      { ...row, id: "div", type: "DIVIDEND", symbol: { symbol: "AAPL" }, fee: 0.5 },
      { ...row, id: "split", type: "REVERSE_SPLIT", amount: null },
      { ...row, id: "transfer", type: "INTERNAL_CASH_TRANSFER_OUT", amount: -10 },
      { ...row, id: "ambiguous", type: "TRANSFER", amount: -10 },
      { ...row, id: "bad-day", trade_date: null, settlement_date: "2026-01-15" },
      { ...row, id: "outside", trade_date: "2025-12-31" },
    ],
    pagination: { offset: 0, total: 100 },
  }), store);
  const res = await handleSnapTradeRequest(USER, {
    operation: "accountActivities",
    params: { accountId: ACCOUNT, startDate: "2026-01-01", endDate: "2026-01-31", userId: `st-${OTHER}` },
  }, deps);
  assertEquals(res.status, 200);
  assertEquals(calls[0].method, "GET");
  assertEquals(calls[0].url.pathname, `/accounts/${ACCOUNT}/activities`);
  assertEquals(calls[0].url.searchParams.get("startDate"), "2026-01-01");
  assertEquals(calls[0].url.searchParams.get("limit"), "50");
  assertEquals(calls[0].url.searchParams.get("userId"), `st-${USER}`);
  assert(calls[0].headers.has("Signature"));
  const body = res.body as { activities: { id: string; cashFlow: unknown; symbol: string; currency: string; fee: number }[]; omitted: number; nextOffset: number };
  assertEquals(body.omitted, 2);
  assertEquals(body.nextOffset, 13);
  assertEquals(body.activities.length, 10);
  assertEquals(body.activities[0].cashFlow, { date: "2026-01-15", kind: "deposit", amount: 620.05 });
  assertEquals(body.activities[1].cashFlow, { date: "2026-01-15", kind: "withdrawal", amount: 22.99 });
  assertEquals(body.activities[2].currency, "CAD");
  assertEquals(body.activities[6].symbol, "AAPL");
  assertEquals(body.activities[6].fee, 0.5);
  assertEquals(body.activities[8].cashFlow, { date: "2026-01-15", kind: "withdrawal", amount: 10 });
  assertEquals(body.activities.slice(2, 8).map((x) => x.cashFlow), Array(6).fill(null));
  assertEquals(body.activities[9].cashFlow, null);
  assert(body.activities.every((activity) => /^[a-f0-9]{64}$/.test(activity.id)));
  assertFalse(JSON.stringify(res.body).includes("broker-transaction"));
});

Deno.test("activity refuses malformed dates or pagination and never uses a different user's credentials", async () => {
  const store = new MemoryStore();
  store.rows.set(USER, { snapTradeUserId: `st-${USER}`, userSecret: "mine" });
  const { deps, calls } = harness(() => json(200, { data: [], pagination: { total: 10, offset: 0 } }), store);
  const params = { accountId: ACCOUNT, startDate: "2026-01-01", endDate: "2026-01-31" };
  for (const invalid of [
    { startDate: "2026-02-30" }, { offset: -1 }, { offset: "1" }, { offset: 1.1 }, { accountId: "a/../accounts" },
  ]) {
    assertEquals((await handleSnapTradeRequest(USER, { operation: "accountActivities", params: { ...params, ...invalid } }, deps)).status, 400);
  }
  assertEquals((await handleSnapTradeRequest(OTHER, { operation: "accountActivities", params }, deps)).status, 409);
  assertEquals(calls.length, 0);
  assertEquals((await handleSnapTradeRequest(USER, { operation: "accountActivities", params }, deps)).status, 502);
});
