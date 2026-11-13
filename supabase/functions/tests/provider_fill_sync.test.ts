import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { AdapterContext, BrokerAdapter, BrokerFill } from "../_shared/brokers/types.ts";
import { type FillCheckpoint, syncFillPages } from "../_shared/oms/fill_sync.ts";

const ctx: AdapterContext = { environment: "paper", credentials: { provider: "alpaca", keyID: "test", secretKey: "test" } };
const now = Date.parse("2026-11-13T10:00:00.000Z");
const firstBoundary = new Date(now).toISOString();
const fill = (providerFillID: string): BrokerFill => ({
  providerFillID, providerOrderID: "o-1", symbol: "AAPL", side: "buy", quantity: "1", price: "100", executedAt: "2026-11-13T09:00:00.000Z",
});

Deno.test("fill sync resumes a fixed time window, then starts a fresh scan for later fills", async () => {
  let checkpoint: FillCheckpoint = {};
  const stored = new Set<string>();
  const adapter: Pick<BrokerAdapter, "fills"> = {
    fills(_ctx, options) {
      if (options.until === firstBoundary && !options.cursor) return Promise.resolve({ items: [fill("a")], cursor: "older" });
      if (options.until === firstBoundary) {
        assertEquals(options.cursor, "older");
        return Promise.resolve({ items: [fill("b")] });
      }
      assertEquals(options.since, "2026-11-12T10:00:00.000Z");
      assertEquals(options.cursor, undefined);
      return Promise.resolve({ items: [fill("c"), fill("a")] });
    },
  };
  const run = (time: number) => syncFillPages(adapter, ctx, {
    checkpoint,
    commit(next, fills) {
      for (const item of fills) stored.add(item.providerFillID);
      checkpoint = next;
      return Promise.resolve(true);
    },
  }, time, 1);

  assertEquals(await run(now), { fills: 1, complete: false });
  assertEquals(checkpoint.until, firstBoundary);
  assertEquals(await run(now + 60_000), { fills: 1, complete: true });
  assertEquals(await run(now + 120_000), { fills: 2, complete: true });
  assertEquals([...stored], ["a", "b", "c"]);
});

Deno.test("fill sync cannot advance a stale lease or a repeated page", async () => {
  const checkpoint = { until: firstBoundary, cursor: "older" };
  let commits = 0;
  const store = { checkpoint, commit() { commits++; return Promise.resolve(false); } };
  assertEquals(await syncFillPages({ fills: () => Promise.resolve({ items: [fill("a")] }) }, ctx, store, now, 2),
    { fills: 0, complete: false });
  await assertRejects(() => syncFillPages({ fills: () => Promise.resolve({ items: [fill("a")], cursor: "older" }) }, ctx, store, now, 2),
    Error, "repeated fill page");
  assertEquals(commits, 1);
});
