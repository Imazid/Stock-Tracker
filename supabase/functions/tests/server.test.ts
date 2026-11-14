// The small rules the two edge functions lean on, tested without a stack: who is calling,
// when the stronger sign-in is needed, what counts as loosening a limit, the secret
// comparison, the (empty) live-adapter seam, what may be logged — and a read of the
// source itself to prove nothing in the server can place a real order or ask a model.
//
// Run: npx -y deno test --allow-read supabase/functions/tests/server.test.ts

import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { authenticate, type Caller, requireStepUp, stepUpProblem } from "../_shared/server/auth.ts";
import { errorResponse, Field, HttpError, logEvent, sameSecret, tradingErrorStatus } from "../_shared/server/http.ts";
import { liveAdapter, liveAdapters, LiveTradingDisabledError, reconcile } from "../_shared/server/live.ts";
import { isLoosening } from "../_shared/server/policy.ts";
import type { Order } from "../_shared/trading/orders.ts";
import { type RiskPolicy, standardPolicy } from "../_shared/trading/risk.ts";
import { TradingError } from "../_shared/trading/state.ts";
import { agentActivityWindow } from "../_shared/trading/activity.ts";

Deno.test("agent activity weeks start on local Monday across a daylight saving change", () => {
  const now = Date.parse("2026-10-05T00:00:00Z");
  const window = agentActivityWindow("lastWeek", "Australia/Sydney", now);
  assertEquals(new Date(window.from).toISOString(), "2026-09-27T14:00:00.000Z");
  assertEquals(new Date(window.through).toISOString(), "2026-10-04T13:00:00.000Z");
  assertEquals(agentActivityWindow("thisWeek", "Australia/Sydney", now), { from: window.through, through: now });
});

// MARK: - Who is calling

const b64 = (value: unknown) => btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const token = (claims: Record<string, unknown>) => `${b64({ alg: "HS256" })}.${b64(claims)}.signature`;
const USER = "0b8f3d0e-6f3a-4c57-9d54-2f1c8a7e5b11";

function authServer(status: number, user: unknown, seen: { url: string; authorization: string | null }[] = []): typeof fetch {
  return ((input: string | URL | Request, init?: RequestInit) => {
    seen.push({ url: String(input), authorization: new Headers(init?.headers).get("authorization") });
    return Promise.resolve(new Response(JSON.stringify(user), { status }));
  }) as typeof fetch;
}

const request = (authorization?: string) => new Request("http://localhost/functions/v1/trading-api", { method: "POST", headers: authorization ? { authorization } : {} });
const env = (fetcher: typeof fetch) => ({ url: "http://auth.test/", anonKey: "anon", fetch: fetcher });

async function refusedWith(promise: Promise<unknown>, status: number, code: string): Promise<void> {
  const error = await assertRejects(() => promise, HttpError);
  assertEquals([error.status, error.code], [status, code]);
}

Deno.test("the caller is whoever the auth server says the token belongs to", async () => {
  const seen: { url: string; authorization: string | null }[] = [];
  const mine = token({ sub: USER, role: "authenticated", aal: "aal1" });
  const caller = await authenticate(request(`Bearer ${mine}`), env(authServer(200, { id: USER, factors: [] }, seen)));
  assertEquals(caller, { userID: USER, aal: "aal1", hasVerifiedFactor: false });
  assertEquals(seen, [{ url: "http://auth.test/auth/v1/user", authorization: `Bearer ${mine}` }], "the token goes to the auth server and nowhere else");

  const strong = await authenticate(request(`Bearer ${token({ sub: USER, role: "authenticated", aal: "aal2" })}`),
    env(authServer(200, { id: USER, factors: [{ status: "unverified" }, { status: "verified" }] })));
  assertEquals(strong, { userID: USER, aal: "aal2", hasVerifiedFactor: true });
  // A factor that was started but never confirmed doesn't count as having one.
  const halfEnrolled = await authenticate(request(`Bearer ${mine}`), env(authServer(200, { id: USER, factors: [{ status: "unverified" }] })));
  assertEquals(halfEnrolled.hasVerifiedFactor, false);
});

Deno.test("no token, a bad token, the anon key and someone else's identity are all refused", async () => {
  const good = authServer(200, { id: USER, factors: [] });
  await refusedWith(authenticate(request(), env(good)), 401, "unauthenticated");
  await refusedWith(authenticate(request("Basic abc"), env(good)), 401, "unauthenticated");
  await refusedWith(authenticate(request("Bearer"), env(good)), 401, "unauthenticated");
  const mine = `Bearer ${token({ sub: USER, role: "authenticated" })}`;
  // The auth server says no (expired, signed-out, forged, deleted account).
  await refusedWith(authenticate(request(mine), env(authServer(401, {}))), 401, "unauthenticated");
  await refusedWith(authenticate(request(mine), env(authServer(403, {}))), 401, "unauthenticated");
  // The auth server can't be asked: nobody is let in on the strength of what the token claims.
  await refusedWith(authenticate(request(mine), env(authServer(500, {}))), 503, "unavailable");
  await refusedWith(authenticate(request(mine), env((() => Promise.reject(new Error("down"))) as typeof fetch)), 503, "unavailable");
  await refusedWith(authenticate(request(mine), { url: undefined, anonKey: "anon", fetch: good }), 503, "unavailable");
  await refusedWith(authenticate(request(mine), { url: "http://auth.test", anonKey: undefined, fetch: good }), 503, "unavailable");
  // The token's own claims never override the auth server's answer.
  await refusedWith(authenticate(request(`Bearer ${token({ sub: "someone-else", role: "authenticated" })}`), env(good)), 401, "unauthenticated");
  await refusedWith(authenticate(request(`Bearer ${token({ sub: USER, role: "anon" })}`), env(good)), 401, "unauthenticated");
  await refusedWith(authenticate(request(`Bearer ${token({ sub: USER, role: "service_role" })}`), env(good)), 401, "unauthenticated");
  await refusedWith(authenticate(request("Bearer not.a-jwt"), env(good)), 401, "unauthenticated");
  await refusedWith(authenticate(request(mine), env(authServer(200, null))), 401, "unauthenticated");
  await refusedWith(authenticate(request(mine), env(authServer(200, { factors: [] }))), 401, "unauthenticated");
});

Deno.test("the stronger sign-in is needed exactly when the person has an authenticator and hasn't used it", () => {
  const caller = (aal: "aal1" | "aal2", hasVerifiedFactor: boolean): Caller => ({ userID: USER, aal, hasVerifiedFactor });
  assertEquals(stepUpProblem(caller("aal1", false)), undefined);
  assertEquals(stepUpProblem(caller("aal2", false)), undefined);
  assertEquals(stepUpProblem(caller("aal2", true)), undefined);
  assert(stepUpProblem(caller("aal1", true))!.includes("authenticator"));
  requireStepUp(caller("aal2", true));
  const error = assertThrows(() => requireStepUp(caller("aal1", true)), HttpError);
  assertEquals([error.status, error.code, error.details], [403, "step_up_required", { requiredAal: "aal2" }]);
});

// MARK: - Loosening a limit

Deno.test("any limit that lets an agent do more counts as loosening; tightening never does", () => {
  const base = standardPolicy(10_000, 10);
  assertEquals(isLoosening(base, { ...base }), false);
  const higherIsLooser: (keyof RiskPolicy)[] = ["maxOrderNotional", "maxPositionPct", "maxDailyNotional", "maxDailyLossPct", "maxDrawdownPct",
    "maxOpenPositions", "maxSpreadBps", "maxQuoteAgeSeconds", "maxDailyVolatilityPct", "maxPriceGapPct"];
  for (const key of higherIsLooser) {
    assertEquals(isLoosening(base, { ...base, [key]: (base[key] as number) + 1 }), true, `${key} raised`);
    assertEquals(isLoosening(base, { ...base, [key]: (base[key] as number) - 0.5 }), false, `${key} lowered`);
  }
  assertEquals(isLoosening(base, { ...base, minAverageDollarVolume: base.minAverageDollarVolume - 1 }), true);
  assertEquals(isLoosening(base, { ...base, minAverageDollarVolume: base.minAverageDollarVolume + 1 }), false);
  assertEquals(isLoosening(base, { ...base, cooldownSeconds: base.cooldownSeconds - 1 }), true);
  assertEquals(isLoosening(base, { ...base, cooldownSeconds: base.cooldownSeconds + 60 }), false);
  assertEquals(isLoosening({ ...base, allowQueueOutsideHours: false }, { ...base, allowQueueOutsideHours: true }), true);
  assertEquals(isLoosening({ ...base, allowQueueOutsideHours: true }, { ...base, allowQueueOutsideHours: false }), false);
  // Tightening nine things doesn't pay for loosening one.
  const mixed = { ...base, maxOrderNotional: 1, maxDailyNotional: 1, maxOpenPositions: 1, maxDrawdownPct: base.maxDrawdownPct + 0.01 };
  assertEquals(isLoosening(base, mixed), true);
  // Every number in the policy is covered by the rule (a new limit can't be added and forgotten).
  const covered = new Set<string>([...higherIsLooser, "minAverageDollarVolume", "cooldownSeconds", "allowQueueOutsideHours"]);
  assertEquals(Object.keys(base).filter((key) => !covered.has(key)), []);
});

// MARK: - Secrets and logs

Deno.test("the scheduler secret is compared whole", () => {
  const secret = "c0ffee".repeat(8);
  assertEquals(sameSecret(secret, secret), true);
  assertEquals(sameSecret(secret, `${secret.slice(0, -1)}x`), false);
  assertEquals(sameSecret(secret, secret.slice(0, -1)), false);
  assertEquals(sameSecret(secret, `${secret}0`), false);
  assertEquals(sameSecret(secret, ""), false);
  assertEquals(sameSecret("", secret), false);
  assertEquals(sameSecret(secret, secret.toUpperCase()), false);
});

Deno.test("log lines carry no secrets, and errors tell the caller nothing internal", async () => {
  const lines: string[] = [];
  const original = console.log;
  console.log = (line: string) => { lines.push(line); };
  try {
    logEvent("probe", {
      action: "placeOrder", status: 200, ms: 12, authorization: "Bearer abc", token: "abc", scheduler_secret: "s3cr3t", apikey: "k", API_KEY: "k",
      password: "p", cookie: "c", alpaca_key_id: "id", jwt: "j", nested: { secret: "deep" }, list: ["a", { secret: "x" }], long: "x".repeat(1_000),
    });
  } finally {
    console.log = original;
  }
  const logged = JSON.parse(lines[0]);
  assertEquals(Object.keys(logged).sort(), ["action", "at", "event", "long", "ms", "status"]);
  assert(logged.long.length <= 301);
  for (const secret of ["Bearer abc", "s3cr3t", "deep"]) assert(!lines[0].includes(secret));

  // An unexpected failure answers with a fixed sentence: no stack, no SQL, no connection string.
  const response = errorResponse(new Error("connect ECONNREFUSED postgresql://postgres:hunter2@db:5432/postgres"));
  const body = await response.text();
  assertEquals(response.status, 500);
  assert(!body.includes("hunter2") && !body.includes("postgres") && !body.includes("ECONNREFUSED"), body);
  assertEquals(JSON.parse(body), { ok: false, error: { code: "internal", message: "Something went wrong on our side. Nothing was changed." } });

  assertEquals(tradingErrorStatus(TradingError.liveNotAvailable(["No."])), { status: 403, code: "live_not_available" });
  assertEquals(tradingErrorStatus(TradingError.invalid(["Bad."])), { status: 422, code: "invalid" });
  assertEquals(tradingErrorStatus(TradingError.notFound("That order")), { status: 404, code: "not_found" });
  assertEquals(tradingErrorStatus(TradingError.notAllowed("No.")), { status: 409, code: "not_allowed" });
});

Deno.test("request fields are checked, not coerced", () => {
  for (const bad of ["12", null, undefined, Number.NaN, Number.POSITIVE_INFINITY, {}, [], true]) assertThrows(() => Field.number(bad, "n"), HttpError);
  assertEquals(Field.number(0, "n"), 0);
  for (const bad of [1.5, "1", Number.NaN]) assertThrows(() => Field.integer(bad, "n"), HttpError);
  for (const bad of ["true", 1, null]) assertThrows(() => Field.boolean(bad, "b"), HttpError);
  for (const bad of ["", "nope", "0b8f3d0e6f3a4c579d542f1c8a7e5b11", 5, null, `${USER}; drop table orders`]) assertThrows(() => Field.uuid(bad, "id"), HttpError);
  assertEquals(Field.uuid(USER.toUpperCase(), "id"), USER);
  assertThrows(() => Field.string("x".repeat(201), "name"), HttpError);
  assertThrows(() => Field.oneOf("live!", ["paper", "live"] as const, "mode"), HttpError);
  for (const bad of [null, [], "x", 3]) assertThrows(() => Field.object(bad, "o"), HttpError);
});

// MARK: - The live seam

Deno.test("there is no live adapter: the registry is empty and frozen, and asking for one throws", () => {
  assertEquals(Object.keys(liveAdapters), []);
  assert(Object.isFrozen(liveAdapters));
  assertThrows(() => { (liveAdapters as Record<string, unknown>).alpaca = {}; }, TypeError);
  for (const id of ["alpaca", "snaptrade", "paper", ""]) assertThrows(() => liveAdapter(id), LiveTradingDisabledError);

  const paper = { id: "1", mode: "paper", status: "accepted" } as unknown as Order;
  assertEquals(reconcile([]), { reconciled: 0 });
  assertEquals(reconcile([paper, paper]), { reconciled: 0 }, "paper orders live in our own database: nothing outside to reconcile");
  const live = { id: "2", mode: "live", status: "accepted" } as unknown as Order;
  assertThrows(() => reconcile([paper, live]), LiveTradingDisabledError, "live trading is not enabled");
});

// MARK: - What the source can reach

async function sources(dir: URL, out: { path: string; text: string }[] = []): Promise<{ path: string; text: string }[]> {
  for await (const entry of Deno.readDir(dir)) {
    const url = new URL(entry.name + (entry.isDirectory ? "/" : ""), dir);
    if (entry.isDirectory) {
      if (entry.name !== "tests") await sources(url, out);
    } else if (entry.name.endsWith(".ts")) {
      out.push({ path: url.pathname.split("/supabase/functions/")[1], text: await Deno.readTextFile(url) });
    }
  }
  return out;
}

/** The code with comments removed, so a sentence about what the code doesn't do can't trip a check. */
function code(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, "").split("\n").map((line) => line.replace(/^\s*\/\/.*$/, "").replace(/\s\/\/ .*$/, "")).join("\n");
}

const PRACTICE_PATH = /^(trading-api|agent-scheduler|_shared\/(server|trading|market|studio))\//;
const EXTERNAL_PATH = /^(broker-orders|broker-connections|snaptrade-proxy|ai-proxy|market-data-proxy|_shared\/(brokers|oms|vault|snaptrade|ai|secure))\//;

Deno.test("the practice server cannot place a provider order or call a model", async () => {
  const files = (await sources(new URL("../", import.meta.url))).filter((file) => PRACTICE_PATH.test(file.path));
  const root = new URL("../", import.meta.url);
  for (const file of files) {
    for (const match of code(file.text).matchAll(/\b(?:from\s+|import\s*\(\s*|import\s+)["'](\.[^"']+)["']/g)) {
      const target = new URL(match[1], new URL(file.path, root)).pathname.slice(root.pathname.length);
      assert(!EXTERNAL_PATH.test(target), `${file.path} imports ${target}`);
    }
  }
  assert(files.length >= 30, `only ${files.length} source files found`);

  // Every address the code can call.
  const hosts = new Set<string>();
  for (const file of files) for (const match of code(file.text).matchAll(/https?:\/\/([a-zA-Z0-9.-]+)/g)) hosts.add(match[1]);
  assertEquals([...hosts].sort(), ["api.coingecko.com", "data.alpaca.markets", "query1.finance.yahoo.com"], "market data (read-only) and nothing else");

  // Network calls are made in four places only: the three market-data clients and the sign-in check.
  const callers = files.filter((file) => /\bfetch\s*\)?\s*\(|\bfetch\)\(/.test(code(file.text)) || /\?\? fetch\b/.test(code(file.text))).map((file) => file.path).sort();
  assertEquals(callers, ["_shared/market/alpaca.ts", "_shared/market/coingecko.ts", "_shared/market/yahoo.ts", "_shared/server/auth.ts"]);

  for (const file of files) {
    const text = code(file.text);
    // No broker trading API, by address or by path.
    for (const pattern of [/api\.alpaca\.markets/i, /paper-api/i, /\/v2\/orders/i, /\/v2\/positions/i, /\/v2\/account\b/i, /snaptrade/i, /\/trade\/place/i, /(binance|coinbase|kraken)\.(com|us)/i]) {
      if (file.path === "_shared/trading/broker.ts" && /snaptrade/i.test(pattern.source)) continue;     // a described, switched-off venue
      assert(!pattern.test(text), `${file.path} mentions ${pattern}`);
    }
    // No language model.
    for (const pattern of [/openai/i, /anthropic/i, /generativelanguage/i, /\bgemini\b/i, /\/v1\/(chat\/completions|messages|responses)\b/i, /\bllm\b/i]) {
      assert(!pattern.test(text), `${file.path} mentions ${pattern}`);
    }
    // No key written into the code.
    assert(!/eyJ[A-Za-z0-9_-]{20,}|sb_secret_|sk_live_|PK[A-Z0-9]{18}/.test(file.text), `${file.path} contains something key-shaped`);
    // The market-data credentials are read in one file and nowhere else.
    if (/ALPACA_DATA_(KEY_ID|SECRET)|COINGECKO_API_KEY/.test(text)) assertEquals(file.path, "_shared/market/index.ts");
    if (/TRADING_SCHEDULER_SECRET/.test(text)) assertEquals(file.path, "agent-scheduler/index.ts");
  }

  // The only non-GET request the market-data clients could make would be a trading call: there is none.
  for (const path of ["_shared/market/alpaca.ts", "_shared/market/coingecko.ts", "_shared/market/yahoo.ts"]) {
    const text = code(files.find((file) => file.path === path)!.text);
    assert(!/method:\s*["'`](POST|PUT|PATCH|DELETE)/i.test(text), `${path} sends something other than a GET`);
  }
  // The live seam has no implementation anywhere.
  const implementers = files.filter((file) => /implements\s+LiveBrokerAdapter|:\s*LiveBrokerAdapter\s*=\s*\{/.test(code(file.text))).map((file) => file.path);
  assertEquals(implementers, []);
});
