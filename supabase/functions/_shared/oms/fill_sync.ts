import type { AdapterContext, BrokerAdapter, BrokerFill } from "../brokers/types.ts";
import { BrokerError } from "../brokers/types.ts";
import type { ConnectionState } from "./execute.ts";
import type { Sql } from "./store_pg.ts";

const OVERLAP_MS = 24 * 60 * 60_000;
const PAGE_SIZE = 100;

export interface FillCheckpoint {
  since?: string;
  until?: string;
  cursor?: string;
}

interface FillPageStore {
  checkpoint: FillCheckpoint;
  commit(next: FillCheckpoint, fills: BrokerFill[]): Promise<boolean>;
}

/** A cursor is valid only for the same scan window. A finished scan restarts from
 *  its upper boundary with overlap for late provider records. Fill IDs dedupe reads. */
export async function syncFillPages(
  adapter: Pick<BrokerAdapter, "fills">,
  ctx: AdapterContext,
  store: FillPageStore,
  now: number,
  maxPages: number,
): Promise<{ fills: number; complete: boolean }> {
  let { since, until, cursor } = store.checkpoint;
  until ??= new Date(now).toISOString();
  if (since && Date.parse(since) >= Date.parse(until)) return { fills: 0, complete: true };
  let fills = 0;
  for (let page = 0; page < maxPages; page++) {
    const result = await adapter.fills(ctx, { since, until, cursor, limit: PAGE_SIZE });
    if (result.cursor && result.cursor === cursor) {
      throw new BrokerError("provider_unavailable", "The provider returned a repeated fill page.");
    }
    const next = result.cursor
      ? { since, until, cursor: result.cursor }
      : { since: new Date(Date.parse(until) - OVERLAP_MS).toISOString() };
    if (!(await store.commit(next, result.items))) return { fills, complete: false };
    fills += result.items.length;
    if (!result.cursor) return { fills, complete: true };
    cursor = result.cursor;
  }
  return { fills, complete: false };
}

/** Claim via the connection row before network I/O. This protects manual and scheduled
 *  workers alike. Each page commits with its checkpoint under the same row lock. */
export async function syncProviderFills(
  sql: Sql,
  connection: ConnectionState,
  adapter: Pick<BrokerAdapter, "fills">,
  ctx: AdapterContext,
  now: number,
  maxPages = 3,
  claimedUntil?: Date,
  manual = false,
): Promise<{ fills: number; complete: boolean }> {
  const leaseUntil = claimedUntil ?? new Date(now + 120_000);
  if (!claimedUntil) {
    const [claimed] = await sql`
      update public.broker_connections set fill_sync_lease_until = ${leaseUntil}
      where id = ${connection.id} and user_id = ${connection.userID} and status <> 'revoked'
        and (${manual} or fill_sync_due_at <= ${new Date(now)})
        and (fill_sync_lease_until is null or fill_sync_lease_until <= ${new Date(now)}) returning id`;
    if (!claimed) return { fills: 0, complete: false };
  }

  let delay = 5 * 60_000;
  let cursor: string | undefined;
  try {
    const [current] = await sql`select window_start, window_end, cursor from public.provider_sync_cursors
                                where connection_id = ${connection.id} and stream = 'fills'`;
    const iso = (value: Date | string | null | undefined) => value ? new Date(value).toISOString() : undefined;
    const checkpoint: FillCheckpoint = {
      since: iso(current?.window_start), until: iso(current?.window_end), cursor: current?.cursor ?? undefined,
    };
    cursor = checkpoint.cursor;
    let inserted = 0;
    const result = await syncFillPages(adapter, ctx, {
      checkpoint,
      async commit(next, rows) {
        const count = await sql.begin(async (tx) => {
          const [owned] = await tx`select id from public.broker_connections where id = ${connection.id}
            and user_id = ${connection.userID} and status <> 'revoked' and fill_sync_lease_until = ${leaseUntil} for update`;
          if (!owned) return -1;
          const values = rows.map((fill) => ({
            user_id: connection.userID, connection_id: connection.id, provider_fill_id: fill.providerFillID,
            provider_order_id: fill.providerOrderID, symbol: fill.symbol, side: fill.side, quantity: fill.quantity,
            price: fill.price, fee: fill.fee ?? null, fee_currency: fill.feeCurrency ?? null, executed_at: new Date(fill.executedAt),
          }));
          const saved = values.length
            ? (await tx`insert into public.broker_fills ${tx(values)} on conflict (connection_id, provider_fill_id) do nothing returning id`).length
            : 0;
          await tx`insert into public.provider_sync_cursors (connection_id, stream, cursor, window_start, window_end)
                   values (${connection.id}, 'fills', ${next.cursor ?? null}, ${next.since ?? null}, ${next.until ?? null})
                   on conflict (connection_id, stream) do update set cursor = excluded.cursor,
                     window_start = excluded.window_start, window_end = excluded.window_end, updated_at = now()`;
          return saved;
        }) as number;
        if (count < 0) return false;
      cursor = next.cursor;
        inserted += count;
        return true;
      },
    }, now, maxPages);
    if (!result.complete) delay = 45_000;
    return { fills: inserted, complete: result.complete };
  } catch (error) {
    // A provider may expire its page token between jobs. Restart the same fixed
    // window on the next run and keep the committed pages deduplicated.
    if (cursor && error instanceof BrokerError && error.code === "invalid_request") {
      await sql`update public.provider_sync_cursors set cursor = null, updated_at = now()
        where connection_id = ${connection.id} and stream = 'fills' and cursor = ${cursor}
        and exists (select 1 from public.broker_connections where id = ${connection.id}
          and user_id = ${connection.userID} and fill_sync_lease_until = ${leaseUntil})`;
    }
    if (error instanceof BrokerError && (error.code === "unauthorized" || error.code === "forbidden")) {
      await sql`update public.broker_connections set status = 'needs_attention', sync_state = 'failed',
        sync_error = 'Provider rejected the saved credentials.', updated_at = now()
        where id = ${connection.id} and user_id = ${connection.userID} and fill_sync_lease_until = ${leaseUntil}
          and status <> 'revoked'`;
    }
    throw error;
  } finally {
    await sql`update public.broker_connections set fill_sync_due_at = ${new Date(Date.now() + delay)}, fill_sync_lease_until = null
      where id = ${connection.id} and user_id = ${connection.userID} and fill_sync_lease_until = ${leaseUntil}`;
  }
}
