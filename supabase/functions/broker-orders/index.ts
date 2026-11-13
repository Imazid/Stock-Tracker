// broker-orders — orders that go to a PROVIDER account (Alpaca paper today).
//
// POST { action, ... } with the person's access token; contract in _shared/oms/api.ts.
//   list · get · draft · riskCheck · approve · reject · submit · cancel · reconcile
//
// Practice trading (simulated fills in our own database) is trading-api, not this.
// Nothing here lets a model decide anything: an intent is drafted by the person, checked by
// the deterministic risk engine, approved by the person (hash-bound, single use, step-up
// where required) and only then sent — by _shared/oms/execute.ts, the one place that calls a
// provider's order endpoint. Live (real-money) environments are refused by the database, the
// platform gate and the adapter, independently.
//
// Environment (function secrets; never logged or returned):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_DB_URL     provided by Supabase
//   BROKER_CREDENTIALS_KEKS                               credential key ring (see _shared/vault)
//   ALPACA_DATA_KEY_ID, ALPACA_DATA_SECRET                market data for risk checks

import { adapterFor, capabilitiesFor } from "../_shared/brokers/registry.ts";
import type { AdapterContext, BrokerAdapter, ProviderCapabilities } from "../_shared/brokers/types.ts";
import { BrokerError } from "../_shared/brokers/types.ts";
import { providerFromEnv } from "../_shared/market/index.ts";
import type { ApiErrorCode, OrderIntentInput, OrdersRequest } from "../_shared/oms/api.ts";
import { checkApprove, DEFAULT_APPROVAL_POLICY } from "../_shared/oms/approval.ts";
import * as D from "../_shared/decimal.ts";
import { cancelIntent, type ExecutionDeps, type ExecutionOutcome, type IntentRecord, reconcileIntent, submitIntent } from "../_shared/oms/execute.ts";
import { GateClosedError, gateForEnvironment, requireGates } from "../_shared/oms/gates.ts";
import { authenticate, type Caller, errorResponse, HttpError, idempotencyKey, json, logEvent, preflight, readJSONObject, statusFor } from "../_shared/oms/http.ts";
import { canonicalIntent, IntentError, intentHash, newClientOrderID, validateInput } from "../_shared/oms/intent.ts";
import { canTransition } from "../_shared/oms/lifecycle.ts";
import { engineInstrument, evaluateProviderRisk, type ProviderQuote } from "../_shared/oms/risk.ts";
import {
  accountPolicyFor, type ConnectionRow, database, insertIntent, intentView, knownClientOrderIDs, listIntents, loadConnection, loadGates,
  loadIntent, openCredentials, PgOmsStore, providerPolicy, remember, remembered, reservingOrders, serializeFor, type Sql,
} from "../_shared/oms/store_pg.ts";
import { keyRingFromEnv, VaultError } from "../_shared/vault/envelope.ts";

const env = (name: string) => Deno.env.get(name);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface Ctx {
  sql: Sql;
  caller: Caller;
  body: Record<string, unknown>;
  now: number;
}
type Result = { status: number; body: unknown };
const done = (data: unknown): Result => ({ status: 200, body: { ok: true, data } });
const refused = (code: ApiErrorCode, message: string, details?: Record<string, unknown>): Result =>
  ({ status: statusFor(code), body: { ok: false, error: details ? { code, message, details } : { code, message } } });

function uuidField(value: unknown, name: string): string {
  if (typeof value !== "string" || !UUID.test(value)) throw new HttpError(422, "invalid", `${name} must be an id.`);
  return value.toLowerCase();
}

async function ownedIntent(ctx: Ctx): Promise<IntentRecord> {
  const intent = await loadIntent(ctx.sql, ctx.caller.userID, uuidField(ctx.body.intentID, "intentID"));
  if (!intent) throw new HttpError(404, "not_found", "That order doesn't exist.");
  return intent;
}

async function ownedConnection(ctx: Ctx, id: string): Promise<ConnectionRow> {
  const connection = await loadConnection(ctx.sql, ctx.caller.userID, id);
  if (!connection || connection.status === "revoked") throw new HttpError(404, "not_found", "That account isn't connected.");
  return connection;
}

// MARK: - Provider session (credentials opened per request, never stored or returned)

interface Session {
  adapter: BrokerAdapter;
  context: Omit<AdapterContext, "allowLive">;
  capabilities: ProviderCapabilities;
}

async function session(ctx: Ctx, connection: ConnectionRow): Promise<Session> {
  let credentials;
  try {
    credentials = await openCredentials(ctx.sql, await keyRingFromEnv(env), connection);
  } catch (error) {
    if (error instanceof VaultError && error.code === "not_configured") throw new HttpError(503, "feature_disabled", "Provider connections aren't configured on this server.", { gate: "credential_vault" });
    throw new HttpError(409, "provider_error", "This connection's key can't be used. Reconnect it in Connections.");
  }
  return { adapter: adapterFor(connection.provider), context: { environment: connection.environment, credentials }, capabilities: capabilitiesFor(connection.provider, connection.environment) };
}

async function marketQuote(intent: IntentRecord, now: number): Promise<{ quote?: ProviderQuote; bars?: import("../_shared/trading/market.ts").Bar[] }> {
  const choice = providerFromEnv(env);
  if (!choice.provider) return {};
  const instrument = engineInstrument(intent.input.symbol, intent.input.assetClass);
  if (!choice.provider.supports(instrument)) return {};
  const [quotes, bars] = await Promise.all([
    choice.provider.quotes([instrument], now).catch(() => undefined),
    choice.provider.bars([instrument], "day", 30, now).catch(() => undefined),
  ]);
  const id = `${instrument.venue}:${instrument.symbol}`;
  const q = quotes?.quotes[id];
  const quote: ProviderQuote | undefined = q && q.provenance.kind === "market"
    ? {
      last: D.fromNumber(q.last), bid: q.bid ? D.fromNumber(q.bid) : undefined, ask: q.ask ? D.fromNumber(q.ask) : undefined,
      observedAt: q.time, source: q.provenance.source, delaySeconds: q.provenance.delaySeconds,
      status: q.provenance.delaySeconds === 0 ? "real_time" : "delayed", currency: instrument.currency,
    }
    : undefined;
  return { quote, bars: bars?.series[id]?.bars };
}

async function evaluateRisk(ctx: Ctx, intent: IntentRecord, connection: ConnectionRow, s: Session) {
  const actx: AdapterContext = { ...s.context, allowLive: false };
  // "Today" is the trailing 24 hours: conservative (counts at least as much as the calendar day).
  const [accounts, positions, fills, market, accountPolicy, reserving, known] = await Promise.all([
    s.adapter.accounts(actx),
    s.adapter.positions(actx),
    s.adapter.fills(actx, { since: new Date(ctx.now - 86_400_000).toISOString(), limit: 500 }).catch(() => ({ items: [] })),
    marketQuote(intent, ctx.now),
    accountPolicyFor(ctx.sql, ctx.caller.userID),
    reservingOrders(ctx.sql, ctx.caller.userID, connection.id),
    knownClientOrderIDs(ctx.sql, ctx.caller.userID, intent.clientOrderID),
  ]);
  const account = connection.providerAccountID ? accounts.find((a) => a.providerAccountID === connection.providerAccountID) : accounts[0];
  const equity = account?.equity ?? account?.cash ?? "0";
  const policy = await providerPolicy(ctx.sql, ctx.caller.userID, connection.id, D.toNumber(equity), intent.input.assetClass === "crypto", account?.currency ?? "USD");
  return evaluateProviderRisk({
    intent, connection, capabilities: s.capabilities, policy, accountPolicy,
    snapshot: {
      currency: account?.currency ?? "USD", cash: account?.cash ?? "0", equity,
      positions, fillsToday: fills.items.map((f) => ({ symbol: f.symbol, side: f.side, quantity: f.quantity, price: f.price, executedAt: Date.parse(f.executedAt) })),
    },
    reserving, knownClientOrderIDs: known, quote: market.quote, dailyBars: market.bars, now: ctx.now,
  });
}

function deps(ctx: Ctx, connection: ConnectionRow, s: Session, gates: ExecutionDeps["gates"], killSwitch: boolean, maxQuoteAgeMs: number): ExecutionDeps {
  return {
    store: new PgOmsStore(ctx.sql, ctx.caller.userID),
    gates,
    killSwitchEngaged: killSwitch,
    connection,
    adapter: s.adapter,
    adapterContext: s.context,
    evaluateRisk: (intent) => evaluateRisk(ctx, intent, connection, s),
    maxQuoteAgeMs,
    approvalPolicy: DEFAULT_APPROVAL_POLICY,
    serialize: (fn) => serializeFor(ctx.sql, ctx.caller.userID, fn),
    now: () => ctx.now,
  };
}

const outcome = async (ctx: Ctx, intentID: string, out: ExecutionOutcome): Promise<Result> => {
  const fresh = await loadIntent(ctx.sql, ctx.caller.userID, intentID);
  const view = fresh ? await intentView(ctx.sql, fresh) : undefined;
  return out.ok ? done({ intent: view }) : refused(out.code, out.message, { ...(out.details ?? {}), intent: view });
};

async function pipelineFor(ctx: Ctx, intent: IntentRecord) {
  const connection = await ownedConnection(ctx, intent.input.connectionID);
  const s = await session(ctx, connection);
  const [gates, accountPolicy] = await Promise.all([loadGates(ctx.sql), accountPolicyFor(ctx.sql, ctx.caller.userID)]);
  const policy = await providerPolicy(ctx.sql, ctx.caller.userID, connection.id, 1, intent.input.assetClass === "crypto", "USD");
  return deps(ctx, connection, s, gates, accountPolicy.killSwitchEngaged, policy.limits.maxQuoteAgeSeconds * 1000);
}

// MARK: - Actions

const actions: Record<OrdersRequest["action"], (ctx: Ctx) => Promise<Result>> = {
  list: async (ctx) => {
    const filter = ctx.body.status === "open" || ctx.body.status === "closed" ? ctx.body.status : "all";
    const intents = await listIntents(ctx.sql, ctx.caller.userID, filter);
    return done({ intents: await Promise.all(intents.map((i) => intentView(ctx.sql, i))) });
  },

  get: async (ctx) => done({ intent: await intentView(ctx.sql, await ownedIntent(ctx)) }),

  draft: async (ctx) => {
    const input = ctx.body.intent as OrderIntentInput;
    if (typeof input !== "object" || input === null) throw new HttpError(422, "invalid", "Send the order as `intent`.");
    // People draft manual orders. Agent drafts come only from the server-side scheduler.
    if (input.origin?.kind !== "manual") throw new HttpError(403, "forbidden", "Agents propose orders through the scheduler, not this endpoint.");
    try {
      validateInput(input);
    } catch (error) {
      if (error instanceof IntentError) throw new HttpError(422, "invalid", error.message, { field: error.field });
      throw error;
    }
    const connection = await ownedConnection(ctx, input.connectionID.toLowerCase());
    if (connection.status !== "active") return refused("provider_error", "This connection needs attention. Reconnect it in Connections.");
    if (!connection.permissions.includes("trade")) return refused("forbidden", "This connection is read-only. It was never given permission to trade.");
    try {
      requireGates(await loadGates(ctx.sql), gateForEnvironment(connection.environment, false));
    } catch (error) {
      if (error instanceof GateClosedError) return refused("feature_disabled", error.reason, { gate: error.gate });
      throw error;
    }
    const caps = capabilitiesFor(connection.provider, connection.environment);
    const cap = caps.orders.find((o) => o.assetClass === input.assetClass);
    if (!caps.executionAvailable || !cap) return refused("feature_disabled", caps.notes[0] ?? "This account can't take orders for that asset.");
    if (!cap.orderTypes.includes(input.type)) return refused("invalid", `This provider doesn't accept ${input.type.replace("_", "-")} orders for this asset.`);
    if (!(cap.timeInForce[input.type] ?? []).includes(input.timeInForce)) return refused("invalid", `This provider doesn't accept that time in force for ${input.type.replace("_", "-")} orders.`);
    if (input.notional && !cap.notional) return refused("invalid", "This provider doesn't accept orders by amount for this asset; give a quantity.");

    const clientOrderID = newClientOrderID();
    const normalized: OrderIntentInput = { ...input, connectionID: connection.id, symbol: input.symbol.toUpperCase() };
    const hash = await intentHash(canonicalIntent({ userID: ctx.caller.userID, provider: connection.provider, environment: connection.environment, clientOrderID, input: normalized }));
    const probe: IntentRecord = { id: "", userID: ctx.caller.userID, provider: connection.provider, environment: connection.environment, input: normalized, clientOrderID, intentHash: hash, status: "draft", createdAt: ctx.now, expiresAt: ctx.now };
    const { quote } = await marketQuote(probe, ctx.now);
    const estimate: Record<string, string> = { currency: "USD" };
    if (normalized.notional) estimate.notional = normalized.notional;
    else if (quote) estimate.notional = D.round(D.mul(normalized.quantity!, normalized.limitPrice ?? quote.ask ?? quote.last), 2);
    if (quote) {
      estimate.priceSource = quote.source;
      estimate.priceObservedAt = new Date(quote.observedAt).toISOString();
    }
    // Alpaca charges no commission on paper/US equities; regulatory pass-through fees on sells are not estimated.
    estimate.fee = "0";
    estimate.feeCurrency = "USD";
    const intent = await insertIntent(ctx.sql, {
      userID: ctx.caller.userID, provider: connection.provider, environment: connection.environment, input: normalized,
      clientOrderID, intentHash: hash, estimate, expiresAt: ctx.now + DEFAULT_APPROVAL_POLICY.intentTtlMs,
    });
    await new PgOmsStore(ctx.sql, ctx.caller.userID).audit({ userID: ctx.caller.userID, intentID: intent.id, kind: "oms.drafted", detail: { symbol: normalized.symbol, side: normalized.side, type: normalized.type } });
    return done({ intent: await intentView(ctx.sql, intent) });
  },

  riskCheck: async (ctx) => {
    const intent = await ownedIntent(ctx);
    if (!["draft", "risk_checked", "awaiting_approval"].includes(intent.status)) return refused("conflict", "This order is past the risk check.");
    if (ctx.now >= intent.expiresAt) {
      await new PgOmsStore(ctx.sql, ctx.caller.userID).transition(intent.id, intent.status, "expired", "expired before approval");
      return refused("approval_expired", "This order expired. Prepare it again.");
    }
    const connection = await ownedConnection(ctx, intent.input.connectionID);
    const s = await session(ctx, connection);
    const store = new PgOmsStore(ctx.sql, ctx.caller.userID);
    const risk = await serializeFor(ctx.sql, ctx.caller.userID, () => evaluateRisk(ctx, intent, connection, s));
    await store.recordRisk(intent.id, risk);
    if (risk.result === "fail") {
      await store.transition(intent.id, intent.status, "rejected", `risk: ${risk.reasonCodes.join(",")}`);
      await store.audit({ userID: ctx.caller.userID, intentID: intent.id, kind: "oms.risk_rejected", detail: { reasonCodes: risk.reasonCodes, policyVersion: risk.policyVersion } });
    } else {
      let status = intent.status;
      if (status !== "risk_checked" && (await store.transition(intent.id, status, "risk_checked", `policy v${risk.policyVersion}`))) status = "risk_checked";
      if (status === "risk_checked") await store.transition(intent.id, "risk_checked", "awaiting_approval");
    }
    const fresh = (await loadIntent(ctx.sql, ctx.caller.userID, intent.id))!;
    return risk.result === "fail"
      ? refused("risk_rejected", "This order breaks your risk limits.", { reasonCodes: risk.reasonCodes, intent: await intentView(ctx.sql, fresh) })
      : done({ intent: await intentView(ctx.sql, fresh) });
  },

  approve: async (ctx) => {
    const intent = await ownedIntent(ctx);
    if (intent.status !== "awaiting_approval") return refused("conflict", "This order isn't waiting for approval.");
    const presented = typeof ctx.body.intentHash === "string" ? ctx.body.intentHash : "";
    const problem = checkApprove({
      callerID: ctx.caller.userID, callerAAL: ctx.caller.aal, ownerID: intent.userID, storedHash: intent.intentHash, presentedHash: presented,
      environment: intent.environment, estimatedNotional: intent.estimatedNotional, intentExpiresAt: intent.expiresAt, now: ctx.now,
    });
    if (problem) return refused(problem.code, problem.message);
    const store = new PgOmsStore(ctx.sql, ctx.caller.userID);
    await ctx.sql`insert into public.order_approvals (intent_id, approver_id, approved_intent_hash, aal, approved_at, expires_at)
                  values (${intent.id}, ${ctx.caller.userID}, ${intent.intentHash}, ${ctx.caller.aal}, ${new Date(ctx.now)},
                          ${new Date(ctx.now + DEFAULT_APPROVAL_POLICY.approvalTtlMs)})
                  on conflict (intent_id) do nothing`;
    if (!(await store.transition(intent.id, "awaiting_approval", "approved", `aal ${ctx.caller.aal}`))) return refused("conflict", "This order changed while approving. Refresh it.");
    await store.audit({ userID: ctx.caller.userID, intentID: intent.id, kind: "oms.approved", detail: { aal: ctx.caller.aal } });
    return done({ intent: await intentView(ctx.sql, (await loadIntent(ctx.sql, ctx.caller.userID, intent.id))!) });
  },

  reject: async (ctx) => {
    const intent = await ownedIntent(ctx);
    if (!canTransition(intent.status, "rejected") || !["draft", "risk_checked", "awaiting_approval", "approved"].includes(intent.status)) {
      return refused("conflict", "This order can't be rejected now.");
    }
    const store = new PgOmsStore(ctx.sql, ctx.caller.userID);
    const reason = typeof ctx.body.reason === "string" ? ctx.body.reason.slice(0, 200) : "rejected by owner";
    if (!(await store.transition(intent.id, intent.status, "rejected", reason))) return refused("conflict", "This order changed. Refresh it.");
    await store.audit({ userID: ctx.caller.userID, intentID: intent.id, kind: "oms.owner_rejected", detail: {} });
    return done({ intent: await intentView(ctx.sql, (await loadIntent(ctx.sql, ctx.caller.userID, intent.id))!) });
  },

  submit: async (ctx) => {
    const intent = await ownedIntent(ctx);
    return outcome(ctx, intent.id, await submitIntent(await pipelineFor(ctx, intent), intent, ctx.caller));
  },

  cancel: async (ctx) => {
    const intent = await ownedIntent(ctx);
    if (["draft", "risk_checked", "awaiting_approval", "approved"].includes(intent.status)) {
      const store = new PgOmsStore(ctx.sql, ctx.caller.userID);
      const moved = await store.transition(intent.id, intent.status, "cancelled", "cancelled before submission");
      return moved ? outcome(ctx, intent.id, { ok: true, status: "cancelled" }) : refused("conflict", "This order changed. Refresh it.");
    }
    return outcome(ctx, intent.id, await cancelIntent(await pipelineFor(ctx, intent), intent, ctx.caller));
  },

  reconcile: async (ctx) => {
    const intent = await ownedIntent(ctx);
    return outcome(ctx, intent.id, await reconcileIntent(await pipelineFor(ctx, intent), intent));
  },
};

const STATE_CHANGING = new Set(["draft", "riskCheck", "approve", "reject", "submit", "cancel"]);

async function handle(request: Request, now: number): Promise<{ response: Response; action: string }> {
  if (request.method !== "POST") throw new HttpError(405, "method_not_allowed", "Send a POST request.");
  const caller = await authenticate(request, { url: env("SUPABASE_URL"), anonKey: env("SUPABASE_ANON_KEY") });
  const body = await readJSONObject(request);
  const action = typeof body.action === "string" ? body.action : "";
  const run = Object.hasOwn(actions, action) ? actions[action as OrdersRequest["action"]] : undefined;
  if (!run) throw new HttpError(400, "invalid", "That isn't something the order API can do.");
  const key = idempotencyKey(request);
  const sql = database();
  const ctx: Ctx = { sql, caller, body, now };
  if (STATE_CHANGING.has(action)) {
    const prior = await remembered(sql, caller.userID, key, action);
    if (prior) return { response: json(prior.status, prior.body), action };
  }
  let result: Result;
  try {
    result = await run(ctx);
  } catch (error) {
    if (error instanceof BrokerError) result = refused("provider_error", "The provider couldn't be reached or refused the request.", { providerCode: error.code });
    else throw error;
  }
  if (STATE_CHANGING.has(action)) await remember(sql, caller.userID, key, action, result.status, result.body);
  return { response: json(result.status, result.body), action };
}

Deno.serve(async (request) => {
  const started = Date.now(); // the one clock read; every step of this request uses it
  if (request.method === "OPTIONS") return preflight();
  let action = "unknown";
  let response: Response;
  try {
    const handled = await handle(request, started);
    action = handled.action;
    response = handled.response;
  } catch (error) {
    response = errorResponse(error);
  }
  logEvent("broker_orders", { action, status: response.status, ms: Date.now() - started });
  return response;
});
