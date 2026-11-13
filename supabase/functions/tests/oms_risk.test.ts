// Provider-order risk: the shared engine on a provider-built ledger plus account limits.
// Run: npx -y deno test --allow-read supabase/functions/tests/oms_risk.test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import type { ProviderCapabilities } from "../_shared/brokers/types.ts";
import type { ConnectionState, IntentRecord } from "../_shared/oms/execute.ts";
import { DEFAULT_ACCOUNT_LIMITS, evaluateProviderRisk, orderQuantity, type ProviderRiskInput, worstPrice } from "../_shared/oms/risk.ts";
import { defaultAccountPolicy, standardPolicy } from "../_shared/trading/risk.ts";
import type { Bar } from "../_shared/trading/market.ts";

const T0 = Date.parse("2026-11-13T15:00:00Z"); // Friday 10:00 New York — market open
const CONN = "33333333-3333-4333-8333-333333333333";
const USER = "11111111-1111-4111-8111-111111111111";

const caps: ProviderCapabilities = {
  provider: "alpaca", environment: "paper", executionAvailable: true, readAccounts: true, readPositions: true, readFills: true,
  orders: [
    { assetClass: "us_equity", orderTypes: ["market", "limit", "stop", "stop_limit"], timeInForce: { market: ["day", "gtc", "ioc", "fok"], limit: ["day", "gtc", "ioc", "fok"], stop: ["day", "gtc"], stop_limit: ["day", "gtc"] }, fractional: true, notional: true, replace: true, preview: false, shortSelling: false, margin: false },
    { assetClass: "crypto", orderTypes: ["market", "limit", "stop_limit"], timeInForce: { market: ["gtc", "ioc"], limit: ["gtc", "ioc"], stop_limit: ["gtc"] }, fractional: true, notional: true, replace: true, preview: false, shortSelling: false, margin: false },
  ],
  streaming: { orders: false, marketData: false }, notes: [],
};

function bars(close: number): Bar[] {
  const out: Bar[] = [];
  for (let i = 30; i >= 1; i--) {
    const c = close * (1 + (i % 2 === 0 ? 0.004 : -0.004));
    out.push({ time: T0 - i * 86_400_000, open: c, high: c * 1.01, low: c * 0.99, close: c, volume: 20_000_000 });
  }
  return out;
}

function intent(over: Partial<IntentRecord["input"]> = {}, env: "paper" | "live" = "paper"): IntentRecord {
  return {
    id: "44444444-4444-4444-8444-444444444444", userID: USER, provider: "alpaca", environment: env,
    input: { connectionID: CONN, symbol: "AAPL", assetClass: "us_equity", side: "buy", type: "limit", timeInForce: "day", quantity: "10", limitPrice: "190", origin: { kind: "manual" }, ...over },
    clientOrderID: "st-0123456789abcdef0123456789abcdef", intentHash: "x", status: "draft", createdAt: T0, expiresAt: T0 + 60_000,
  };
}

function base(over: Partial<ProviderRiskInput> = {}): ProviderRiskInput {
  const connection: ConnectionState = { id: CONN, userID: USER, provider: "alpaca", environment: "paper", status: "active", permissions: ["read", "trade"] };
  return {
    intent: intent(),
    connection,
    capabilities: caps,
    policy: { version: 2, limits: standardPolicy(100_000, 20), account: DEFAULT_ACCOUNT_LIMITS },
    accountPolicy: defaultAccountPolicy(),
    snapshot: {
      currency: "USD", cash: "100000", equity: "100000", lastEquity: "100000", realizedToday: "0",
      positions: [{ providerAccountID: "a", symbol: "MSFT", assetClass: "us_equity", quantity: "5", averageEntryPrice: "400", costBasis: "2000", marketValue: "2100", currency: "USD" }],
      fillsToday: [],
    },
    reserving: [],
    knownClientOrderIDs: new Set(),
    quote: { last: "190.10", bid: "190.05", ask: "190.15", observedAt: T0 - 5_000, source: "alpaca-iex", delaySeconds: 0, status: "real_time", currency: "USD" },
    dailyBars: bars(190),
    now: T0,
    ...over,
  };
}

const failed = (v: ReturnType<typeof evaluateProviderRisk>) => v.reasonCodes;

Deno.test("risk: a sensible paper limit buy passes on the shared engine", () => {
  const v = evaluateProviderRisk(base());
  assertEquals(failed(v), [], JSON.stringify(v.checks.filter((c) => c.status === "failed")));
  assertEquals(v.result, "pass");
  assertEquals(v.policyVersion, 2);
  assertEquals(v.price.value, "190"); // a buy limit below the ask is the worst price
  assert(v.checks.some((c) => c.id === "killSwitch") && v.checks.some((c) => c.id === "restrictedAsset"));
});

Deno.test("risk: worst price and notional sizing", () => {
  const q = base().quote!;
  assertEquals(worstPrice(intent({ type: "market", limitPrice: undefined }), q), "190.15");
  assertEquals(worstPrice(intent({ type: "market", limitPrice: undefined, side: "sell" }), q), "190.05");
  assertEquals(worstPrice(intent({ limitPrice: "195" }), q), "190.15"); // marketable limit trades at the ask at worst
  assertEquals(orderQuantity(intent({ type: "market", limitPrice: undefined, quantity: undefined, notional: "100" }), "190.15"), "0.5259006");
});

Deno.test("risk: refusals", () => {
  const cases: [string, Partial<ProviderRiskInput>, string][] = [
    ["live is refused by the engine's authorization check", { intent: intent({}, "live") }, "authorization"],
    ["read-only connection", { connection: { ...base().connection, permissions: ["read"] } }, "brokerPermission"],
    ["no quote", { quote: undefined }, "marketData"],
    ["stale quote", { quote: { ...base().quote!, observedAt: T0 - 3_600_000 } }, "quoteFreshness"],
    ["kill switch", { accountPolicy: { ...defaultAccountPolicy(), killSwitchEngaged: true }, intent: intent({ }, "paper") }, "killSwitch"],
    ["restricted symbol", { policy: { ...base().policy, account: { ...DEFAULT_ACCOUNT_LIMITS, restrictedSymbols: ["AAPL"] } } }, "restrictedAsset"],
    ["fat-finger limit", { intent: intent({ limitPrice: "19" }) }, "priceDeviation"],
    ["too big for cash", { intent: intent({ quantity: "1000" }) }, "buyingPower"],
    ["cash reserve", { policy: { ...base().policy, account: { ...DEFAULT_ACCOUNT_LIMITS, minCashReserve: "99000" } } }, "cashReserve"],
    ["selling what isn't held", { intent: intent({ side: "sell", symbol: "TSLA" }) }, "holdings"],
    ["market closed (Saturday)", { now: Date.parse("2026-11-14T15:00:00Z"), quote: { ...base().quote!, observedAt: Date.parse("2026-11-14T14:59:55Z") }, intent: intent({ timeInForce: "ioc" }) }, "marketHours"],
  ];
  for (const [name, over, code] of cases) {
    const v = evaluateProviderRisk(base(over));
    assert(v.reasonCodes.includes(code), `${name}: expected ${code}, got ${JSON.stringify(v.reasonCodes)}`);
    assertEquals(v.result, "fail", name);
  }
});

Deno.test("risk: kill switch stops agent orders too", () => {
  const v = evaluateProviderRisk(base({ accountPolicy: { ...defaultAccountPolicy(), killSwitchEngaged: true }, intent: intent({ origin: { kind: "agent", agentID: "55555555-5555-4555-8555-555555555555", rationale: "trend" } }) }));
  assert(v.reasonCodes.includes("killSwitch"));
});

Deno.test("risk: crypto allocation cap", () => {
  const crypto = intent({ symbol: "BTC/USD", assetClass: "crypto", type: "market", limitPrice: undefined, timeInForce: "gtc", quantity: undefined, notional: "40000" });
  const v = evaluateProviderRisk(base({ intent: crypto, quote: { ...base().quote!, last: "90000", bid: "89990", ask: "90010" }, dailyBars: bars(90000), policy: { ...base().policy, limits: standardPolicy(100_000, 50, true) } }));
  assert(v.reasonCodes.includes("cryptoAllocation"), JSON.stringify(v.reasonCodes));
});

Deno.test("risk: orders still reserving count against cash and today's limit", () => {
  // Alone this order is fine; with an approved-but-unsent 99k buy it can't be paid for.
  const v = evaluateProviderRisk(base({ reserving: [{ intentID: "other", symbol: "MSFT", assetClass: "us_equity", side: "buy", quantity: "240", price: "412.5" }] }));
  assert(v.reasonCodes.includes("buyingPower") || v.reasonCodes.includes("dailyNotional"), JSON.stringify(v.reasonCodes));
  // A reserving sell reduces what can be sold again.
  const sell = evaluateProviderRisk(base({ intent: intent({ side: "sell", symbol: "MSFT", limitPrice: "420", quantity: "5" }), quote: { ...base().quote!, last: "420", bid: "419.9", ask: "420.1" }, reserving: [{ intentID: "other", symbol: "MSFT", assetClass: "us_equity", side: "sell", quantity: "3", price: "420" }] }));
  assert(sell.reasonCodes.includes("holdings"), JSON.stringify(sell.reasonCodes));
});

Deno.test("risk: duplicate client order id", () => {
  const v = evaluateProviderRisk(base({ knownClientOrderIDs: new Set(["st-0123456789abcdef0123456789abcdef"]) }));
  assert(v.reasonCodes.includes("duplicate"), JSON.stringify(v.reasonCodes));
});

Deno.test("risk: identical inputs, identical verdict", () => {
  assertEquals(JSON.stringify(evaluateProviderRisk(base())), JSON.stringify(evaluateProviderRisk(base())));
});
