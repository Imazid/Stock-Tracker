// Database-side upkeep the edge functions share: the day-long traded-value cache (see
// ../market/volume_cache.ts and migration 20261113150000) and pruning old idempotency keys.

import type { VolumeStore } from "../market/volume_cache.ts";
import type { Sql } from "./persistence.ts";

/** Idempotency keys are kept this long: long enough for any client retry, short enough not to pile up. */
export const IDEMPOTENCY_KEY_DAYS = 30;
/** At most this many keys go per scheduler run, so one run never holds a long lock. */
const PRUNE_BATCH = 5_000;

/** The traded-value cache in `public.trading_volume_cache`, read and written as the service role. */
export function postgresVolumeStore(sql: Sql): VolumeStore {
  return {
    async read(ids, notBefore) {
      if (ids.length === 0) return {};
      const rows = await sql.begin(async (tx) => {
        await tx`set local role service_role`;
        return await tx`select instrument_id, dollar_volume from public.trading_volume_cache
                        where instrument_id in ${tx(ids)} and fetched_at >= ${new Date(notBefore)}`;
      });
      return Object.fromEntries(rows.map((row) => [row.instrument_id as string, row.dollar_volume as number]));
    },
    async write(figures, fetchedAt, source) {
      const rows = Object.entries(figures).map(([instrument_id, dollar_volume]) => ({ instrument_id, dollar_volume, source, fetched_at: new Date(fetchedAt) }));
      if (rows.length === 0) return;
      await sql.begin(async (tx) => {
        await tx`set local role service_role`;
        // A newer figure is never overwritten by an older one (two runs finishing out of order).
        await tx`insert into public.trading_volume_cache ${tx(rows)}
                 on conflict (instrument_id) do update
                   set dollar_volume = excluded.dollar_volume, source = excluded.source, fetched_at = excluded.fetched_at
                   where public.trading_volume_cache.fetched_at <= excluded.fetched_at`;
      });
    },
  };
}

/** Deletes idempotency keys older than 30 days (one batch). Returns how many went. */
export async function pruneIdempotencyKeys(sql: Sql, now: number): Promise<number> {
  const cutoff = new Date(now - IDEMPOTENCY_KEY_DAYS * 86_400_000);
  const rows = await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    return await tx`delete from public.trading_idempotency_keys
                    where (user_id, key) in (
                      select user_id, key from public.trading_idempotency_keys
                      where created_at < ${cutoff} order by created_at limit ${PRUNE_BATCH})
                    returning 1`;
  });
  return rows.length;
}
