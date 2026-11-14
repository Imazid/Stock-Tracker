import { listenToAlpacaPaperOrders, type AlpacaOrderNotice, type AlpacaStreamEnd } from "../_shared/brokers/alpaca-paper-stream.ts";
import { alpacaAdapter } from "../_shared/brokers/alpaca.ts";
import { BrokerError, type ProviderCredentials } from "../_shared/brokers/types.ts";
import { AT_PROVIDER } from "../_shared/oms/lifecycle.ts";
import { loadConnection, loadIntent, openCredentials, PgOmsStore, type Sql } from "../_shared/oms/store_pg.ts";
import { keyRingFromEnv } from "../_shared/vault/envelope.ts";
import { type FailureCode, providerFailure } from "../_shared/worker-report.ts";

type Lease = { connection_id: string; user_id: string };
type OpenStream = typeof listenToAlpacaPaperOrders;
type ReadBrokerOrder = typeof alpacaAdapter.getOrder;
type AlpacaCredentials = Extract<ProviderCredentials, { provider: "alpaca" }>;

const ROTATION_MS = 45_000;
const LEASE_MS = 75_000;
const MAX_ORDERS_PER_WINDOW = 30;

export async function leaseAlpacaConnections(sql: Sql, token: string, now: Date, expires: Date): Promise<Lease[]> {
  return await sql<Lease[]>`
    with due as (
      select c.id, c.user_id from public.broker_connections c
      left join provider_operations.alpaca_stream_leases l on l.connection_id = c.id
      where c.adapter_id = 'alpaca' and c.environment = 'paper' and c.status = 'active'
        and 'read' = any(c.permissions) and (l.available_at is null or l.available_at <= ${now})
        and exists (
          select 1 from public.order_intents i where i.connection_id = c.id and i.user_id = c.user_id
            and i.provider = 'alpaca' and i.environment = 'paper'
            and i.status in ('submitted', 'partially_filled', 'reconciliation_required')
        )
      order by l.last_started_at asc nulls first, c.id
      limit 8 for update of c skip locked
    ), claimed as (
      insert into provider_operations.alpaca_stream_leases (connection_id, token, last_started_at, available_at)
      select id, ${token}, ${now}, ${expires} from due
      on conflict (connection_id) do update set token = excluded.token,
        last_started_at = excluded.last_started_at, available_at = excluded.available_at
      where provider_operations.alpaca_stream_leases.available_at <= ${now}
      returning connection_id
    )
    select claimed.connection_id, due.user_id from claimed join due on due.id = claimed.connection_id`;
}

export async function confirmAlpacaOrder(
  sql: Sql,
  lease: Lease,
  notice: AlpacaOrderNotice,
  getOrder: ReadBrokerOrder,
  credentials: AlpacaCredentials,
): Promise<boolean> {
  const [row] = await sql`
    select i.id from public.order_intents i join public.broker_connections c
      on c.id = i.connection_id and c.user_id = i.user_id
    where i.user_id = ${lease.user_id} and i.connection_id = ${lease.connection_id}
      and i.client_order_id = ${notice.clientOrderID}
      and i.provider = 'alpaca' and i.environment = 'paper'
      and (i.provider_order_id is null or i.provider_order_id = ${notice.providerOrderID})
      and c.status = 'active' and c.adapter_id = 'alpaca' and c.environment = 'paper' and 'read' = any(c.permissions)`;
  if (!row) return false;
  const intent = await loadIntent(sql, lease.user_id, row.id);
  if (!intent || !AT_PROVIDER.includes(intent.status)) return false;
  const order = await getOrder(
    { credentials, environment: "paper", timeoutMs: 4_000, readAttempts: 1 },
    notice.providerOrderID,
  );
  const equivalentSymbol = order.symbol.replace(/\//g, "") === intent.input.symbol.replace(/\//g, "");
  if (order.providerOrderID !== notice.providerOrderID || order.clientOrderID !== intent.clientOrderID ||
      !equivalentSymbol || order.side !== intent.input.side || order.type !== intent.input.type) return false;
  const store = new PgOmsStore(sql, lease.user_id);
  await store.recordBrokerOrder(intent.id, intent.status, order, { requireActiveConnection: true });
  return true;
}

// The lease expires even if an Edge worker is recycled mid-window.
export async function streamAlpacaOrders(
  sql: Sql,
  failures: Set<FailureCode>,
  openStream: OpenStream = listenToAlpacaPaperOrders,
  getOrder: ReadBrokerOrder = alpacaAdapter.getOrder,
  windowMs = ROTATION_MS,
) {
  const now = new Date();
  const token = crypto.randomUUID();
  const leases = await leaseAlpacaConnections(sql, token, now, new Date(now.getTime() + LEASE_MS));
  if (leases.length === 0) return { connectionsClaimed: 0, confirmed: 0, errors: 0 };
  const ring = await keyRingFromEnv((key) => Deno.env.get(key));
  const results = await Promise.all(leases.map(async (lease) => {
    let confirmed = 0;
    let errors = 0;
    let ending: AlpacaStreamEnd = "elapsed";
    try {
      const connection = await loadConnection(sql, lease.user_id, lease.connection_id);
      if (connection?.provider !== "alpaca" || connection.environment !== "paper" ||
          connection.status !== "active" || !connection.permissions.includes("read")) return { confirmed, errors };
      const stored = await openCredentials(sql, ring, connection);
      if (stored.provider !== "alpaca") return { confirmed, errors };
      const credentials: AlpacaCredentials = stored;
      const sessionEnded = new AbortController();
      const deadline = AbortSignal.any([AbortSignal.timeout(windowMs), sessionEnded.signal]);
      const pending = new Map<string, AlpacaOrderNotice>();
      let drain: Promise<void> | undefined;
      let reads = 0;
      const confirmPending = async () => {
        // Merge repeated events during a burst. An event received during a REST read can
        // enqueue another read, so a partial fill cannot hide a later final fill.
        while (pending.size && !deadline.aborted && reads < MAX_ORDERS_PER_WINDOW) {
          const next = pending.entries().next().value;
          if (!next) break;
          const [key, notice] = next;
          pending.delete(key);
          reads++;
          try {
            if (await confirmAlpacaOrder(sql, lease, notice, getOrder, credentials)) confirmed++;
          } catch (error) {
            if (error instanceof BrokerError && error.code === "not_found") continue;
            errors++;
            failures.add(error instanceof BrokerError
              ? providerFailure(typeof error.details.status === "number" ? error.details.status : undefined, "provider_order")
              : "database");
          }
        }
        drain = undefined;
      };
      ending = await openStream(credentials, (notice) => {
        if (deadline.aborted || reads >= MAX_ORDERS_PER_WINDOW || pending.size >= MAX_ORDERS_PER_WINDOW) return;
        pending.set(notice.providerOrderID, notice);
        drain ??= confirmPending();
      }, deadline);
      sessionEnded.abort();
      await drain;
      if (ending !== "elapsed") {
        errors++;
        failures.add(ending === "unauthorized" ? "provider_auth" : ending === "protocol" ? "provider_response" : "provider_unavailable");
      }
    } catch {
      errors++;
      failures.add("internal");
    } finally {
      const available = new Date(Date.now() + (errors ? 120_000 : 0));
      await sql`update provider_operations.alpaca_stream_leases set available_at = ${available}
        where connection_id = ${lease.connection_id} and token = ${token}`;
    }
    return { confirmed, errors };
  }));
  return {
    connectionsClaimed: leases.length,
    confirmed: results.reduce((sum, value) => sum + value.confirmed, 0),
    errors: results.reduce((sum, value) => sum + value.errors, 0),
  };
}
