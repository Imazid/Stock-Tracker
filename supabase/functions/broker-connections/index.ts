// broker-connections — connect, list, sync and revoke a provider account (Alpaca, Coinbase).
//
// POST { action, ... } with the person's access token; contract in _shared/oms/api.ts.
//
// The key a person pastes is validated with the provider, sealed with envelope encryption
// (_shared/vault) bound to this user + connection + provider, and stored where no client
// role can read it. It is never returned, logged or sent anywhere but the provider. Trade
// permission is granted only if the person asked for it AND the key's scopes allow it; a key
// with transfer/withdrawal permission is refused by the adapter. Live connections can't hold
// trade permission in this build (database CHECK).
//
// Environment: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_DB_URL, BROKER_CREDENTIALS_KEKS.

import { adapterFor, capabilitiesFor, isProviderID } from "../_shared/brokers/registry.ts";
import type { AdapterContext, ConnectionPermission, ProviderCredentials, ProviderID, TradingEnvironment } from "../_shared/brokers/types.ts";
import { BrokerError } from "../_shared/brokers/types.ts";
import type { ConnectionsRequest, ConnectionView } from "../_shared/oms/api.ts";
import { syncProviderFills } from "../_shared/oms/fill_sync.ts";
import { authenticate, type Caller, errorResponse, HttpError, json, logEvent, preflight, readJSONObject } from "../_shared/oms/http.ts";
import { type ConnectionRow, database, listConnections, loadConnection, openCredentials, type Sql } from "../_shared/oms/store_pg.ts";
import { keyHint, keyRingFromEnv, seal, VaultError } from "../_shared/vault/envelope.ts";

const env = (name: string) => Deno.env.get(name);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface Ctx {
  sql: Sql;
  caller: Caller;
  body: Record<string, unknown>;
  now: number;
}

function view(c: ConnectionRow): ConnectionView {
  return {
    id: c.id, provider: c.provider, environment: c.environment, label: c.label, permissions: c.permissions, status: c.status, keyHint: c.keyHint,
    sync: {
      state: c.syncState, lastSuccessAt: c.lastSyncedAt, lastError: c.syncError,
      repair: c.status === "needs_attention" ? "The provider refused this key. Create a new key at the provider and reconnect." : undefined,
    },
    capabilities: capabilitiesFor(c.provider, c.environment),
    createdAt: c.createdAt,
  };
}

function credentialsFrom(provider: ProviderID, raw: unknown): { credentials: ProviderCredentials; secret: Record<string, string>; keyID: string } {
  if (typeof raw !== "object" || raw === null) throw new HttpError(422, "invalid", "Paste your API key details.");
  const r = raw as Record<string, unknown>;
  const text = (k: string, max: number) => {
    const v = r[k];
    if (typeof v !== "string" || v.trim() === "" || v.length > max) throw new HttpError(422, "invalid", `Missing or malformed ${k}.`, { field: k });
    return v.trim();
  };
  if (provider === "alpaca") {
    const keyID = text("keyID", 64);
    const secretKey = text("secretKey", 128);
    return { credentials: { provider, keyID, secretKey }, secret: { keyID, secretKey }, keyID };
  }
  const keyName = text("keyName", 300);
  const privateKeyPEM = text("privateKeyPEM", 4000);
  const portfolioID = typeof r.portfolioID === "string" && r.portfolioID.trim() !== "" ? r.portfolioID.trim().slice(0, 100) : undefined;
  return { credentials: { provider, keyName, privateKeyPEM, portfolioID }, secret: { keyName, privateKeyPEM, portfolioID: portfolioID ?? "" }, keyID: keyName };
}

async function ring() {
  try {
    return await keyRingFromEnv(env);
  } catch (error) {
    if (error instanceof VaultError) throw new HttpError(503, "feature_disabled", "Provider connections aren't configured on this server yet.", { gate: "credential_vault" });
    throw error;
  }
}

/** Reads the provider and stores snapshots; idempotent on provider ids. */
async function sync(ctx: Ctx, connection: ConnectionRow): Promise<{ accounts: number; positions: number; fills: number; orders: number }> {
  const sql = ctx.sql;
  const [active] = await sql`update public.broker_connections set sync_state = 'running', updated_at = now()
    where id = ${connection.id} and user_id = ${ctx.caller.userID} and status <> 'revoked' returning id`;
  if (!active) throw new HttpError(404, "not_found", "That account isn't connected.");
  try {
    const credentials = await openCredentials(sql, await ring(), connection);
    const actx: AdapterContext = { environment: connection.environment, credentials, allowLive: false };
    const adapter = adapterFor(connection.provider);
    const [accounts, balances, positions] = await Promise.all([adapter.accounts(actx), adapter.balances(actx), adapter.positions(actx)]);
    const observed = new Date(ctx.now);
    for (const b of balances) {
      await sql`insert into public.broker_balance_snapshots (user_id, connection_id, currency, total, available, reserved, observed_at)
                values (${ctx.caller.userID}, ${connection.id}, ${b.currency}, ${b.total}, ${b.available}, ${b.reserved}, ${observed})`;
    }
    for (const p of positions) {
      await sql`insert into public.broker_position_snapshots (user_id, connection_id, symbol, asset_class, quantity, average_entry_price, cost_basis, market_value, currency, observed_at)
                values (${ctx.caller.userID}, ${connection.id}, ${p.symbol}, ${p.assetClass}, ${p.quantity}, ${p.averageEntryPrice ?? null},
                        ${p.costBasis ?? null}, ${p.marketValue ?? null}, ${p.currency}, ${observed})`;
    }
    const { fills } = await syncProviderFills(sql, connection, adapter, { ...actx, readAttempts: 1 }, Date.now(), 3, undefined, true);
    const open = await adapter.orders(actx, { status: "open", limit: 100 });
    const account = accounts[0];
    await sql`update public.broker_connections set sync_state = 'ok', last_synced_at = now(), sync_error = null, status = 'active',
              provider_account_id = coalesce(provider_account_id, ${account?.providerAccountID ?? null}), updated_at = now()
              where id = ${connection.id} and user_id = ${ctx.caller.userID} and status <> 'revoked'`;
    return { accounts: accounts.length, positions: positions.length, fills, orders: open.items.length };
  } catch (error) {
    const message = error instanceof BrokerError ? error.message : "The sync didn't finish.";
    const needsAttention = error instanceof BrokerError && (error.code === "unauthorized" || error.code === "forbidden");
    await sql`update public.broker_connections set sync_state = 'failed', sync_error = ${message.slice(0, 500)},
              status = case when ${needsAttention} then 'needs_attention' else status end, updated_at = now()
              where id = ${connection.id} and user_id = ${ctx.caller.userID} and status <> 'revoked'`;
    throw error instanceof BrokerError ? new HttpError(502, "provider_error", message, { providerCode: error.code }) : error;
  }
}

const actions: Record<ConnectionsRequest["action"], (ctx: Ctx) => Promise<unknown>> = {
  list: async (ctx) => ({ connections: (await listConnections(ctx.sql, ctx.caller.userID)).map(view) }),

  connect: async (ctx) => {
    const provider = ctx.body.provider;
    if (!isProviderID(provider)) throw new HttpError(422, "invalid", "Choose Alpaca or Coinbase.");
    const environment = ctx.body.environment as TradingEnvironment;
    if (!["paper", "sandbox", "live"].includes(environment)) throw new HttpError(422, "invalid", "Choose an environment.");
    const wanted = Array.isArray(ctx.body.permissions) ? (ctx.body.permissions as unknown[]).filter((p): p is ConnectionPermission => p === "read" || p === "trade") : ["read" as const];
    const { credentials, secret, keyID } = credentialsFrom(provider, ctx.body.credentials);
    const keyRing = await ring();

    // Prove the key works and learn what it may do. Errors carry no key material.
    let validated;
    try {
      validated = await adapterFor(provider).validate({ environment, credentials, allowLive: false });
    } catch (error) {
      if (error instanceof BrokerError) throw new HttpError(422, "invalid", error.message, { providerCode: error.code });
      throw error;
    }
    const granted: ConnectionPermission[] = ["read"];
    if (wanted.includes("trade") && validated.permissions.includes("trade") && environment !== "live") granted.push("trade");
    const account = validated.accounts[0];
    const label = typeof ctx.body.label === "string" && ctx.body.label.trim() !== "" ? ctx.body.label.trim().slice(0, 80) : account?.label ?? `${provider} ${environment}`;

    // deno-lint-ignore no-explicit-any
    const id = await ctx.sql.begin(async (tx: any) => {
      const [row] = await tx`insert into public.broker_connections (user_id, adapter_id, name, environment, permissions, provider_account_id, key_hint, status)
                             values (${ctx.caller.userID}, ${provider}, ${label}, ${environment}, ${granted}, ${account?.providerAccountID ?? null}, ${keyHint(keyID)}, 'active')
                             returning id`;
      const sealed = await seal(keyRing, { userID: ctx.caller.userID, connectionID: row.id, provider }, secret);
      await tx`insert into public.broker_credentials (connection_id, user_id, sealed, kek_id) values (${row.id}, ${ctx.caller.userID}, ${tx.json(sealed)}, ${sealed.kekID})`;
      await tx`insert into public.oms_events (user_id, kind, detail) values (${ctx.caller.userID}, 'connections.connected', ${tx.json({ connectionID: row.id, provider, environment, permissions: granted })})`;
      return String(row.id);
    }) as string;
    const connection = (await loadConnection(ctx.sql, ctx.caller.userID, id))!;
    let synced;
    try {
      synced = await sync(ctx, connection);
    } catch {
      synced = undefined; // the connection stands; its sync state says what went wrong
    }
    const fresh = (await loadConnection(ctx.sql, ctx.caller.userID, id))!;
    return synced ? { connection: view(fresh), synced } : { connection: view(fresh) };
  },

  sync: async (ctx) => {
    const id = typeof ctx.body.connectionID === "string" && UUID.test(ctx.body.connectionID) ? ctx.body.connectionID : "";
    const connection = await loadConnection(ctx.sql, ctx.caller.userID, id);
    if (!connection || connection.status === "revoked") throw new HttpError(404, "not_found", "That account isn't connected.");
    const synced = await sync(ctx, connection);
    return { connection: view((await loadConnection(ctx.sql, ctx.caller.userID, id))!), synced };
  },

  revoke: async (ctx) => {
    const id = typeof ctx.body.connectionID === "string" && UUID.test(ctx.body.connectionID) ? ctx.body.connectionID : "";
    const connection = await loadConnection(ctx.sql, ctx.caller.userID, id);
    if (!connection || connection.status === "revoked") throw new HttpError(404, "not_found", "That account isn't connected.");
    const [open] = await ctx.sql`select count(*)::int as n from public.order_intents where connection_id = ${id} and user_id = ${ctx.caller.userID}
                                 and status in ('submitting', 'submitted', 'partially_filled', 'reconciliation_required')`;
    if (open.n > 0) {
      throw new HttpError(409, "conflict", "This account has orders still open at the provider. Cancel or wait for them first — disconnecting would stop us tracking them.", { openOrders: open.n });
    }
    // The trigger deletes the sealed key in the same statement.
    await ctx.sql`update public.broker_connections set status = 'revoked', revoked_at = now(), permissions = array['read'], updated_at = now()
                  where id = ${id} and user_id = ${ctx.caller.userID}`;
    await ctx.sql`insert into public.oms_events (user_id, kind, detail) values (${ctx.caller.userID}, 'connections.revoked', ${ctx.sql.json({ connectionID: id })})`;
    return { revoked: true, note: "We deleted the key we stored. Also delete the key at the provider so it can't be used anywhere." };
  },
};

Deno.serve(async (request) => {
  const started = Date.now();
  if (request.method === "OPTIONS") return preflight();
  let action = "unknown";
  let response: Response;
  try {
    if (request.method !== "POST") throw new HttpError(405, "method_not_allowed", "Send a POST request.");
    const caller = await authenticate(request, { url: env("SUPABASE_URL"), anonKey: env("SUPABASE_ANON_KEY") });
    const body = await readJSONObject(request);
    action = typeof body.action === "string" ? body.action : "";
    const run = Object.hasOwn(actions, action) ? actions[action as ConnectionsRequest["action"]] : undefined;
    if (!run) throw new HttpError(400, "invalid", "That isn't something the connections API can do.");
    response = json(200, { ok: true, data: await run({ sql: database(), caller, body, now: started }) });
  } catch (error) {
    response = errorResponse(error);
  }
  logEvent("broker_connections", { action, status: response.status, ms: Date.now() - started });
  return response;
});
