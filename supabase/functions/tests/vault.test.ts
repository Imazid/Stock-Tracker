// Envelope encryption for provider credentials.
// Run: npx -y deno test --allow-read supabase/functions/tests/vault.test.ts

import { assert, assertEquals, assertNotEquals, assertRejects } from "jsr:@std/assert@1";
import { keyHint, keyRingFromEnv, keyRingFromRaw, open, rewrap, seal, VaultError } from "../_shared/vault/envelope.ts";

const raw = (fill: number) => new Uint8Array(32).fill(fill);
const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const binding = { userID: "11111111-1111-4111-8111-111111111111", connectionID: "33333333-3333-4333-8333-333333333333", provider: "alpaca" };
const secret = { keyID: "PKTEST1234ABCD", secretKey: "very-secret-value" };

Deno.test("vault: round trip, and the ciphertext reveals nothing", async () => {
  const ring = await keyRingFromRaw("k1", { k1: raw(1) });
  const sealed = await seal(ring, binding, secret);
  assertEquals(sealed.kekID, "k1");
  const json = JSON.stringify(sealed);
  assert(!json.includes("very-secret-value") && !json.includes("PKTEST"));
  assertEquals(await open(ring, binding, sealed), secret);
  // Fresh DEK and IV each time.
  const again = await seal(ring, binding, secret);
  assertNotEquals(again.ciphertext, sealed.ciphertext);
  assertNotEquals(again.wrappedDEK, sealed.wrappedDEK);
});

Deno.test("vault: a sealed blob moved to another user or connection won't open", async () => {
  const ring = await keyRingFromRaw("k1", { k1: raw(1) });
  const sealed = await seal(ring, binding, secret);
  for (const other of [{ ...binding, userID: "22222222-2222-4222-8222-222222222222" }, { ...binding, connectionID: "44444444-4444-4444-8444-444444444444" }, { ...binding, provider: "coinbase" }]) {
    await assertRejects(() => open(ring, other, sealed), VaultError);
  }
  // Same ids in another case are the same binding.
  assertEquals(await open(ring, { ...binding, userID: binding.userID.toUpperCase() }, sealed), secret);
});

Deno.test("vault: tampering is detected", async () => {
  const ring = await keyRingFromRaw("k1", { k1: raw(1) });
  const sealed = await seal(ring, binding, secret);
  const bytes = Uint8Array.from(atob(sealed.ciphertext), (c) => c.charCodeAt(0));
  bytes[0] ^= 1;
  await assertRejects(() => open(ring, binding, { ...sealed, ciphertext: b64(bytes) }), VaultError);
  await assertRejects(() => open(ring, binding, { ...sealed, kekID: "k9" }), VaultError);
});

Deno.test("vault: rotation rewraps without touching the secret; old key can then be retired", async () => {
  const old = await keyRingFromRaw("k1", { k1: raw(1) });
  const sealed = await seal(old, binding, secret);
  const both = await keyRingFromRaw("k2", { k1: raw(1), k2: raw(2) });
  const moved = await rewrap(both, binding, sealed);
  assertEquals(moved.kekID, "k2");
  assertEquals(moved.ciphertext, sealed.ciphertext);
  const onlyNew = await keyRingFromRaw("k2", { k2: raw(2) });
  assertEquals(await open(onlyNew, binding, moved), secret);
  await assertRejects(() => open(onlyNew, binding, sealed), VaultError);
});

Deno.test("vault: key ring from the environment", async () => {
  const env = { BROKER_CREDENTIALS_KEKS: JSON.stringify({ active: "k1", keys: { k1: b64(raw(7)) } }) } as Record<string, string>;
  const ring = await keyRingFromEnv((n) => env[n]);
  assertEquals(ring.active, "k1");
  await assertRejects(() => keyRingFromEnv(() => undefined), VaultError);
  await assertRejects(() => keyRingFromEnv(() => JSON.stringify({ active: "k1", keys: { k1: b64(new Uint8Array(16)) } })), VaultError);
  await assertRejects(() => keyRingFromEnv(() => JSON.stringify({ active: "k2", keys: { k1: b64(raw(7)) } })), VaultError);
  assertEquals(keyHint("PKTEST1234ABCD"), "…ABCD");
  assertEquals(keyHint("ab"), "…");
});
