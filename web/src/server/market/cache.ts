// A small in-process cache with in-flight de-duplication. Identical upstream requests made
// at the same time share one fetch; successful answers are reused for a short TTL (seconds,
// well under the minute-level freshness shown to people). Failures are not cached, except
// for a brief cool-down so a throttled upstream isn't hammered.

interface Entry {
  expires: number;
  value: unknown;
}

interface CacheGlobals {
  __stMarketCache?: Map<string, Entry>;
  __stMarketInflight?: Map<string, Promise<unknown>>;
}

const g = globalThis as CacheGlobals;
const store = (g.__stMarketCache ??= new Map<string, Entry>());
const inflight = (g.__stMarketInflight ??= new Map<string, Promise<unknown>>());

const MAX_ENTRIES = 2_000;

export async function cached<T>(key: string, ttlMs: number, load: () => Promise<T>): Promise<T> {
  const now = Date.now();
  const hit = store.get(key);
  if (hit && hit.expires > now) return hit.value as T;
  const pending = inflight.get(key);
  if (pending) return pending as Promise<T>;
  const promise = (async () => {
    try {
      const value = await load();
      if (store.size >= MAX_ENTRIES) {
        // Drop the oldest-inserted entries; Map keeps insertion order.
        let drop = Math.ceil(MAX_ENTRIES / 10);
        for (const k of store.keys()) {
          store.delete(k);
          if (--drop <= 0) break;
        }
      }
      store.set(key, { expires: Date.now() + ttlMs, value });
      return value;
    } finally {
      inflight.delete(key);
    }
  })();
  inflight.set(key, promise);
  return promise;
}

/** For tests and manual refresh. */
export function invalidate(prefix: string): void {
  for (const k of store.keys()) if (k.startsWith(prefix)) store.delete(k);
}
