// Envelope encryption for provider credentials (API keys a person connects).
//
//   plaintext ──AES-256-GCM(DEK, aad)──▶ ciphertext         (a fresh 256-bit DEK per secret)
//   DEK       ──AES-256-GCM(KEK, aad)──▶ wrappedDEK          (the KEK never touches the database)
//
// * The KEK lives only in function secrets (BROKER_CREDENTIALS_KEKS), as a key ring so it can
//   be rotated: {"active":"k2","keys":{"k1":"<base64 32 bytes>","k2":"..."}}. In production the
//   ring should be fetched from a KMS at cold start instead of an env var; the interface stays.
// * The additional authenticated data binds a ciphertext to its owner, connection and provider.
//   A sealed blob copied onto another user's row, or another connection, fails to open.
// * Plaintext exists only in function memory for the duration of a provider call. It is never
//   logged, returned to a client, stored in another column, or put in a model prompt.
// * `rewrap` moves a record to the active KEK without the plaintext leaving this module.

export interface SealedSecret {
  v: 1;
  alg: "A256GCM+A256GCMKW";
  kekID: string;
  /** base64 */
  wrappedDEK: string;
  wrapIV: string;
  iv: string;
  ciphertext: string;
}

export interface SecretBinding {
  userID: string;
  connectionID: string;
  provider: string;
}

export interface KeyRing {
  active: string;
  keys: Record<string, CryptoKey>;
}

export class VaultError extends Error {
  constructor(readonly code: "not_configured" | "unknown_key" | "corrupt" | "binding_mismatch", message: string) {
    super(message);
    this.name = "VaultError";
  }
}

const enc = new TextEncoder();
const dec = new TextDecoder();

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function unb64(text: string): Uint8Array<ArrayBuffer> {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function aad(binding: SecretBinding, kekID?: string): Uint8Array<ArrayBuffer> {
  // Fixed field order; ids are lower-cased so a casing difference can't make two bindings.
  const parts = ["st-vault-v1", binding.userID.toLowerCase(), binding.connectionID.toLowerCase(), binding.provider];
  if (kekID !== undefined) parts.push(kekID);
  return enc.encode(parts.join("|"));
}

function importAesKey(raw: Uint8Array<ArrayBuffer>): Promise<CryptoKey> {
  if (raw.length !== 32) throw new VaultError("not_configured", "Each key in the credentials key ring must be 32 bytes.");
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

/** Reads the key ring from the BROKER_CREDENTIALS_KEKS secret. Throws `not_configured` if absent or malformed. */
export async function keyRingFromEnv(read: (name: string) => string | undefined): Promise<KeyRing> {
  const raw = read("BROKER_CREDENTIALS_KEKS");
  if (!raw) throw new VaultError("not_configured", "Credential storage isn't configured on this server.");
  let parsed: { active?: unknown; keys?: unknown };
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new VaultError("not_configured", "The credentials key ring isn't valid JSON.");
  }
  if (typeof parsed.active !== "string" || typeof parsed.keys !== "object" || parsed.keys === null) {
    throw new VaultError("not_configured", "The credentials key ring needs an active key id and keys.");
  }
  const keys: Record<string, CryptoKey> = {};
  for (const [id, value] of Object.entries(parsed.keys as Record<string, unknown>)) {
    if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,32}$/.test(id)) throw new VaultError("not_configured", "Bad key ring entry.");
    keys[id] = await importAesKey(unb64(value));
  }
  if (!keys[parsed.active]) throw new VaultError("not_configured", "The active key isn't in the key ring.");
  return { active: parsed.active, keys };
}

export async function keyRingFromRaw(active: string, rawKeys: Record<string, Uint8Array<ArrayBuffer>>): Promise<KeyRing> {
  const keys: Record<string, CryptoKey> = {};
  for (const [id, raw] of Object.entries(rawKeys)) keys[id] = await importAesKey(raw);
  if (!keys[active]) throw new VaultError("not_configured", "The active key isn't in the key ring.");
  return { active, keys };
}

export async function seal(ring: KeyRing, binding: SecretBinding, secret: Record<string, string>): Promise<SealedSecret> {
  const kek = ring.keys[ring.active];
  const dekRaw = crypto.getRandomValues(new Uint8Array(32));
  const dek = await importAesKey(dekRaw);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const wrapIV = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad(binding) }, dek, enc.encode(JSON.stringify(secret))),
  );
  const wrappedDEK = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: wrapIV, additionalData: aad(binding, ring.active) }, kek, dekRaw));
  dekRaw.fill(0);
  return { v: 1, alg: "A256GCM+A256GCMKW", kekID: ring.active, wrappedDEK: b64(wrappedDEK), wrapIV: b64(wrapIV), iv: b64(iv), ciphertext: b64(ciphertext) };
}

async function unwrapDEK(ring: KeyRing, binding: SecretBinding, sealed: SealedSecret): Promise<Uint8Array<ArrayBuffer>> {
  if (sealed.v !== 1 || sealed.alg !== "A256GCM+A256GCMKW") throw new VaultError("corrupt", "Unknown credential format.");
  const kek = ring.keys[sealed.kekID];
  if (!kek) throw new VaultError("unknown_key", "This credential was sealed with a key that's no longer in the key ring.");
  try {
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(sealed.wrapIV), additionalData: aad(binding, sealed.kekID) }, kek, unb64(sealed.wrappedDEK)));
  } catch {
    // GCM can't tell a wrong binding from tampering; both mean "this isn't yours to open".
    throw new VaultError("binding_mismatch", "This credential doesn't belong to this connection.");
  }
}

export async function open(ring: KeyRing, binding: SecretBinding, sealed: SealedSecret): Promise<Record<string, string>> {
  const dekRaw = await unwrapDEK(ring, binding, sealed);
  const dek = await importAesKey(dekRaw);
  dekRaw.fill(0);
  let plain: ArrayBuffer;
  try {
    plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(sealed.iv), additionalData: aad(binding) }, dek, unb64(sealed.ciphertext));
  } catch {
    throw new VaultError("binding_mismatch", "This credential doesn't belong to this connection.");
  }
  const value = JSON.parse(dec.decode(plain));
  if (typeof value !== "object" || value === null) throw new VaultError("corrupt", "Credential payload is malformed.");
  return value as Record<string, string>;
}

/** Re-seals the DEK under the active KEK (rotation). The secret itself is not decrypted. */
export async function rewrap(ring: KeyRing, binding: SecretBinding, sealed: SealedSecret): Promise<SealedSecret> {
  if (sealed.kekID === ring.active) return sealed;
  const dekRaw = await unwrapDEK(ring, binding, sealed);
  const wrapIV = crypto.getRandomValues(new Uint8Array(12));
  const wrappedDEK = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: wrapIV, additionalData: aad(binding, ring.active) }, ring.keys[ring.active], dekRaw),
  );
  dekRaw.fill(0);
  return { ...sealed, kekID: ring.active, wrappedDEK: b64(wrappedDEK), wrapIV: b64(wrapIV) };
}

/** Last four characters of a key id for display ("…A1B2"). Never more. */
export function keyHint(keyID: string): string {
  const tail = keyID.replace(/\s/g, "").slice(-4);
  return tail.length === 4 ? `…${tail}` : "…";
}
