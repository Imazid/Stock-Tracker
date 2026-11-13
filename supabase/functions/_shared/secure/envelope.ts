// Envelope encryption for per-user credentials (SnapTrade user secrets, brokerage API keys).
//
// Each secret gets its own random 256-bit data key (DEK). The secret is sealed with the DEK
// (AES-256-GCM), and the DEK is sealed with a key-encryption key (KEK, AES-256-GCM) held
// only as an Edge Function secret — never in the database, never on a device.
//
// What a row in `secure_credentials` holds is useless without the KEK. Both layers carry
// associated data (AAD) that binds the ciphertext to its owner and purpose, so a sealed
// value copied onto another user's row (or another purpose) fails to open instead of
// decrypting under the wrong identity.
//
// KEK rotation: add the new key to the keyring, make it active, and call `rewrap` on each
// row. Only the small wrapped DEK changes; the secret itself is never decrypted in bulk.

import { type Bytes, fromBase64, fromUtf8, toBase64, utf8 } from "./encoding.ts";

export const ENVELOPE_VERSION = 1;
export const ENVELOPE_ALGORITHM = "A256GCM+A256GCMKW";

export interface SealedSecret {
  v: 1;
  alg: typeof ENVELOPE_ALGORITHM;
  /** Which KEK wrapped the data key. */
  kid: string;
  /** The data key, sealed with the KEK. */
  wrappedDek: string;
  dekIv: string;
  /** The secret, sealed with the data key. */
  iv: string;
  ciphertext: string;
}

export interface Keyring {
  activeKid: string;
  keys: ReadonlyMap<string, CryptoKey>;
}

export class EnvelopeError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = "EnvelopeError";
    this.code = code;
  }
}

const KID_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;

/**
 * Builds a keyring from configuration of the form `kid1:BASE64KEY,kid2:BASE64KEY`.
 * Every key must be exactly 32 bytes. `activeKid` names the key new seals use; older keys
 * stay so existing rows can still be opened (and rewrapped).
 */
export async function parseKeyring(spec: string | undefined, activeKid: string | undefined): Promise<Keyring> {
  if (!spec || !spec.trim()) {
    throw new EnvelopeError("KEYRING_MISSING", "CREDENTIAL_KEKS is not configured");
  }
  const keys = new Map<string, CryptoKey>();
  for (const entry of spec.split(",")) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const sep = trimmed.indexOf(":");
    if (sep <= 0) throw new EnvelopeError("KEYRING_INVALID", "each keyring entry must be kid:base64key");
    const kid = trimmed.slice(0, sep);
    if (!KID_PATTERN.test(kid)) throw new EnvelopeError("KEYRING_INVALID", "key ids must be 1-32 of [A-Za-z0-9_-]");
    if (keys.has(kid)) throw new EnvelopeError("KEYRING_INVALID", `duplicate key id ${kid}`);
    let raw: Bytes;
    try {
      raw = fromBase64(trimmed.slice(sep + 1));
    } catch {
      throw new EnvelopeError("KEYRING_INVALID", `key ${kid} is not valid base64`);
    }
    if (raw.length !== 32) throw new EnvelopeError("KEYRING_INVALID", `key ${kid} must be 32 bytes, got ${raw.length}`);
    keys.set(kid, await importAesKey(raw));
    raw.fill(0);
  }
  const active = activeKid ?? (keys.size === 1 ? [...keys.keys()][0] : undefined);
  if (!active || !keys.has(active)) {
    throw new EnvelopeError("KEYRING_INVALID", "CREDENTIAL_ACTIVE_KEK must name a key in CREDENTIAL_KEKS");
  }
  return { activeKid: active, keys };
}

/** Seals `plaintext` for the given context (e.g. `snaptrade_user:<user uuid>`). */
export async function seal(keyring: Keyring, plaintext: string, context: string): Promise<SealedSecret> {
  assertContext(context);
  const kek = keyring.keys.get(keyring.activeKid);
  if (!kek) throw new EnvelopeError("KEYRING_INVALID", "active key missing");

  const dekBytes = crypto.getRandomValues(new Uint8Array(32));
  const dek = await importAesKey(dekBytes);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: dataAad(context) }, dek, utf8(plaintext)),
  );

  const dekIv = crypto.getRandomValues(new Uint8Array(12));
  const wrapped = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: dekIv, additionalData: wrapAad(keyring.activeKid, context) },
      kek,
      dekBytes,
    ),
  );
  dekBytes.fill(0);

  return {
    v: ENVELOPE_VERSION,
    alg: ENVELOPE_ALGORITHM,
    kid: keyring.activeKid,
    wrappedDek: toBase64(wrapped),
    dekIv: toBase64(dekIv),
    iv: toBase64(iv),
    ciphertext: toBase64(ciphertext),
  };
}

/** Opens a sealed secret. Throws `EnvelopeError` on any tampering, wrong context or unknown key. */
export async function open(keyring: Keyring, sealed: SealedSecret, context: string): Promise<string> {
  assertContext(context);
  assertShape(sealed);
  const dekBytes = await unwrapDek(keyring, sealed, context);
  try {
    const dek = await importAesKey(dekBytes);
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: fromBase64(sealed.iv), additionalData: dataAad(context) },
      dek,
      fromBase64(sealed.ciphertext),
    );
    return fromUtf8(new Uint8Array(plain));
  } catch {
    throw new EnvelopeError("ENVELOPE_INVALID", "sealed secret failed authentication");
  } finally {
    dekBytes.fill(0);
  }
}

/** Re-seals the data key under the keyring's active KEK. The secret itself is untouched. */
export async function rewrap(keyring: Keyring, sealed: SealedSecret, context: string): Promise<SealedSecret> {
  assertContext(context);
  assertShape(sealed);
  if (sealed.kid === keyring.activeKid) return sealed;
  const kek = keyring.keys.get(keyring.activeKid);
  if (!kek) throw new EnvelopeError("KEYRING_INVALID", "active key missing");
  const dekBytes = await unwrapDek(keyring, sealed, context);
  try {
    const dekIv = crypto.getRandomValues(new Uint8Array(12));
    const wrapped = new Uint8Array(
      await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: dekIv, additionalData: wrapAad(keyring.activeKid, context) },
        kek,
        dekBytes,
      ),
    );
    return { ...sealed, kid: keyring.activeKid, wrappedDek: toBase64(wrapped), dekIv: toBase64(dekIv) };
  } finally {
    dekBytes.fill(0);
  }
}

/** Random KEK material for operators: `deno eval` this to mint a new keyring entry. */
export function generateKekBase64(): string {
  return toBase64(crypto.getRandomValues(new Uint8Array(32)));
}

async function unwrapDek(keyring: Keyring, sealed: SealedSecret, context: string): Promise<Bytes> {
  const kek = keyring.keys.get(sealed.kid);
  if (!kek) throw new EnvelopeError("KEK_UNKNOWN", `no key ${sealed.kid} in the keyring`);
  try {
    const raw = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: fromBase64(sealed.dekIv), additionalData: wrapAad(sealed.kid, context) },
      kek,
      fromBase64(sealed.wrappedDek),
    );
    const bytes = new Uint8Array(raw);
    if (bytes.length !== 32) throw new Error("bad dek length");
    return bytes;
  } catch {
    throw new EnvelopeError("ENVELOPE_INVALID", "sealed secret failed authentication");
  }
}

function importAesKey(raw: Bytes): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

function dataAad(context: string): Bytes {
  return utf8(`st-credential:v1:data:${context}`);
}

function wrapAad(kid: string, context: string): Bytes {
  return utf8(`st-credential:v1:dek:${kid}:${context}`);
}

function assertContext(context: string): void {
  if (!context || context.length > 200 || !/^[A-Za-z0-9_:.-]+$/.test(context)) {
    throw new EnvelopeError("CONTEXT_INVALID", "context must be 1-200 of [A-Za-z0-9_:.-]");
  }
}

function assertShape(sealed: SealedSecret): void {
  const ok = sealed && sealed.v === ENVELOPE_VERSION && sealed.alg === ENVELOPE_ALGORITHM &&
    typeof sealed.kid === "string" && typeof sealed.wrappedDek === "string" &&
    typeof sealed.dekIv === "string" && typeof sealed.iv === "string" && typeof sealed.ciphertext === "string";
  if (!ok) throw new EnvelopeError("ENVELOPE_INVALID", "not a sealed secret");
}
