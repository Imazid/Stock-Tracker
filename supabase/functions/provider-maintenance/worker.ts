import { adapterFor } from "../_shared/brokers/registry.ts";
import { BrokerError } from "../_shared/brokers/types.ts";
import { errorResponse, HttpError, json, logEvent, sameSecret } from "../_shared/server/http.ts";
import { reconcileIntent } from "../_shared/oms/execute.ts";
import { syncProviderFills } from "../_shared/oms/fill_sync.ts";
import { database, loadConnection, loadIntent, openCredentials, PgOmsStore, type Sql } from "../_shared/oms/store_pg.ts";
import { keyRingFromEnv } from "../_shared/vault/envelope.ts";

const env = (name: string) => Deno.env.get(name);
type Job = { id: string; user_id: string; connection_id: string };
const LEASE_MS = 120_000;

function reportFailure(operation: "order" | "fills", error: unknown) {
  logEvent("provider_maintenance_failure", {
    operation,
    code: error instanceof BrokerError ? error.code : error instanceof Error ? error.name : "unknown",
  });
}

async function claimOrders(sql: Sql, now: Date, lease: Date): Promise<Job[]> {
  return await sql<Job[]>`
    with due as (
      select i.id from public.order_intents i join public.broker_connections c
        on c.id = i.connection_id and c.user_id = i.user_id
      where i.status in ('submitting', 'submitted', 'partially_filled', 'reconciliation_required')
        and i.environment <> 'live' and c.environment = i.environment and c.status = 'active'
        and c.adapter_id = i.provider and 'read' = any(c.permissions)
        and i.provider_check_due_at <= ${now}
        and (i.status <> 'submitting' or i.provider_submitting_at <= ${new Date(now.getTime() - LEASE_MS)})
      order by i.provider_check_due_at, i.id limit 4 for update of i skip locked
    )
    update public.order_intents i set provider_check_due_at = ${lease}
    from due where i.id = due.id returning i.id, i.user_id, i.connection_id`;
}

async function claimFills(sql: Sql, now: Date, lease: Date): Promise<Job[]> {
  return await sql<Job[]>`
    with due as (
      select id from public.broker_connections
      where status = 'active' and adapter_id in ('alpaca', 'coinbase') and 'read' = any(permissions)
        and fill_sync_due_at <= ${now}
        and (fill_sync_lease_until is null or fill_sync_lease_until <= ${now})
      order by fill_sync_due_at, id limit 2 for update skip locked
    )
    update public.broker_connections c set fill_sync_lease_until = ${lease}
    from due where c.id = due.id returning c.id, c.user_id, c.id as connection_id`;
}

async function handle(request: Request): Promise<Response> {
  if (request.method !== "POST") throw new HttpError(405, "method_not_allowed", "Send a POST request.");
  const secret = env("PROVIDER_MAINTENANCE_SECRET") ?? "";
  if (secret.length < 32 || !sameSecret(secret, request.headers.get("x-scheduler-secret") ?? "")) {
    throw new HttpError(401, "unauthorized", "Not allowed.");
  }

  const now = Date.now();
  const sql = database();
  const ring = await keyRingFromEnv(env);
  const lease = new Date(now + LEASE_MS);
  const [orders, connections] = await Promise.all([claimOrders(sql, new Date(now), lease), claimFills(sql, new Date(now), lease)]);
  const sessions = new Map<string, ReturnType<typeof sessionFor>>();
  async function sessionFor(job: Job) {
    const connection = await loadConnection(sql, job.user_id, job.connection_id);
    if (!connection || connection.status !== "active" || !connection.permissions.includes("read")) return undefined;
    const credentials = await openCredentials(sql, ring, connection);
    return {
      connection,
      adapter: adapterFor(connection.provider),
      context: { environment: connection.environment, credentials, allowLive: false, timeoutMs: 7_000, readAttempts: 1 },
    };
  }
  function session(job: Job) {
    const cached = sessions.get(job.connection_id);
    if (cached) return cached;
    const pending = sessionFor(job);
    sessions.set(job.connection_id, pending);
    return pending;
  }

  let checked = 0;
  let imported = 0;
  let errors = 0;
  await Promise.all([
    ...orders.map(async (job) => {
      let delay = 60_000;
      try {
        const [intent, s] = await Promise.all([loadIntent(sql, job.user_id, job.id), session(job)]);
        if (!intent || !s || intent.environment === "live") return;
        const outcome = await reconcileIntent(
          { store: new PgOmsStore(sql, job.user_id), adapter: s.adapter, adapterContext: s.context, now: () => now },
          intent,
        );
        if (outcome.ok) checked++;
        else {
          delay = 5 * 60_000;
          errors++;
        }
      } catch (error) {
        delay = 5 * 60_000;
        errors++;
        reportFailure("order", error);
      } finally {
        await sql`update public.order_intents set provider_check_due_at = ${new Date(Date.now() + delay)}
          where id = ${job.id} and user_id = ${job.user_id} and provider_check_due_at = ${lease}`;
      }
    }),
    ...connections.map(async (job) => {
      try {
        const s = await session(job);
        if (!s) return;
        const result = await syncProviderFills(sql, s.connection, s.adapter, s.context, now, 3, lease);
        imported += result.fills;
      } catch (error) {
        errors++;
        reportFailure("fills", error);
      }
    }),
  ]);
  const data = { ordersClaimed: orders.length, connectionsClaimed: connections.length, checked, imported, errors };
  logEvent("provider_maintenance", data);
  return json(200, { ok: true, data });
}

export async function providerMaintenance(request: Request): Promise<Response> {
  try {
    return await handle(request);
  } catch (error) {
    const response = errorResponse(error);
    logEvent("provider_maintenance_refused", { status: response.status });
    return response;
  }
}
