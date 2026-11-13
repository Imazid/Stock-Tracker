// The real Postgres store under the real pipeline (fake provider). Proves the SQL the
// pipeline relies on: compare-and-set transitions, the database state machine, single-use
// approvals under concurrency, broker-order upserts, the transition log and OMS events.
//
// Needs a THROWAWAY database with the migrations applied (never the shared local stack):
//   OMS_TEST_DB_URL=postgres://postgres:postgres@127.0.0.1:58399/omstest \
//   npx -y deno test --allow-net --allow-env --allow-read supabase/functions/tests/oms_pg.integration.test.ts
// Skips itself when OMS_TEST_DB_URL is unset.

import { assert, assertEquals } from "jsr:@std/assert@1";
import postgres from "npm:postgres@3.4.5";
import type { AdapterContext, BrokerAdapter, BrokerOrder, BrokerOrderRequest, SubmitResult } from "../_shared/brokers/types.ts";
import type { OrderIntentInput, RiskEvaluationView } from "../_shared/oms/api.ts";
import { type ExecutionDeps, reconcileIntent, submitIntent } from "../_shared/oms/execute.ts";
import { resolveGates } from "../_shared/oms/gates.ts";
import { canonicalIntent, intentHash, newClientOrderID } from "../_shared/oms/intent.ts";
import { insertIntent, intentView, loadIntent, PgOmsStore, serializeFor, type Sql } from "../_shared/oms/store_pg.ts";

const URL = Deno.env.get("OMS_TEST_DB_URL");
const USER = crypto.randomUUID();
const CONN = crypto.randomUUID();

const input: OrderIntentInput = { connectionID: CONN, symbol: "AAPL", assetClass: "us_equity", side: "buy", type: "limit", timeInForce: "day", quantity: "10", limitPrice: "190.5", origin: { kind: "manual" } };

class FakeAdapter implements BrokerAdapter {
  readonly provider = "alpaca" as const;
  submits = 0;
  result: SubmitResult = { outcome: "accepted", order: this.order("filled") };
  lookup?: BrokerOrder;
  order(status: BrokerOrder["status"]): BrokerOrder {
    return { providerOrderID: `alp-${crypto.randomUUID()}`, symbol: "AAPL", side: "buy", type: "limit", status, providerStatus: status, quantity: "10", filledQuantity: status === "filled" ? "10" : "0", averageFillPrice: status === "filled" ? "190.42" : undefined };
  }
  capabilities() {
    return { provider: "alpaca" as const, environment: "paper" as const, executionAvailable: true, readAccounts: true, readPositions: true, readFills: true, orders: [], streaming: { orders: false, marketData: false }, notes: [] };
  }
  validate() {
    return Promise.resolve({ accounts: [], permissions: ["read" as const] });
  }
  accounts() {
    return Promise.resolve([{ providerAccountID: "acct-1", label: "paper", environment: "paper" as const, status: "active" as const, currency: "USD", tradingEnabled: true, tradingBlockers: [] }]);
  }
  balances() { return Promise.resolve([]); }
  positions() { return Promise.resolve([]); }
  fills() { return Promise.resolve({ items: [] }); }
  orders() { return Promise.resolve({ items: [] }); }
  async submit(_ctx: AdapterContext, req: BrokerOrderRequest) {
    this.submits++;
    await new Promise((r) => setTimeout(r, 20)); // a real network call takes time
    return this.result.outcome === "accepted" ? { ...this.result, order: { ...this.result.order, clientOrderID: req.clientOrderID } } : this.result;
  }
  cancel() { return Promise.resolve({ accepted: true }); }
  getOrder() { return Promise.resolve(this.lookup!); }
  findOrderByClientID() { return Promise.resolve(this.lookup); }
}

const pass = (): RiskEvaluationView => ({ policyVersion: 1, result: "pass", reasonCodes: [], checks: [], price: { value: "190.4", currency: "USD", source: "test", observedAt: new Date().toISOString(), status: "real_time" }, evaluatedAt: new Date().toISOString() });

async function approvedIntent(sql: Sql) {
  const clientOrderID = newClientOrderID();
  const hash = await intentHash(canonicalIntent({ userID: USER, provider: "alpaca", environment: "paper", clientOrderID, input }));
  const intent = await insertIntent(sql, { userID: USER, provider: "alpaca", environment: "paper", input, clientOrderID, intentHash: hash, estimate: { notional: "1905", currency: "USD" }, expiresAt: Date.now() + 600_000 });
  const store = new PgOmsStore(sql, USER);
  assert(await store.transition(intent.id, "draft", "risk_checked"));
  assert(await store.transition(intent.id, "risk_checked", "awaiting_approval"));
  await sql`insert into public.order_approvals (intent_id, approver_id, approved_intent_hash, aal, expires_at) values (${intent.id}, ${USER}, ${hash}, 'aal1', now() + interval '2 minutes')`;
  assert(await store.transition(intent.id, "awaiting_approval", "approved"));
  return (await loadIntent(sql, USER, intent.id))!;
}

function deps(sql: Sql, adapter: FakeAdapter): ExecutionDeps {
  return {
    store: new PgOmsStore(sql, USER),
    gates: resolveGates([{ id: "provider_paper_execution", enabled: true, reason: "test" }]),
    killSwitchEngaged: false,
    connection: { id: CONN, userID: USER, provider: "alpaca", environment: "paper", status: "active", permissions: ["read", "trade"], providerAccountID: "acct-1" },
    adapter,
    adapterContext: { environment: "paper", credentials: { provider: "alpaca", keyID: "k", secretKey: "s" } },
    evaluateRisk: () => Promise.resolve(pass()),
    maxQuoteAgeMs: 60_000,
    serialize: (fn) => serializeFor(sql, USER, fn),
    now: () => Date.now(),
  };
}

Deno.test({ name: "pg: approved → submitting → filled, recorded end to end", ignore: !URL, sanitizeResources: false, sanitizeOps: false }, async () => {
  const sql = postgres(URL!, { max: 6, prepare: false, onnotice: () => {} });
  try {
    await sql`insert into auth.users (id) values (${USER}) on conflict do nothing`;
    await sql`insert into public.broker_connections (id, user_id, adapter_id, name, environment, permissions, provider_account_id, key_hint)
              values (${CONN}, ${USER}, 'alpaca', 'Alpaca paper', 'paper', array['read','trade'], 'acct-1', '…TEST') on conflict do nothing`;
    const intent = await approvedIntent(sql);
    const adapter = new FakeAdapter();
    const out = await submitIntent(deps(sql, adapter), intent, { userID: USER, aal: "aal1" });
    assert(out.ok, JSON.stringify(out));
    assertEquals(out.status, "filled");
    const view = await intentView(sql, (await loadIntent(sql, USER, intent.id))!);
    assertEquals(view.status, "filled");
    assertEquals(view.transitions.map((t) => t.to), ["draft", "risk_checked", "awaiting_approval", "approved", "submitting", "filled"]);
    assert(view.approval?.consumedAt, "approval consumed");
    assertEquals(view.brokerOrder?.filledQuantity, "10");
    assertEquals(view.brokerOrder?.averageFillPrice, "190.42");
    const events = await sql`select kind from public.oms_events where intent_id = ${intent.id} order by id`;
    assertEquals(events.map((e) => e.kind), ["oms.submitting", "oms.submitted"]);
  } finally {
    await sql.end();
  }
});

Deno.test({ name: "pg: five concurrent submits of one intent → one provider call", ignore: !URL, sanitizeResources: false, sanitizeOps: false }, async () => {
  const sql = postgres(URL!, { max: 12, prepare: false, onnotice: () => {} });
  try {
    const intent = await approvedIntent(sql);
    const adapter = new FakeAdapter();
    const d = deps(sql, adapter);
    const outs = await Promise.all(Array.from({ length: 5 }, () => submitIntent(d, intent, { userID: USER, aal: "aal1" })));
    assertEquals(adapter.submits, 1);
    assertEquals(outs.filter((o) => o.ok).length, 1);
    const [row] = await sql`select count(*)::int as n from public.order_intent_transitions where intent_id = ${intent.id} and to_status = 'submitting'`;
    assertEquals(row.n, 1);
  } finally {
    await sql.end();
  }
});

Deno.test({ name: "pg: unknown outcome is stored as reconciliation_required and never resent", ignore: !URL, sanitizeResources: false, sanitizeOps: false }, async () => {
  const sql = postgres(URL!, { max: 6, prepare: false, onnotice: () => {} });
  try {
    const intent = await approvedIntent(sql);
    const adapter = new FakeAdapter();
    adapter.result = { outcome: "unknown", reason: "timeout" };
    const d = deps(sql, adapter);
    const out = await submitIntent(d, intent, { userID: USER, aal: "aal1" });
    assert(!out.ok);
    assertEquals(out.code, "reconciliation_required");
    const stored = (await loadIntent(sql, USER, intent.id))!;
    assertEquals(stored.status, "reconciliation_required");
    assert(stored.reconcilingSince, "the database stamps when reconciliation started");
    const again = await submitIntent(d, stored, { userID: USER, aal: "aal1" });
    assert(!again.ok);
    assertEquals(adapter.submits, 1);
    // The provider turns out to have it.
    adapter.lookup = { ...adapter.order("accepted"), clientOrderID: stored.clientOrderID };
    const settled = await reconcileIntent(d, stored);
    assertEquals(settled.status, "submitted");
    assertEquals((await loadIntent(sql, USER, intent.id))!.providerOrderID, adapter.lookup.providerOrderID);
  } finally {
    await sql.end();
  }
});
