// The provider order path without a database or network: intent hashing, the state machine,
// gates, approvals, and the submit / reconcile / cancel pipeline against a fake store and a
// fake adapter. Run: npx -y deno test --allow-read supabase/functions/tests/oms.test.ts

import { assert, assertEquals, assertNotEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import type { OrderIntentInput, RiskEvaluationView } from "../_shared/oms/api.ts";
import { type ApprovalRecord, checkApprove, DEFAULT_APPROVAL_POLICY } from "../_shared/oms/approval.ts";
import * as D from "../_shared/decimal.ts";
import { cancelIntent, type ExecutionDeps, type IntentRecord, type OmsStore, RECONCILE_GIVE_UP_MS, recomputeHash, reconcileIntent, submitIntent } from "../_shared/oms/execute.ts";
import { resolveGates } from "../_shared/oms/gates.ts";
import { canonicalIntent, canonicalJSON, IntentError, intentHash, newClientOrderID, validateInput } from "../_shared/oms/intent.ts";
import { assertTransition, canTransition, nextFromBroker, TERMINAL } from "../_shared/oms/lifecycle.ts";
import type { AdapterContext, BrokerAccount, BrokerAdapter, BrokerOrder, BrokerOrderRequest, SubmitResult } from "../_shared/brokers/types.ts";
import { BrokerError } from "../_shared/brokers/types.ts";
import type { IntentStatus } from "../_shared/oms/api.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const CONN = "33333333-3333-4333-8333-333333333333";
const T0 = Date.parse("2026-11-13T15:00:00Z");

const input = (over: Partial<OrderIntentInput> = {}): OrderIntentInput => ({
  connectionID: CONN, symbol: "AAPL", assetClass: "us_equity", side: "buy", type: "limit", timeInForce: "day",
  quantity: "10", limitPrice: "190.50", origin: { kind: "manual" }, ...over,
});

// MARK: - Decimal

Deno.test("decimal: exact arithmetic on provider strings", () => {
  assertEquals(D.normalise("1.500"), "1.5");
  assertEquals(D.normalise("007.10"), "7.1");
  assertEquals(D.mul("0.1", "3"), "0.3"); // 0.1 * 3 = 0.30000000000000004 in doubles
  assertEquals(D.add("0.1", "0.2"), "0.3");
  assertEquals(D.mul("10", "190.50"), "1905");
  assertEquals(D.div("100", "3", 4), "33.3333");
  assertEquals(D.round("2.345", 2), "2.35");
  assertEquals(D.round("2.349", 2, "down"), "2.34");
  assert(D.isMultipleOf("300", "100"));
  assert(!D.isMultipleOf("150", "100"));
  assertEquals(D.compare("1.10", "1.1"), 0);
  assertThrows(() => D.parse("-1"), D.DecimalError);
  assertThrows(() => D.parse("1e5"), D.DecimalError);
  assertThrows(() => D.sub("1", "2"), D.DecimalError);
});

// MARK: - Intent

Deno.test("intent: hash is stable across formatting and changes with any material field", async () => {
  const id = "st-0123456789abcdef0123456789abcdef";
  const base = await intentHash(canonicalIntent({ userID: USER, provider: "alpaca", environment: "paper", clientOrderID: id, input: input() }));
  const reformatted = await intentHash(canonicalIntent({ userID: USER.toUpperCase(), provider: "alpaca", environment: "paper", clientOrderID: id, input: input({ quantity: "10.000", limitPrice: "190.5" }) }));
  assertEquals(base, reformatted);
  for (const change of [{ quantity: "11" }, { limitPrice: "190.51" }, { side: "sell" as const }, { symbol: "MSFT" }, { timeInForce: "gtc" as const }]) {
    const h = await intentHash(canonicalIntent({ userID: USER, provider: "alpaca", environment: "paper", clientOrderID: id, input: input(change) }));
    assertNotEquals(h, base, JSON.stringify(change));
  }
  const live = await intentHash(canonicalIntent({ userID: USER, provider: "alpaca", environment: "live", clientOrderID: id, input: input() }));
  assertNotEquals(live, base);
  assertEquals(canonicalJSON({ b: 1, a: { d: [2, 1], c: null } }), '{"a":{"c":null,"d":[2,1]},"b":1}');
  assert(/^st-[0-9a-f]{32}$/.test(newClientOrderID()));
});

Deno.test("intent: shape validation", () => {
  validateInput(input());
  validateInput(input({ type: "market", quantity: undefined, limitPrice: undefined, notional: "100" }));
  const bad: Partial<OrderIntentInput>[] = [
    { quantity: undefined },
    { notional: "100" },
    { quantity: "0" },
    { quantity: "-1" },
    { limitPrice: undefined },
    { type: "market" }, // market with a limit price
    { type: "limit", quantity: undefined, notional: "50" }, // notional only for market
    { symbol: "aapl; drop" },
    { origin: { kind: "agent", agentID: CONN, rationale: " " } },
  ];
  for (const b of bad) assertThrows(() => validateInput(input(b)), IntentError, undefined, JSON.stringify(b));
});

// MARK: - Lifecycle

Deno.test("lifecycle: the brief's path is legal, shortcuts are not", () => {
  const path: IntentStatus[] = ["draft", "risk_checked", "awaiting_approval", "approved", "submitting", "submitted", "partially_filled", "filled"];
  for (let i = 1; i < path.length; i++) assertTransition(path[i - 1], path[i]);
  assert(!canTransition("draft", "approved"));
  assert(!canTransition("risk_checked", "submitting"));
  assert(!canTransition("awaiting_approval", "submitting"));
  assert(!canTransition("reconciliation_required", "submitting"), "never resubmit after an unknown outcome");
  for (const t of TERMINAL) for (const s of path) assert(!canTransition(t, s));
  assertEquals(nextFromBroker("submitting", "accepted"), "submitted");
  assertEquals(nextFromBroker("submitted", "accepted"), undefined);
  assertEquals(nextFromBroker("partially_filled", "partially_filled"), "partially_filled");
  assertEquals(nextFromBroker("submitted", "replaced"), "reconciliation_required");
});

// MARK: - Gates

Deno.test("gates: default off; automated live needs live; custody never", () => {
  const g = resolveGates([]);
  for (const v of Object.values(g)) assert(!v.enabled);
  const g2 = resolveGates([{ id: "automated_live_execution", enabled: true, reason: "" }, { id: "custodial_features", enabled: true, reason: "" }]);
  assert(!g2.automated_live_execution.enabled);
  assert(!g2.custodial_features.enabled);
});

// MARK: - Approve

Deno.test("approve: owner only, exact hash, step-up for live and large paper, expiry", () => {
  const base = { callerID: USER, callerAAL: "aal1" as const, ownerID: USER, storedHash: "a".repeat(64), presentedHash: "a".repeat(64), environment: "paper" as const, estimatedNotional: "1905", intentExpiresAt: T0 + 60_000, now: T0 };
  assertEquals(checkApprove(base), undefined);
  assertEquals(checkApprove({ ...base, callerID: OTHER })?.code, "forbidden");
  assertEquals(checkApprove({ ...base, presentedHash: "b".repeat(64) })?.code, "intent_changed");
  assertEquals(checkApprove({ ...base, environment: "live" })?.code, "step_up_required");
  assertEquals(checkApprove({ ...base, environment: "live", callerAAL: "aal2" }), undefined);
  assertEquals(checkApprove({ ...base, estimatedNotional: DEFAULT_APPROVAL_POLICY.stepUpPaperNotional })?.code, "step_up_required");
  assertEquals(checkApprove({ ...base, now: T0 + 60_000 })?.code, "approval_expired");
});

// MARK: - Pipeline fakes

class FakeStore implements OmsStore {
  status: IntentStatus;
  approval?: ApprovalRecord;
  transitions: [IntentStatus, IntentStatus, string | undefined][] = [];
  orders: BrokerOrder[] = [];
  events: string[] = [];
  constructor(status: IntentStatus, approval?: ApprovalRecord) {
    this.status = status;
    this.approval = approval;
  }
  transition(_id: string, from: IntentStatus, to: IntentStatus, note?: string): Promise<boolean> {
    if (this.status !== from || !canTransition(from, to)) return Promise.resolve(false);
    this.transitions.push([from, to, note]);
    this.status = to;
    return Promise.resolve(true);
  }
  loadApproval() {
    return Promise.resolve(this.approval ? { ...this.approval } : undefined);
  }
  consumeApproval(_id: string, now: number) {
    if (!this.approval || this.approval.consumedAt !== undefined || now >= this.approval.expiresAt) return Promise.resolve(false);
    this.approval.consumedAt = now;
    return Promise.resolve(true);
  }
  async recordBrokerOrder(id: string, from: IntentStatus, order: BrokerOrder) {
    this.orders.push(order);
    const to = nextFromBroker(from, order.status);
    return to && await this.transition(id, from, to, `provider: ${order.providerStatus}`) ? to : from;
  }
  recordRisk() {
    return Promise.resolve();
  }
  audit(e: { kind: string }) {
    this.events.push(e.kind);
    return Promise.resolve();
  }
}

const brokerOrder = (status: BrokerOrder["status"], over: Partial<BrokerOrder> = {}): BrokerOrder => ({
  providerOrderID: "alp-1", clientOrderID: "st-0123456789abcdef0123456789abcdef", symbol: "AAPL", side: "buy", type: "limit",
  status, providerStatus: status, quantity: "10", filledQuantity: status === "filled" ? "10" : "0", ...over,
});

class FakeAdapter implements BrokerAdapter {
  readonly provider = "alpaca" as const;
  submits: { ctx: AdapterContext; req: BrokerOrderRequest }[] = [];
  submitResult: SubmitResult | Error = { outcome: "accepted", order: brokerOrder("accepted") };
  lookup: BrokerOrder | undefined;
  account: BrokerAccount = { providerAccountID: "acct-1", label: "Alpaca paper", environment: "paper", status: "active", currency: "USD", tradingEnabled: true, tradingBlockers: [] };
  cancels = 0;
  cancelAccepted = true;
  afterCancel: BrokerOrder | undefined;
  capabilities() {
    return { provider: "alpaca" as const, environment: "paper" as const, executionAvailable: true, readAccounts: true, readPositions: true, readFills: true, orders: [], streaming: { orders: false, marketData: false }, notes: [] };
  }
  validate() {
    return Promise.resolve({ accounts: [this.account], permissions: ["read" as const, "trade" as const] });
  }
  accounts() {
    return Promise.resolve([this.account]);
  }
  balances() {
    return Promise.resolve([]);
  }
  positions() {
    return Promise.resolve([]);
  }
  fills() {
    return Promise.resolve({ items: [] });
  }
  orders() {
    return Promise.resolve({ items: [] });
  }
  submit(ctx: AdapterContext, req: BrokerOrderRequest) {
    this.submits.push({ ctx, req });
    if (this.submitResult instanceof Error) return Promise.reject(this.submitResult);
    return Promise.resolve(this.submitResult);
  }
  cancel() {
    this.cancels++;
    if (this.afterCancel) this.lookup = this.afterCancel;
    return Promise.resolve({ accepted: this.cancelAccepted });
  }
  getOrder() {
    if (!this.lookup) return Promise.reject(new BrokerError("not_found", "no such order"));
    return Promise.resolve(this.lookup);
  }
  findOrderByClientID() {
    return Promise.resolve(this.lookup);
  }
}

const passRisk = (observedAt = new Date(T0 - 5_000).toISOString()): RiskEvaluationView => ({
  policyVersion: 3, result: "pass", reasonCodes: [], checks: [], price: { value: "190.40", currency: "USD", source: "alpaca-iex", observedAt, status: "real_time" }, evaluatedAt: new Date(T0).toISOString(),
});

async function setup(over: { status?: IntentStatus; environment?: "paper" | "live"; approval?: Partial<ApprovalRecord> | null; gates?: string[]; kill?: boolean; risk?: RiskEvaluationView; permissions?: ("read" | "trade")[] } = {}) {
  const environment = over.environment ?? "paper";
  const intent: IntentRecord = {
    id: "44444444-4444-4444-8444-444444444444", userID: USER, provider: "alpaca", environment, input: input(),
    clientOrderID: "st-0123456789abcdef0123456789abcdef", intentHash: "", status: over.status ?? "approved",
    createdAt: T0 - 60_000, expiresAt: T0 + 600_000, estimatedNotional: "1905",
  };
  intent.intentHash = await recomputeHash(intent);
  const approval: ApprovalRecord | undefined = over.approval === null ? undefined : {
    intentID: intent.id, approverID: USER, approvedIntentHash: intent.intentHash, aal: "aal1", approvedAt: T0 - 30_000, expiresAt: T0 + 90_000, ...over.approval,
  };
  const store = new FakeStore(intent.status, approval);
  const adapter = new FakeAdapter();
  const deps: ExecutionDeps = {
    store,
    gates: resolveGates((over.gates ?? ["provider_paper_execution"]).map((id) => ({ id: id as never, enabled: true, reason: "test" }))),
    killSwitchEngaged: over.kill ?? false,
    connection: { id: CONN, userID: USER, provider: "alpaca", environment, status: "active", permissions: over.permissions ?? ["read", "trade"], providerAccountID: "acct-1" },
    adapter,
    adapterContext: { environment, credentials: { provider: "alpaca", keyID: "k", secretKey: "s" } },
    evaluateRisk: () => Promise.resolve(over.risk ?? passRisk()),
    maxQuoteAgeMs: 60_000,
    now: () => T0,
  };
  return { intent, store, adapter, deps };
}

const caller = { userID: USER, aal: "aal1" as const };

// MARK: - Submit

Deno.test("submit: happy path sends once with our client order id and follows the provider", async () => {
  const { intent, store, adapter, deps } = await setup();
  adapter.submitResult = { outcome: "accepted", order: brokerOrder("filled", { averageFillPrice: "190.45" }) };
  const out = await submitIntent(deps, intent, caller);
  assert(out.ok, JSON.stringify(out));
  assertEquals(out.status, "filled");
  assertEquals(adapter.submits.length, 1);
  assertEquals(adapter.submits[0].req.clientOrderID, intent.clientOrderID);
  assertEquals(adapter.submits[0].ctx.allowLive, false);
  assertEquals(store.transitions.map(([f, t]) => `${f}>${t}`), ["approved>submitting", "submitting>filled"]);
  assert(store.approval?.consumedAt !== undefined);
});

Deno.test("submit: a second submit (double click / retry) can't send twice", async () => {
  const { intent, adapter, deps } = await setup();
  const first = await submitIntent(deps, intent, caller);
  assert(first.ok);
  const again = await submitIntent(deps, { ...intent, status: "approved" }, caller); // stale client view
  assert(!again.ok);
  assertEquals(adapter.submits.length, 1);
});

Deno.test("submit: concurrent submits — one wins, the approval is single use", async () => {
  const { intent, adapter, deps } = await setup();
  const [a, b] = await Promise.all([submitIntent(deps, intent, caller), submitIntent(deps, intent, caller)]);
  assertEquals([a.ok, b.ok].filter(Boolean).length, 1);
  assertEquals(adapter.submits.length, 1);
});

Deno.test("submit: refusals happen before any provider call", async () => {
  const cases: [string, Parameters<typeof setup>[0], string][] = [
    ["gate off", { gates: [] }, "feature_disabled"],
    ["kill switch", { kill: true }, "kill_switch_engaged"],
    ["read-only connection", { permissions: ["read"] }, "forbidden"],
    ["no approval", { approval: null }, "approval_invalid"],
    ["used approval", { approval: { consumedAt: T0 - 1 } }, "approval_used"],
    ["expired approval", { approval: { expiresAt: T0 } }, "approval_expired"],
    ["approval for another order", { approval: { approvedIntentHash: "f".repeat(64) } }, "intent_changed"],
    ["approved by someone else", { approval: { approverID: OTHER } }, "approval_invalid"],
    ["live without the live gate", { environment: "live", gates: ["provider_paper_execution"] }, "feature_disabled"],
    ["live without aal2", { environment: "live", gates: ["live_execution"], approval: { aal: "aal1" } }, "step_up_required"],
    ["not approved yet", { status: "awaiting_approval" }, "conflict"],
    ["stale price", { risk: passRisk(new Date(T0 - 120_000).toISOString()) }, "stale_price"],
  ];
  for (const [name, over, code] of cases) {
    const { intent, adapter, deps } = await setup(over);
    const out = await submitIntent(deps, intent, caller);
    assert(!out.ok, name);
    assertEquals(out.code, code, name);
    assertEquals(adapter.submits.length, 0, name);
  }
});

Deno.test("submit: another user can't submit, even with the intent id", async () => {
  const { intent, adapter, deps } = await setup();
  const out = await submitIntent(deps, intent, { userID: OTHER, aal: "aal2" });
  assert(!out.ok);
  assertEquals(out.code, "forbidden");
  assertEquals(adapter.submits.length, 0);
});

Deno.test("submit: risk re-run at submission rejects and records it", async () => {
  const { intent, store, adapter, deps } = await setup({ risk: { ...passRisk(), result: "fail", reasonCodes: ["positionLimit"] } });
  const out = await submitIntent(deps, intent, caller);
  assert(!out.ok);
  assertEquals(out.code, "risk_rejected");
  assertEquals(out.details?.reasonCodes, ["positionLimit"]);
  assertEquals(store.status, "rejected");
  assertEquals(adapter.submits.length, 0);
});

Deno.test("submit: provider account blocked → nothing sent", async () => {
  const { intent, adapter, deps } = await setup();
  adapter.account = { ...adapter.account, tradingEnabled: false, tradingBlockers: ["account_blocked"] };
  const out = await submitIntent(deps, intent, caller);
  assert(!out.ok);
  assertEquals(adapter.submits.length, 0);
});

Deno.test("submit: timeout after the provider accepted → reconcile finds it, no second order", async () => {
  const { intent, store, adapter, deps } = await setup();
  adapter.submitResult = { outcome: "unknown", reason: "timeout" };
  adapter.lookup = brokerOrder("accepted");
  const out = await submitIntent(deps, intent, caller);
  assert(out.ok, JSON.stringify(out));
  assertEquals(out.status, "submitted");
  assertEquals(adapter.submits.length, 1);
  assertEquals(store.transitions.map(([f, t]) => `${f}>${t}`), ["approved>submitting", "submitting>reconciliation_required", "reconciliation_required>submitted"]);
});

Deno.test("submit: unknown outcome the provider hasn't seen stays in reconciliation and refuses resubmission", async () => {
  const { intent, store, adapter, deps } = await setup();
  adapter.submitResult = { outcome: "unknown", reason: "connection reset" };
  const out = await submitIntent(deps, intent, caller);
  assert(!out.ok);
  assertEquals(out.code, "reconciliation_required");
  assertEquals(store.status, "reconciliation_required");
  const retry = await submitIntent(deps, { ...intent, status: "reconciliation_required" }, caller);
  assert(!retry.ok);
  assertEquals(retry.code, "reconciliation_required");
  assertEquals(adapter.submits.length, 1);
  // After the grace period with still no provider record, it's failed (safe to draft again).
  const later = { ...deps, now: () => T0 + RECONCILE_GIVE_UP_MS };
  const settled = await reconcileIntent(later, { ...intent, status: "reconciliation_required", reconcilingSince: T0 });
  assert(settled.ok);
  assertEquals(settled.status, "failed");
});

Deno.test("submit: an unexpected adapter exception is treated as unknown, not as 'not sent'", async () => {
  const { intent, store, adapter, deps } = await setup();
  adapter.submitResult = new TypeError("socket hang up");
  const out = await submitIntent(deps, intent, caller);
  assert(!out.ok);
  assertEquals(store.status, "reconciliation_required");
});

Deno.test("submit: provider rejection and adapter environment refusal", async () => {
  {
    const { intent, store, adapter, deps } = await setup();
    adapter.submitResult = { outcome: "rejected", code: "insufficient_buying_power", message: "insufficient buying power" };
    const out = await submitIntent(deps, intent, caller);
    assert(!out.ok);
    assertEquals(store.status, "rejected");
  }
  {
    const { intent, store, adapter, deps } = await setup();
    adapter.submitResult = new BrokerError("environment_refused", "live refused");
    const out = await submitIntent(deps, intent, caller);
    assert(!out.ok);
    assertEquals(out.code, "feature_disabled");
    assertEquals(store.status, "failed");
  }
});

// MARK: - Partial fills and cancel

Deno.test("reconcile: partial fill then fill", async () => {
  const { intent, store, adapter, deps } = await setup({ status: "submitted" });
  const at = { ...intent, status: "submitted" as const, providerOrderID: "alp-1" };
  adapter.lookup = brokerOrder("partially_filled", { filledQuantity: "4" });
  assertEquals((await reconcileIntent(deps, at)).status, "partially_filled");
  adapter.lookup = brokerOrder("partially_filled", { filledQuantity: "7" });
  assertEquals((await reconcileIntent(deps, { ...at, status: "partially_filled" })).status, "partially_filled");
  adapter.lookup = brokerOrder("filled");
  assertEquals((await reconcileIntent(deps, { ...at, status: "partially_filled" })).status, "filled");
  assertEquals(store.orders.map((o) => o.filledQuantity), ["4", "7", "10"]);
});

Deno.test("reconcile: a stranded submission gets its own grace period", async () => {
  const { intent, deps, store, adapter } = await setup({ status: "submitting" });
  const submitting = { ...intent, submittingAt: T0 - 15_000 };
  assertEquals((await reconcileIntent(deps, submitting)).status, "submitting");
  assertEquals((await reconcileIntent({ ...deps, now: () => T0 + 120_000 }, submitting)).status, "reconciliation_required");
  assertEquals(store.status, "reconciliation_required");
  assertEquals(adapter.submits.length, 0);
  assertEquals(adapter.cancels, 0);
});

Deno.test("reconcile: missing known orders and bounded lookups remain unresolved", async () => {
  const { intent, deps, adapter } = await setup({ status: "reconciliation_required" });
  const later = { ...deps, now: () => T0 + RECONCILE_GIVE_UP_MS };
  const pending = { ...intent, reconcilingSince: T0 };
  assertEquals((await reconcileIntent(later, { ...pending, providerOrderID: "known-id" })).status, "reconciliation_required");
  assertEquals((await reconcileIntent(later, { ...pending, provider: "coinbase" })).status, "reconciliation_required");
  assertEquals(adapter.submits.length, 0);
});

Deno.test("cancel: before submission is local; after, only the provider's word cancels it", async () => {
  {
    const { intent, adapter, deps } = await setup({ status: "awaiting_approval" });
    const out = await cancelIntent(deps, { ...intent, status: "awaiting_approval" }, caller);
    assertEquals(out.status, "cancelled");
    assertEquals(adapter.cancels, 0);
  }
  {
    const { intent, adapter, deps } = await setup({ status: "submitted" });
    adapter.lookup = brokerOrder("pending_cancel");
    const out = await cancelIntent(deps, { ...intent, status: "submitted", providerOrderID: "alp-1" }, caller);
    assertEquals(adapter.cancels, 1);
    assertEquals(out.status, "submitted", "a cancel request isn't a cancellation");
  }
  {
    const { intent, adapter, deps } = await setup({ status: "submitted" });
    adapter.afterCancel = brokerOrder("canceled");
    const out = await cancelIntent(deps, { ...intent, status: "submitted", providerOrderID: "alp-1" }, caller);
    assertEquals(out.status, "cancelled");
  }
  {
    const { intent, adapter, deps } = await setup({ status: "submitted" });
    adapter.cancelAccepted = false;
    adapter.lookup = brokerOrder("filled");
    const out = await cancelIntent(deps, { ...intent, status: "submitted", providerOrderID: "alp-1" }, caller);
    assert(!out.ok);
    assertEquals(out.code, "provider_error");
    assertEquals(out.status, "filled", "a refused cancellation should still refresh the broker status");
  }
  {
    const { intent, deps } = await setup({ status: "submitted" });
    await assertRejects(async () => {
      const out = await cancelIntent(deps, { ...intent, status: "submitted", providerOrderID: "alp-1" }, { userID: OTHER, aal: "aal2" });
      if (!out.ok) throw new Error(out.code);
    }, Error, "forbidden");
  }
});

Deno.test("submit: under the lock, two orders that only pass alone can't both go through", async () => {
  // Shared exposure: risk fails once another order is reserving (submitting).
  let reserving = 0;
  // A rendezvous makes the race deterministic: each risk check waits (up to 50 ms) for the
  // other one to arrive, as two real requests in flight would.
  let arrived = 0;
  let release: () => void = () => {};
  let bothIn = new Promise<void>((r) => (release = r));
  const rendezvous = async () => {
    if (++arrived >= 2) release();
    await Promise.race([bothIn, new Promise((r) => setTimeout(r, 50))]);
  };
  const resetRendezvous = () => {
    arrived = 0;
    bothIn = new Promise<void>((r) => (release = r));
  };
  let chain: Promise<unknown> = Promise.resolve();
  const mutex = <T>(fn: () => Promise<T>): Promise<T> => {
    const run = chain.then(fn);
    chain = run.catch(() => undefined);
    return run;
  };
  const make = async (useLock: boolean) => {
    const a = await setup();
    const b = await setup();
    for (const x of [a, b]) {
      const transition = x.store.transition.bind(x.store);
      x.store.transition = async (id, from, to, note) => {
        const moved = await transition(id, from, to, note);
        if (moved && to === "submitting") reserving++;
        return moved;
      };
      x.deps.evaluateRisk = async () => {
        await rendezvous(); // a real risk check awaits a quote
        return reserving > 0 ? { ...passRisk(), result: "fail", reasonCodes: ["dailyNotional"] } : passRisk();
      };
      if (useLock) x.deps.serialize = mutex;
    }
    return [a, b] as const;
  };
  {
    reserving = 0;
    resetRendezvous();
    const [a, b] = await make(false);
    const outs = await Promise.all([submitIntent(a.deps, a.intent, caller), submitIntent(b.deps, b.intent, caller)]);
    assertEquals(outs.filter((o) => o.ok).length, 2, "without the lock both slip through (this is the race)");
  }
  {
    reserving = 0;
    resetRendezvous();
    const [a, b] = await make(true);
    const outs = await Promise.all([submitIntent(a.deps, a.intent, caller), submitIntent(b.deps, b.intent, caller)]);
    assertEquals(outs.filter((o) => o.ok).length, 1);
    assertEquals(outs.find((o) => !o.ok && o.code === "risk_rejected") !== undefined, true);
  }
});
