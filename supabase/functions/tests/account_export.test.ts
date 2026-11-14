// deno-lint-ignore no-import-prefix
import { assertEquals } from "jsr:@std/assert@1";
import { accountRecords, accountSections, parseAccountPage } from "../account-export/records.ts";

Deno.test("account export accepts only named sections and valid page offsets", () => {
  assertEquals(new Set(accountSections.map(({ id }) => id)).size, accountSections.length);
  assertEquals(parseAccountPage("account", undefined), { id: "account", start: 0 });
  assertEquals(parseAccountPage("private_reports", 20), { id: "private_reports", start: 20 });
  assertEquals(parseAccountPage("watchlist_group_assets", 50), { id: "watchlist_group_assets", start: 50 });
  for (const [section, offset] of [["account", 1], ["private_valuation_history", 0], ["secure_credentials", 0],
    ["__proto__", 0], ["watchlists", -1], ["watchlists", 1.25], ["watchlists", "50"], ["watchlists", 1_000_000_001]]) {
    assertEquals(parseAccountPage(section, offset), null);
  }
});

Deno.test("account export scopes credentials metadata and trims lookahead rows", async () => {
  const calls: unknown[][] = [];
  const rows = Array.from({ length: 51 }, (_, n) => ({ id: String(n) }));
  const query = {
    select(fields: string) { calls.push(["select", fields]); return this; },
    eq(column: string, value: string) { calls.push(["eq", column, value]); return this; },
    order(column: string) { calls.push(["order", column]); return this; },
    range(start: number, end: number) { calls.push(["range", start, end]); return this; },
    returns() { return Promise.resolve({ data: rows, error: null }); },
  };
  const admin = {
    from(table: string) { calls.push(["from", table]); return query; },
  } as unknown as Parameters<typeof accountRecords>[0];

  const page = await accountRecords(admin, "verified-owner", "sync_connections", 50);
  assertEquals(calls, [
    ["from", "secure_credentials"],
    ["select", "id,purpose,provider,created_at,updated_at,revoked_at"],
    ["eq", "user_id", "verified-owner"],
    ["order", "id"],
    ["range", 50, 100],
  ]);
  assertEquals(page, { records: rows.slice(0, 50), next_offset: 100 });

  calls.length = 0;
  await accountRecords(admin, "verified-owner", "watchlist_group_assets", 0);
  assertEquals(calls, [
    ["from", "watchlist_group_assets"],
    ["select", "id,group_id,listing_id,symbol,name,kind,exchange,added_at,sort_position::text"],
    ["eq", "user_id", "verified-owner"],
    ["order", "group_id"],
    ["order", "listing_id"],
    ["range", 0, 50],
  ]);
});
