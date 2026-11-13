// Envelope encryption for stored credentials.
//
//   npx -y deno test --no-check=remote supabase/functions/tests/secure_envelope.test.ts

import { assert, assertEquals, assertNotEquals, assertRejects } from "jsr:@std/assert@1";
import { EnvelopeError, generateKekBase64, open, parseKeyring, rewrap, seal } from "../_shared/secure/envelope.ts";
import { canonicalJson, fromBase64, toBase64 } from "../_shared/secure/encoding.ts";

const KEY_A = toBase64(new Uint8Array(32).fill(7));
const KEY_B = toBase64(new Uint8Array(32).fill(9));

Deno.test("seal then open round-trips, and each seal is fresh", async () => {
  const ring = await parseKeyring(`a:${KEY_A}`, undefined);
  const s1 = await seal(ring, "user-secret-ü-🔑", "snaptrade_user:11111111-1111-1111-1111-111111111111");
  const s2 = await seal(ring, "user-secret-ü-🔑", "snaptrade_user:11111111-1111-1111-1111-111111111111");
  assertEquals(await open(ring, s1, "snaptrade_user:11111111-1111-1111-1111-111111111111"), "user-secret-ü-🔑");
  assertNotEquals(s1.ciphertext, s2.ciphertext, "a new data key and IV every time");
  assertNotEquals(s1.wrappedDek, s2.wrappedDek);
  assertEquals(s1.kid, "a");
  assert(!JSON.stringify(s1).includes("user-secret"), "plaintext never appears in the sealed form");
});

Deno.test("a sealed value moved to another user or purpose does not open", async () => {
  const ring = await parseKeyring(`a:${KEY_A}`, "a");
  const sealed = await seal(ring, "secret", "snaptrade_user:user-1");
  const err = await assertRejects(() => open(ring, sealed, "snaptrade_user:user-2"), EnvelopeError);
  assertEquals(err.code, "ENVELOPE_INVALID");
  await assertRejects(() => open(ring, sealed, "broker_api_key:user-1"), EnvelopeError);
});

Deno.test("any tampering with ciphertext, wrapped key, IVs or key id is detected", async () => {
  const ring = await parseKeyring(`a:${KEY_A},b:${KEY_B}`, "a");
  const sealed = await seal(ring, "secret", "ctx:1");
  const flip = (b64: string) => {
    const bytes = fromBase64(b64);
    bytes[0] ^= 1;
    return toBase64(bytes);
  };
  for (const field of ["ciphertext", "wrappedDek", "iv", "dekIv"] as const) {
    await assertRejects(() => open(ring, { ...sealed, [field]: flip(sealed[field]) }, "ctx:1"), EnvelopeError);
  }
  // Claiming the other (valid) key wrapped it must fail too: the key id is in the AAD.
  await assertRejects(() => open(ring, { ...sealed, kid: "b" }, "ctx:1"), EnvelopeError);
});

Deno.test("KEK rotation: rewrap moves rows to the new key without changing the secret", async () => {
  const oldRing = await parseKeyring(`a:${KEY_A}`, "a");
  const sealed = await seal(oldRing, "secret", "ctx:1");
  const rotated = await parseKeyring(`a:${KEY_A},b:${KEY_B}`, "b");
  assertEquals(await open(rotated, sealed, "ctx:1"), "secret", "old rows still open during rotation");
  const moved = await rewrap(rotated, sealed, "ctx:1");
  assertEquals(moved.kid, "b");
  assertEquals(moved.ciphertext, sealed.ciphertext, "the secret's ciphertext is untouched");
  const newOnly = await parseKeyring(`b:${KEY_B}`, "b");
  assertEquals(await open(newOnly, moved, "ctx:1"), "secret", "old key can be retired after rewrap");
  const err = await assertRejects(() => open(newOnly, sealed, "ctx:1"), EnvelopeError);
  assertEquals(err.code, "KEK_UNKNOWN");
});

Deno.test("keyring configuration is validated", async () => {
  for (const [spec, active] of [
    [undefined, undefined],
    ["", undefined],
    ["nokid", undefined],
    [`a:${toBase64(new Uint8Array(16))}`, undefined],
    [`a:${KEY_A},a:${KEY_B}`, "a"],
    [`a:${KEY_A},b:${KEY_B}`, undefined],
    [`a:${KEY_A}`, "z"],
    [`bad kid:${KEY_A}`, undefined],
  ] as const) {
    await assertRejects(() => parseKeyring(spec, active), EnvelopeError);
  }
  assertEquals(fromBase64(generateKekBase64()).length, 32);
});

Deno.test("contexts are restricted to a safe alphabet", async () => {
  const ring = await parseKeyring(`a:${KEY_A}`, undefined);
  await assertRejects(() => seal(ring, "x", ""), EnvelopeError);
  await assertRejects(() => seal(ring, "x", "has space"), EnvelopeError);
});

Deno.test("canonicalJson matches Python's sort_keys + compact separators + ensure_ascii", () => {
  assertEquals(
    canonicalJson({ path: "/api/v1/x", content: { b: 1, a: [{ d: null, c: "é" }] }, query: "a=1&b=2" }),
    '{"content":{"a":[{"c":"\\u00e9","d":null}],"b":1},"path":"/api/v1/x","query":"a=1&b=2"}',
  );
  assertEquals(canonicalJson({ content: null }), '{"content":null}');
  assertEquals(canonicalJson({ text: "two words" }), '{"text":"two words"}', "spaces inside values are kept");
});
