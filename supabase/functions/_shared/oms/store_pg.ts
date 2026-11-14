// Postgres side of the order system: the OmsStore the pipeline writes through, and the
// loaders the two edge functions read with. Runs as the service role (SUPABASE_DB_URL), so
// EVERY query here filters by the caller's user id itself — RLS is not what protects these.

import postgres from "npm:postgres@3.4.5";
import type { BrokerOrder, ProviderCredentials, ProviderID, TradingEnvironment } from "../brokers/types.ts";
import { defaultAccountPolicy, type AccountPolicy, standardPolicy } from "../trading/risk.ts";
import type { GateID, IntentStatus, OrderIntentInput, OrderIntentView, RiskEvaluationView } from "./api.ts";
import type { ApprovalRecord } from "./approval.ts";
import * as D from "../decimal.ts";
import type { ConnectionState, IntentRecord, OmsStore } from "./execute.ts";
import { type GateRow, resolveGates } from "./gates.ts";
import { nextFromBroker, RESERVING } from "./lifecycle.ts";
import { DEFAULT_ACCOUNT_LIMITS, type ProviderPolicy, type ReservingOrder } from "./risk.ts";
import { type KeyRing, open as openSealed, type SealedSecret } from "../vault/envelope.ts";

// deno-lint-ignore no-explicit-any
export type Sql = postgres.Sql<any>;

let shared: Sql | undefined;
export function database(): Sql {
  if (!shared) {
    const url = Deno.env.get("SUPABASE_DB_URL");
    if (!url) throw new Error("SUPABASE_DB_URL is not set");
    shared = postgres(url, { max: 4, idle_timeout: 20, prepare: false });
  }
  return shared;
}

const dec = (v: unknown): string | undefined => (v === null || v === undefined ? undefined : D.normalise(String(v)));
const ms = (v: unknown): number => (v instanceof Date ? v.getTime() : Date.parse(String(v)));
const iso = (v: unknown): string | undefined => (v === null || v === undefined ? undefined : new Date(ms(v)).toISOString());

// MARK: - Gates, kill switch, account policy

export async function loadGates(sql: Sql): Promise<Record<GateID, GateRow>> {
  const rows = await sql`select id, enabled, reason, updated_at from public.platform_gates`;
  return resolveGates(rows.map((r) => ({ id: r.id as GateID, enabled: r.enabled === true, reason: r.reason ?? "", updatedAt: iso(r.updated_at) })));
}

/** The practice server's per-person policy row (kill switch, account-wide limits), if that table exists. */
export async function accountPolicyFor(sql: Sql, userID: string): Promise<AccountPolicy> {
  const policy = defaultAccountPolicy();
  const [exists] = await sql`select to_regclass('public.risk_policies') is not null as present`;
  if (!exists?.present) return policy;
  const [row] = await sql`select kill_switch_engaged, kill_switch_at, max_symbol_exposure_pct, max_total_daily_notional
                          from public.risk_policies where user_id = ${userID}`;
  if (!row) return policy;
  return {
    ...policy,
    killSwitchEngaged: row.kill_switch_engaged === true,
    killSwitchAt: row.kill_switch_at ? ms(row.kill_switch_at) : undefined,
    maxSymbolExposurePct: Number(row.max_symbol_exposure_pct),
    maxTotalDailyNotional: Number(row.max_total_daily_notional),
    // Live authorisation is never read from storage on this path.
  };
}

// MARK: - Connections and credentials

export interface ConnectionRow extends ConnectionState {
  label: string;
  keyHint: string;
  syncState: "never" | "running" | "ok" | "failed";
  lastSyncedAt?: string;
  syncError?: string;
  createdAt: string;
}

function connectionFrom(r: Record<string, unknown>): ConnectionRow {
  return {
    id: String(r.id),
    userID: String(r.user_id),
    provider: r.adapter_id as ProviderID,
    environment: r.environment as TradingEnvironment,
    status: r.status as ConnectionRow["status"],
    permissions: (r.permissions as string[]).filter((p): p is "read" | "trade" => p === "read" || p === "trade"),
    providerAccountID: (r.provider_account_id as string | null) ?? undefined,
    label: String(r.name),
    keyHint: String(r.key_hint ?? "…"),
    syncState: (r.sync_state as ConnectionRow["syncState"]) ?? "never",
    lastSyncedAt: iso(r.last_synced_at),
    syncError: (r.sync_error as string | null) ?? undefined,
    createdAt: iso(r.created_at)!,
  };
}

export async function listConnections(sql: Sql, userID: string): Promise<ConnectionRow[]> {
  const rows = await sql`select * from public.broker_connections
                         where user_id = ${userID} and adapter_id in ('alpaca', 'coinbase') and status <> 'revoked'
                         order by created_at desc`;
  return rows.map(connectionFrom);
}

export async function loadConnection(sql: Sql, userID: string, id: string): Promise<ConnectionRow | undefined> {
  const [row] = await sql`select * from public.broker_connections where id = ${id} and user_id = ${userID}`;
  return row ? connectionFrom(row) : undefined;
}

export async function openCredentials(sql: Sql, ring: KeyRing, connection: ConnectionState): Promise<ProviderCredentials> {
  const [row] = await sql`select sealed from public.broker_credentials where connection_id = ${connection.id} and user_id = ${connection.userID}`;
  if (!row) throw new Error("credentials_missing");
  const secret = await openSealed(ring, { userID: connection.userID, connectionID: connection.id, provider: connection.provider }, row.sealed as SealedSecret);
  if (connection.provider === "alpaca") return { provider: "alpaca", keyID: secret.keyID, secretKey: secret.secretKey };
  return { provider: "coinbase", keyName: secret.keyName, privateKeyPEM: secret.privateKeyPEM, portfolioID: secret.portfolioID || undefined };
}

// MARK: - Intents

function intentFrom(r: Record<string, unknown>): IntentRecord {
  const input: OrderIntentInput = {
    connectionID: String(r.connection_id),
    symbol: String(r.symbol),
    assetClass: r.asset_class as OrderIntentInput["assetClass"],
    side: r.side as OrderIntentInput["side"],
    type: r.order_type as OrderIntentInput["type"],
    timeInForce: r.time_in_force as OrderIntentInput["timeInForce"],
    quantity: dec(r.quantity),
    notional: dec(r.notional),
    limitPrice: dec(r.limit_price),
    stopPrice: dec(r.stop_price),
    origin: r.origin_kind === "agent" ? { kind: "agent", agentID: String(r.agent_id), rationale: String(r.rationale ?? "") } : { kind: "manual" },
  };
  const estimate = (r.estimate ?? {}) as Record<string, string>;
  return {
    id: String(r.id),
    userID: String(r.user_id),
    provider: r.provider as ProviderID,
    environment: r.environment as TradingEnvironment,
    input,
    clientOrderID: String(r.client_order_id),
    intentHash: String(r.intent_hash),
    status: r.status as IntentStatus,
    createdAt: ms(r.created_at),
    submittingAt: r.provider_submitting_at ? ms(r.provider_submitting_at) : undefined,
    expiresAt: ms(r.expires_at),
    estimatedNotional: estimate.notional,
    providerOrderID: (r.provider_order_id as string | null) ?? undefined,
    reconcilingSince: r.reconciling_since ? ms(r.reconciling_since) : undefined,
  };
}

export async function loadIntent(sql: Sql, userID: string, id: string): Promise<IntentRecord | undefined> {
  const [row] = await sql`select * from public.order_intents where id = ${id} and user_id = ${userID}`;
  return row ? intentFrom(row) : undefined;
}

export async function insertIntent(sql: Sql, fields: {
  userID: string; provider: ProviderID; environment: TradingEnvironment; input: OrderIntentInput; clientOrderID: string;
  intentHash: string; estimate: Record<string, string>; expiresAt: number;
}): Promise<IntentRecord> {
  const i = fields.input;
  const [row] = await sql`
    insert into public.order_intents (user_id, connection_id, provider, environment, symbol, asset_class, side, order_type, time_in_force,
      quantity, notional, limit_price, stop_price, origin_kind, agent_id, rationale, client_order_id, intent_hash, estimate, expires_at)
    values (${fields.userID}, ${i.connectionID}, ${fields.provider}, ${fields.environment}, ${i.symbol}, ${i.assetClass}, ${i.side}, ${i.type},
      ${i.timeInForce}, ${i.quantity ?? null}, ${i.notional ?? null}, ${i.limitPrice ?? null}, ${i.stopPrice ?? null},
      ${i.origin.kind}, ${i.origin.kind === "agent" ? i.origin.agentID : null}, ${i.origin.kind === "agent" ? i.origin.rationale : null},
      ${fields.clientOrderID}, ${fields.intentHash}, ${sql.json(fields.estimate)}, ${new Date(fields.expiresAt)})
    returning *`;
  return intentFrom(row);
}

export async function listIntents(sql: Sql, userID: string, filter: "open" | "closed" | "all"): Promise<IntentRecord[]> {
  const terminal = ["filled", "rejected", "expired", "cancelled", "failed"];
  const rows = filter === "all"
    ? await sql`select * from public.order_intents where user_id = ${userID} order by created_at desc limit 200`
    : filter === "open"
    ? await sql`select * from public.order_intents where user_id = ${userID} and status <> all(${terminal}) order by created_at desc limit 200`
    : await sql`select * from public.order_intents where user_id = ${userID} and status = any(${terminal}) order by created_at desc limit 200`;
  return rows.map(intentFrom);
}

export async function intentView(sql: Sql, intent: IntentRecord): Promise<OrderIntentView> {
  const [risk] = await sql`select risk, estimate from public.order_intents where id = ${intent.id}`;
  const transitions = await sql`select from_status, to_status, note, at from public.order_intent_transitions where intent_id = ${intent.id} order by id`;
  const [approval] = await sql`select approved_at, expires_at, consumed_at, aal from public.order_approvals where intent_id = ${intent.id}`;
  const [order] = intent.providerOrderID
    ? await sql`select status, filled_quantity, average_fill_price, submitted_at, provider_updated_at from public.broker_orders
                 where provider_order_id = ${intent.providerOrderID} and connection_id = ${intent.input.connectionID} and user_id = ${intent.userID}`
    : [];
  const estimate = (risk?.estimate ?? {}) as Record<string, string>;
  return {
    ...intent.input,
    id: intent.id,
    provider: intent.provider,
    environment: intent.environment,
    status: intent.status,
    intentHash: intent.intentHash,
    clientOrderID: intent.clientOrderID,
    estimate: { notional: estimate.notional, fee: estimate.fee, feeCurrency: estimate.feeCurrency, currency: estimate.currency ?? "USD" },
    risk: (risk?.risk as RiskEvaluationView | null) ?? undefined,
    approval: approval ? { approvedAt: iso(approval.approved_at)!, expiresAt: iso(approval.expires_at)!, consumedAt: iso(approval.consumed_at), aal: approval.aal } : undefined,
    brokerOrder: order && intent.providerOrderID
      ? { providerOrderID: intent.providerOrderID, status: order.status, filledQuantity: dec(order.filled_quantity) ?? "0",
          averageFillPrice: dec(order.average_fill_price), submittedAt: iso(order.submitted_at), updatedAt: iso(order.provider_updated_at) }
      : undefined,
    transitions: transitions.map((t) => ({ from: (t.from_status as IntentStatus | null) ?? null, to: t.to_status as IntentStatus, at: iso(t.at)!, note: t.note ?? undefined })),
    createdAt: new Date(intent.createdAt).toISOString(),
    expiresAt: new Date(intent.expiresAt).toISOString(),
  };
}

export async function reservingOrders(sql: Sql, userID: string, connectionID: string): Promise<ReservingOrder[]> {
  const rows = await sql`select id, symbol, asset_class, side, quantity, notional, limit_price, risk
                         from public.order_intents
                         where user_id = ${userID} and connection_id = ${connectionID} and status = any(${[...RESERVING]})`;
  return rows.map((r) => ({
    intentID: String(r.id),
    symbol: String(r.symbol),
    assetClass: r.asset_class,
    side: r.side,
    quantity: dec(r.quantity),
    notional: dec(r.notional),
    price: dec(r.limit_price) ?? (r.risk?.price?.value as string | undefined) ?? "0",
  }));
}

export async function knownClientOrderIDs(sql: Sql, userID: string, except: string): Promise<Set<string>> {
  const rows = await sql`select client_order_id from public.order_intents where user_id = ${userID} and client_order_id <> ${except}`;
  return new Set(rows.map((r) => String(r.client_order_id)));
}

export async function providerPolicy(sql: Sql, userID: string, connectionID: string, equity: number, crypto: boolean, currency: string): Promise<ProviderPolicy> {
  const [row] = await sql`select version, limits, account_limits from public.provider_risk_policies where connection_id = ${connectionID} and user_id = ${userID}`;
  if (!row) return { version: 0, limits: standardPolicy(Math.max(equity, 1), 10, crypto, currency), account: DEFAULT_ACCOUNT_LIMITS };
  return { version: Number(row.version), limits: row.limits, account: { ...DEFAULT_ACCOUNT_LIMITS, ...(row.account_limits ?? {}) } };
}

/** Runs `fn` holding the person's trading lock (released when the transaction ends). */
export async function serializeFor<T>(sql: Sql, userID: string, fn: () => Promise<T>): Promise<T> {
  // deno-lint-ignore no-explicit-any
  return await sql.begin(async (tx: any) => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${"oms:" + userID}, 0))`;
    return await fn();
  }) as T;
}

// MARK: - Idempotency

export async function remembered(sql: Sql, userID: string, key: string | undefined, action: string): Promise<{ status: number; body: unknown } | undefined> {
  if (!key) return undefined;
  const [row] = await sql`select action, status, response from public.oms_idempotency_keys where user_id = ${userID} and key = ${key}`;
  if (!row) return undefined;
  if (row.action !== action) return { status: 409, body: { ok: false, error: { code: "conflict", message: "That Idempotency-Key was already used for a different request." } } };
  return { status: Number(row.status), body: row.response };
}

export async function remember(sql: Sql, userID: string, key: string | undefined, action: string, status: number, body: unknown): Promise<void> {
  if (!key) return;
  await sql`insert into public.oms_idempotency_keys (user_id, key, action, status, response)
            values (${userID}, ${key}, ${action}, ${status}, ${sql.json(body as never)}) on conflict do nothing`;
}

// MARK: - The store the pipeline writes through

export class PgOmsStore implements OmsStore {
  constructor(private readonly sql: Sql, private readonly userID: string) {}

  async transition(intentID: string, from: IntentStatus, to: IntentStatus, note?: string): Promise<boolean> {
    try {
      // deno-lint-ignore no-explicit-any
      return await this.sql.begin(async (tx: any) => {
        if (note) await tx`select set_config('oms.transition_note', ${note.slice(0, 500)}, true)`;
        const rows = await tx`update public.order_intents set status = ${to}
                              where id = ${intentID} and user_id = ${this.userID} and status = ${from} returning id`;
        return rows.length === 1;
      }) as boolean;
    } catch (error) {
      // The database's state machine refused it: treat as "didn't move".
      if ((error as { code?: string }).code === "23514") return false;
      throw error;
    }
  }

  async loadApproval(intentID: string): Promise<ApprovalRecord | undefined> {
    const [r] = await this.sql`select a.* from public.order_approvals a join public.order_intents i on i.id = a.intent_id
                               where a.intent_id = ${intentID} and i.user_id = ${this.userID}`;
    if (!r) return undefined;
    return {
      intentID: String(r.intent_id), approverID: String(r.approver_id), approvedIntentHash: String(r.approved_intent_hash), aal: r.aal,
      approvedAt: ms(r.approved_at), expiresAt: ms(r.expires_at), consumedAt: r.consumed_at ? ms(r.consumed_at) : undefined,
    };
  }

  async consumeApproval(intentID: string, now: number): Promise<boolean> {
    const [r] = await this.sql`select public.oms_consume_approval(${intentID}, ${new Date(now)}) as used`;
    return r?.used === true;
  }

  async recordBrokerOrder(intentID: string, from: IntentStatus, order: BrokerOrder): Promise<IntentStatus> {
    return await this.sql.begin(async (tx) => {
      const [intent] = await tx`select connection_id, status, provider_order_id, client_order_id from public.order_intents
                               where id = ${intentID} and user_id = ${this.userID} for update`;
      if (!intent || intent.status !== from) return (intent?.status as IntentStatus | undefined) ?? from;
      if ((intent.provider_order_id && intent.provider_order_id !== order.providerOrderID) ||
          (order.clientOrderID && order.clientOrderID !== intent.client_order_id)) return from;
      const [previous] = from === "partially_filled" && order.status === "partially_filled"
        ? await tx`select filled_quantity from public.broker_orders where connection_id = ${intent.connection_id}
                    and provider_order_id = ${order.providerOrderID}`
        : [];
      const to = previous && dec(previous.filled_quantity) === D.normalise(order.filledQuantity)
        ? undefined : nextFromBroker(from, order.status);
      if (!to && from === "partially_filled" && ["pending_new", "accepted", "pending_cancel", "pending_replace"].includes(order.status)) return from;
      const [saved] = await tx`
      insert into public.broker_orders (user_id, connection_id, intent_id, provider_order_id, client_order_id, symbol, side, order_type, status,
        provider_status, quantity, notional, filled_quantity, average_fill_price, limit_price, stop_price, submitted_at, provider_updated_at)
      values (${this.userID}, ${intent.connection_id}, ${intentID}, ${order.providerOrderID}, ${order.clientOrderID ?? null}, ${order.symbol},
        ${order.side}, ${order.type}, ${order.status}, ${order.providerStatus}, ${order.quantity ?? null}, ${order.notional ?? null},
        ${order.filledQuantity}, ${order.averageFillPrice ?? null}, ${order.limitPrice ?? null}, ${order.stopPrice ?? null},
        ${order.submittedAt ? new Date(order.submittedAt) : null}, ${order.updatedAt ? new Date(order.updatedAt) : null})
      on conflict (connection_id, provider_order_id) do update set
        status = excluded.status, provider_status = excluded.provider_status, filled_quantity = excluded.filled_quantity,
        average_fill_price = coalesce(excluded.average_fill_price, broker_orders.average_fill_price),
        provider_updated_at = coalesce(excluded.provider_updated_at, broker_orders.provider_updated_at), updated_at = now(),
        intent_id = coalesce(public.broker_orders.intent_id, excluded.intent_id)
      where (broker_orders.intent_id is null or broker_orders.intent_id = excluded.intent_id)
        and (broker_orders.provider_updated_at is null or excluded.provider_updated_at >= broker_orders.provider_updated_at
          or excluded.provider_updated_at is null and excluded.status in ('filled', 'canceled', 'expired', 'rejected'))
        and excluded.filled_quantity >= broker_orders.filled_quantity
      returning id`;
      if (!saved) return from;
      if (to) await tx`select set_config('oms.transition_note', ${("provider: " + order.providerStatus).slice(0, 500)}, true)`;
      if (to || !intent.provider_order_id) {
        await tx`update public.order_intents set status = ${to ?? from}, provider_order_id = ${order.providerOrderID}
                 where id = ${intentID} and user_id = ${this.userID}`;
      }
      return to ?? from;
    }) as IntentStatus;
  }

  async recordRisk(intentID: string, risk: RiskEvaluationView): Promise<void> {
    await this.sql`update public.order_intents set risk = ${this.sql.json(risk as never)} where id = ${intentID} and user_id = ${this.userID}`;
  }

  async audit(event: { userID: string; intentID: string; kind: string; detail: Record<string, unknown> }): Promise<void> {
    await this.sql`insert into public.oms_events (user_id, intent_id, kind, detail)
                   values (${this.userID}, ${event.intentID}, ${event.kind}, ${this.sql.json(event.detail as never)})`;
  }
}
