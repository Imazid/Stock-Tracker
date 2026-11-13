// Sealed SnapTrade identities over an in-memory credential table.
//
//   npx -y deno test --no-check=remote supabase/functions/tests/secure_credentials.test.ts

import { assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1";
import {
  CredentialConflictError,
  type CredentialEventAction,
  type CredentialRow,
  type CredentialTable,
  type NewCredentialRow,
  SealedSnapTradeStore,
} from "../_shared/secure/credentials.ts";
import { EnvelopeError, parseKeyring } from "../_shared/secure/envelope.ts";
import { toBase64 } from "../_shared/secure/encoding.ts";

const U1 = "11111111-1111-1111-1111-111111111111";
const U2 = "22222222-2222-2222-2222-222222222222";

class MemoryTable implements CredentialTable {
  rows: (CredentialRow & { revoked: boolean })[] = [];
  events: { action: CredentialEventAction; userId: string }[] = [];
  findActive(userId: string, purpose: string, provider: string) {
    return Promise.resolve(this.rows.find((r) => r.user_id === userId && r.purpose === purpose && r.provider === provider && !r.revoked) ?? null);
  }
  insert(row: NewCredentialRow) {
    const clash = this.rows.some((r) => !r.revoked && r.purpose === row.purpose &&
      (r.user_id === row.user_id || (row.external_ref !== null && r.external_ref === row.external_ref)));
    if (clash) return Promise.reject(new CredentialConflictError());
    const stored = { ...row, id: crypto.randomUUID(), revoked: false };
    this.rows.push(stored);
    return Promise.resolve(stored);
  }
  revoke(id: string) {
    const r = this.rows.find((x) => x.id === id);
    if (r) r.revoked = true;
    return Promise.resolve();
  }
  logEvent(e: { userId: string; action: CredentialEventAction }) {
    this.events.push({ action: e.action, userId: e.userId });
    return Promise.resolve();
  }
}

const ring = () => parseKeyring(`k1:${toBase64(new Uint8Array(32).fill(3))}`, "k1");

Deno.test("stores only sealed secrets and reads them back", async () => {
  const table = new MemoryTable();
  const store = new SealedSnapTradeStore(table, await ring());
  await store.save(U1, { snapTradeUserId: `st-${U1}`, userSecret: "the-secret" });
  assertFalse(JSON.stringify(table.rows).includes("the-secret"));
  assertEquals(table.rows[0].kek_id, "k1");
  assertEquals(await store.get(U1), { snapTradeUserId: `st-${U1}`, userSecret: "the-secret" });
  assertEquals(await store.get(U2), null);
  assertEquals(table.events, [{ action: "created", userId: U1 }]);
});

Deno.test("a row reassigned to another user in the database does not decrypt for them", async () => {
  const table = new MemoryTable();
  const store = new SealedSnapTradeStore(table, await ring());
  await store.save(U1, { snapTradeUserId: `st-${U1}`, userSecret: "s" });
  table.rows[0].user_id = U2; // e.g. a mistaken UPDATE or a malicious insert copying the blob
  await assertRejects(() => store.get(U2), EnvelopeError);
});

Deno.test("one SnapTrade identity per person and per SnapTrade user; revoke frees the slot", async () => {
  const table = new MemoryTable();
  const store = new SealedSnapTradeStore(table, await ring());
  await store.save(U1, { snapTradeUserId: "legacy-user", userSecret: "s" });
  await assertRejects(() => store.save(U2, { snapTradeUserId: "legacy-user", userSecret: "s" }), CredentialConflictError);
  await assertRejects(() => store.save(U1, { snapTradeUserId: `st-${U1}`, userSecret: "s2" }), CredentialConflictError);
  await store.remove(U1);
  assertEquals(await store.get(U1), null);
  await store.save(U1, { snapTradeUserId: `st-${U1}`, userSecret: "s2" });
  assertEquals(table.events.map((e) => e.action), ["imported", "revoked", "created"]);
});
