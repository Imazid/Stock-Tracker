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
import { listenToAlpacaPaperOrders } from "../_shared/brokers/alpaca-paper-stream.ts";
import type { AdapterContext, BrokerAdapter, BrokerFill, BrokerOrder, BrokerOrderRequest, SubmitResult } from "../_shared/brokers/types.ts";
import type { OrderIntentInput, RiskEvaluationView } from "../_shared/oms/api.ts";
import { type ExecutionDeps, reconcileIntent, submitIntent } from "../_shared/oms/execute.ts";
import { syncProviderFills } from "../_shared/oms/fill_sync.ts";
import { resolveGates } from "../_shared/oms/gates.ts";
import { canonicalIntent, intentHash, newClientOrderID } from "../_shared/oms/intent.ts";
import { insertIntent, intentView, loadIntent, PgOmsStore, serializeFor, type Sql } from "../_shared/oms/store_pg.ts";
import { keyRingFromRaw, seal } from "../_shared/vault/envelope.ts";
import { confirmAlpacaOrder, leaseAlpacaConnections, streamAlpacaOrders } from "../provider-maintenance/alpaca-stream.ts";
import { providerMaintenance } from "../provider-maintenance/worker.ts";

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
    const events = await sql`select kind, detail from public.oms_events where intent_id = ${intent.id} order by id`;
    assertEquals(events.map((e) => e.kind), ["oms.submitting", "oms.submitted"]);
    assert(Number.isInteger(events[1].detail.submitLatencyMs) && events[1].detail.submitLatencyMs >= 0);
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

Deno.test({ name: "pg: overlapping provider responses cannot roll back a fill", ignore: !URL, sanitizeResources: false, sanitizeOps: false }, async () => {
  const sql = postgres(URL!, { max: 6, prepare: false, onnotice: () => {} });
  try {
    const intent = await approvedIntent(sql);
    const adapter = new FakeAdapter();
    const first = { ...adapter.order("accepted"), updatedAt: "2026-11-13T10:00:00Z" };
    adapter.result = { outcome: "accepted", order: first };
    const d = deps(sql, adapter);
    assertEquals((await submitIntent(d, intent, { userID: USER, aal: "aal1" })).status, "submitted");
    const submitted = (await loadIntent(sql, USER, intent.id))!;
    adapter.lookup = { ...first, status: "partially_filled", filledQuantity: "5", updatedAt: "2026-11-13T10:01:00Z" };
    assertEquals((await reconcileIntent(d, submitted)).status, "partially_filled");
    const partial = (await loadIntent(sql, USER, intent.id))!;
    const older = { ...adapter.lookup, filledQuantity: "2", updatedAt: "2026-11-13T10:00:30Z" };
    const latest = { ...adapter.lookup, status: "filled" as const, filledQuantity: "10", updatedAt: "2026-11-13T10:02:00Z" };
    await Promise.all([
      d.store.recordBrokerOrder(intent.id, partial.status, latest),
      d.store.recordBrokerOrder(intent.id, partial.status, older),
    ]);
    const view = await intentView(sql, (await loadIntent(sql, USER, intent.id))!);
    assertEquals(view.status, "filled");
    assertEquals(view.brokerOrder?.filledQuantity, "10");
    assertEquals(view.transitions.filter((item) => item.to === "filled").length, 1);
  } finally {
    await sql.end();
  }
});

Deno.test({ name: "pg: fill pages are deduplicated and commit the checkpoint under the lease", ignore: !URL, sanitizeResources: false, sanitizeOps: false }, async () => {
  const sql = postgres(URL!, { max: 6, prepare: false, onnotice: () => {} });
  try {
    const d = deps(sql, new FakeAdapter());
    const now = Date.now();
    const fill: BrokerFill = { providerFillID: "fill-1", providerOrderID: "order-1", symbol: "AAPL",
      side: "buy", quantity: "0.25", price: "190.42", executedAt: new Date(now - 1000).toISOString() };
    let reads = 0;
    const adapter = { fills() { reads++; return Promise.resolve({ items: [fill] }); } };
    await Promise.all(Array.from({ length: 3 }, () => syncProviderFills(sql, d.connection, adapter, d.adapterContext, now)));
    assertEquals(reads, 1);
    await sql`update public.broker_connections set fill_sync_due_at = '-infinity', fill_sync_lease_until = null,
      status = 'active' where id = ${CONN}`;
    assertEquals((await syncProviderFills(sql, d.connection, adapter, d.adapterContext, Date.now() + 1000)).fills, 0);
    const [row] = await sql`select count(*)::int as count from public.broker_fills where connection_id = ${CONN}`;
    assertEquals(row.count, 1);
    const [checkpoint] = await sql`select cursor, window_start, window_end from public.provider_sync_cursors where connection_id = ${CONN}`;
    assert(checkpoint.window_start);
    assertEquals(checkpoint.window_end, null);
    assertEquals(checkpoint.cursor, null);
  } finally {
    await sql.end();
  }
});

Deno.test({ name: "pg: authenticated scheduler reconciles an order and imports a provider fill without writing to Alpaca", ignore: !URL, sanitizeResources: false, sanitizeOps: false }, async () => {
  const sql = postgres(URL!, { max: 6, prepare: false, onnotice: () => {} });
  const env = {
    SUPABASE_DB_URL: URL!,
    PROVIDER_MAINTENANCE_SECRET: crypto.randomUUID(),
    BROKER_CREDENTIALS_KEKS: JSON.stringify({ active: "k1", keys: { k1: btoa("\x01".repeat(32)) } }),
  };
  const previous = Object.fromEntries(Object.keys(env).map((name) => [name, Deno.env.get(name)]));
  for (const [name, value] of Object.entries(env)) Deno.env.set(name, value);
  const originalFetch = globalThis.fetch;
  try {
    const intent = await approvedIntent(sql);
    const d = deps(sql, new FakeAdapter());
    await d.store.transition(intent.id, "approved", "submitting");
    await d.store.transition(intent.id, "submitting", "reconciliation_required");
    const ring = await keyRingFromRaw("k1", { k1: new Uint8Array(32).fill(1) });
    const key = await seal(ring, { userID: USER, connectionID: CONN, provider: "alpaca" }, { keyID: "test-key", secretKey: "test-secret" });
    await sql`insert into public.broker_credentials (connection_id, user_id, sealed, kek_id)
      values (${CONN}, ${USER}, ${sql.json(key as never)}, 'k1')`;
    await sql`update public.broker_connections set fill_sync_due_at = '-infinity', fill_sync_lease_until = null,
      status = 'active' where id = ${CONN}`;
    await sql`update public.order_intents set provider_check_due_at = '-infinity' where id = ${intent.id}`;
    await sql`update public.order_intents set provider_check_due_at = now() + interval '1 day' where id <> ${intent.id}`;
    await sql`update public.broker_connections set fill_sync_due_at = now() + interval '1 day' where id <> ${CONN}`;
    const requests: string[] = [];
    globalThis.fetch = (input, init) => {
      const url = new globalThis.URL(String(input));
      assertEquals(url.hostname, "paper-api.alpaca.markets");
      assertEquals(init?.method, "GET");
      requests.push(url.pathname);
      const order = { id: "worker-order", client_order_id: intent.clientOrderID, symbol: "AAPL", side: "buy", type: "limit",
        status: "filled", filled_qty: "10", filled_avg_price: "190.42", updated_at: "2026-11-13T10:00:00Z" };
      if (url.pathname === "/v2/orders:by_client_order_id") return Promise.resolve(Response.json(order));
      assertEquals(url.pathname, "/v2/account/activities/FILL");
      assert(url.searchParams.get("until"));
      return Promise.resolve(Response.json([{ id: "worker-fill", order_id: order.id, symbol: "AAPL", side: "buy",
        qty: "10", price: "190.42", transaction_time: new Date(Date.now() - 1000).toISOString() }]));
    };
    const request = (secret?: string) => new Request("http://localhost", {
      method: "POST", headers: secret ? { "x-scheduler-secret": secret } : undefined,
    });
    assertEquals((await providerMaintenance(request())).status, 401);
    assertEquals(requests.length, 0);
    const [before] = await sql`select count(*)::integer as count from provider_operations.worker_runs where worker = 'provider-maintenance'`;
    const runs = await Promise.all([providerMaintenance(request(env.PROVIDER_MAINTENANCE_SECRET)), providerMaintenance(request(env.PROVIDER_MAINTENANCE_SECRET))]);
    const reports = await Promise.all(runs.map((r) => r.json()));
    assertEquals(reports.reduce((total, row) => total + row.data.errors, 0), 0);
    assertEquals(reports.reduce((total, row) => total + row.data.checked, 0), 1);
    assertEquals(reports.reduce((total, row) => total + row.data.imported, 0), 1);
    assertEquals(requests.sort(), ["/v2/account/activities/FILL", "/v2/orders:by_client_order_id"]);
    assertEquals((await loadIntent(sql, USER, intent.id))?.status, "filled");
    const [after] = await sql`select count(*)::integer as count, sum(jobs)::integer as jobs, sum(errors)::integer as errors
      from provider_operations.worker_runs where worker = 'provider-maintenance'`;
    assertEquals(after.count - before.count, 2);
    assertEquals(after.jobs, 2);
    assertEquals(after.errors, 0);
  } finally {
    globalThis.fetch = originalFetch;
    for (const name of Object.keys(env)) {
      if (previous[name] === undefined) Deno.env.delete(name);
      else Deno.env.set(name, previous[name]);
    }
    await sql.end();
  }
});


Deno.test({ name: "pg: paper stream leases, confirms via REST and commits only the matched order", ignore: !URL, sanitizeResources: false, sanitizeOps: false }, async () => {
  const sql = postgres(URL!, { max: 8, prepare: false, onnotice: () => {} });
  const envName = "BROKER_CREDENTIALS_KEKS";
  const previous = Deno.env.get(envName);
  Deno.env.set(envName, JSON.stringify({ active: "k1", keys: { k1: btoa("\x01".repeat(32)) } }));
  const providerOrderID = crypto.randomUUID();
  try {
    const intent = await approvedIntent(sql);
    const store = new PgOmsStore(sql, USER);
    assert(await store.transition(intent.id, "approved", "submitting"));
    assert(await store.transition(intent.id, "submitting", "submitted"));
    const otherUser = crypto.randomUUID();
    const otherConn = crypto.randomUUID();
    await sql`insert into auth.users(id) values (${otherUser})`;
    await sql`insert into public.broker_connections (id, user_id, adapter_id, name, environment, permissions)
      values (${otherConn}, ${otherUser}, 'alpaca', 'Unrelated paper connection', 'paper', array['read'])`;

    const now = new Date();
    const otherLease = { connection_id: otherConn, user_id: otherUser };
    const ownerLease = { connection_id: CONN, user_id: USER };
    const results = await Promise.all(Array.from({ length: 4 }, () => leaseAlpacaConnections(sql, crypto.randomUUID(), now, new Date(now.getTime() + 10_000))));
    assertEquals(results.flat(), [ownerLease]);
    await sql`update provider_operations.alpaca_stream_leases set available_at = now() - interval '1 second'`;

    const credentials = { provider: "alpaca", keyID: "stream-test-key", secretKey: "stream-test-secret" } as const;
    const ring = await keyRingFromRaw("k1", { k1: new Uint8Array(32).fill(1) });
    const sealed = await seal(ring, { userID: USER, connectionID: CONN, provider: "alpaca" },
      { keyID: credentials.keyID, secretKey: credentials.secretKey });
    await sql`insert into public.broker_credentials (connection_id, user_id, sealed, kek_id)
      values (${CONN}, ${USER}, ${sql.json(sealed as never)}, 'k1')
      on conflict (connection_id) do update set sealed = excluded.sealed, kek_id = excluded.kek_id`;

    const notice = { clientOrderID: intent.clientOrderID, providerOrderID };
    let restReads = 0;
    const getOrder = (ctx: AdapterContext, requested: string): Promise<BrokerOrder> => {
      assertEquals(ctx.environment, "paper");
      assertEquals(ctx.credentials, credentials);
      assertEquals(requested, providerOrderID);
      restReads++;
      return Promise.resolve({
        providerOrderID, clientOrderID: intent.clientOrderID, symbol: "AAPL", side: "buy", type: "limit",
        status: "partially_filled", providerStatus: "partially_filled", filledQuantity: "3", averageFillPrice: "190.41",
        updatedAt: new Date().toISOString(),
      });
    };
    assertEquals(await confirmAlpacaOrder(sql, otherLease, notice, getOrder, credentials), false);
    assertEquals(restReads, 0);
    const wrongOrder = async (ctx: AdapterContext, requested: string) => ({
      ...(await getOrder(ctx, requested)), clientOrderID: "st-foreign-intent",
    });
    assertEquals(await confirmAlpacaOrder(sql, ownerLease, notice, wrongOrder, credentials), false);
    assertEquals((await loadIntent(sql, USER, intent.id))?.status, "submitted");

    const failures = new Set<import("../_shared/worker-report.ts").FailureCode>();
    const shutdown = new AbortController();
    const frames: string[] = [];
    const socketFixture = Deno.serve({ hostname: "127.0.0.1", port: 0, signal: shutdown.signal, onListen: () => {} }, (request) => {
      const { socket, response } = Deno.upgradeWebSocket(request);
      socket.onmessage = ({ data }) => {
        const request = JSON.parse(data);
        frames.push(request.action);
        const send = (value: unknown) => socket.send(new TextEncoder().encode(JSON.stringify(value)));
        if (request.action === "auth") {
          const status = request.key === credentials.keyID && request.secret === credentials.secretKey ? "authorized" : "unauthorized";
          send({ stream: "authorization", data: { status } });
        } else if (request.action === "listen") {
          send({ stream: "listening", data: { streams: request.data.streams } });
          send({ stream: "trade_updates", data: { order: {
            id: providerOrderID, client_order_id: intent.clientOrderID, filled_qty: "10000", status: "filled",
          } } });
        }
      };
      return response;
    });
    const result = await streamAlpacaOrders(sql, failures, (secret, onOrder, signal) =>
      listenToAlpacaPaperOrders(secret, onOrder, signal, () =>
        new WebSocket(`ws://127.0.0.1:${socketFixture.addr.port}`)), getOrder, 850)
      .finally(async () => { shutdown.abort(); await socketFixture.finished; });
    assertEquals(frames, ["auth", "listen"]);
    assertEquals(result, { connectionsClaimed: 1, confirmed: 1, errors: 0 });
    assertEquals([...failures], []);
    assertEquals(restReads, 2);
    const partial = await intentView(sql, (await loadIntent(sql, USER, intent.id))!);
    assertEquals(partial.status, "partially_filled");
    assertEquals(partial.brokerOrder?.filledQuantity, "3");
    assertEquals(partial.brokerOrder?.averageFillPrice, "190.41");

    const willRevoke = async (ctx: AdapterContext, requested: string): Promise<BrokerOrder> => {
      const latest = await getOrder(ctx, requested);
      await sql`update public.broker_connections set status = 'revoked', revoked_at = now() where id = ${CONN}`;
      return { ...latest, status: "filled", providerStatus: "filled", filledQuantity: "10" };
    };
    await confirmAlpacaOrder(sql, ownerLease, notice, willRevoke, credentials);
    assertEquals((await loadIntent(sql, USER, intent.id))?.status, "partially_filled");
  } finally {
    if (previous === undefined) Deno.env.delete(envName);
    else Deno.env.set(envName, previous);
    await sql.end();
  }
});
