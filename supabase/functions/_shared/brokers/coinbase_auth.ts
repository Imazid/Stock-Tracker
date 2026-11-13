// Coinbase Developer Platform (CDP) API-key authentication for the Advanced Trade API.
//
// Per docs.cdp.coinbase.com (coinbase-app/authentication-authorization/api-key-authentication,
// checked November 2026): a fresh JWT for EVERY request, signed ES256 (ECDSA P-256; Ed25519
// keys are not supported), sent as `Authorization: Bearer <jwt>`.
//   header  { alg: "ES256", kid: <key name>, nonce: <random hex>, typ: "JWT" }
//   claims  { sub: <key name>, iss: "cdp", nbf: now, exp: now + 120, uri: "<METHOD> <host><path>" }
// The key name is "organizations/{org_id}/apiKeys/{key_id}". The private key is downloaded as a
// SEC1 PEM ("-----BEGIN EC PRIVATE KEY-----"); WebCrypto only imports PKCS#8, so SEC1 is
// re-wrapped here (a few lines of DER, no dependency). The uri claim carries the path without
// the query string, as Coinbase's own SDKs build it.
//
// Nothing here logs, stores or returns the private key.

import { BrokerError } from "./types.ts";

// MARK: - Base64 / base64url

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64url(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const textEncoder = new TextEncoder();

// MARK: - Minimal DER

interface TLV {
  tag: number;
  /** Offset of the value's first byte. */
  start: number;
  /** Offset one past the value's last byte. */
  end: number;
}

function readTLV(bytes: Uint8Array, offset: number): TLV {
  if (offset + 2 > bytes.length) throw new RangeError("truncated DER");
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let start = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 3 || start + count > bytes.length) throw new RangeError("bad DER length");
    length = 0;
    for (let i = 0; i < count; i++) length = (length << 8) | bytes[start + i];
    start += count;
  }
  const end = start + length;
  if (end > bytes.length) throw new RangeError("truncated DER");
  return { tag, start, end };
}

function encodeLength(length: number): Uint8Array {
  if (length < 0x80) return Uint8Array.of(length);
  const out: number[] = [];
  for (let n = length; n > 0; n >>= 8) out.unshift(n & 0xff);
  return Uint8Array.of(0x80 | out.length, ...out);
}

function tlv(tag: number, ...parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((sum, p) => sum + p.length, 0);
  const header = Uint8Array.of(tag, ...encodeLength(length));
  const out = new Uint8Array(header.length + length);
  out.set(header, 0);
  let at = header.length;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

const OID_EC_PUBLIC_KEY = Uint8Array.of(0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01); // 1.2.840.10045.2.1
const OID_P256 = Uint8Array.of(0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07); // 1.2.840.10045.3.1.7

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

/**
 * SEC1 ECPrivateKey (RFC 5915) → PKCS#8 PrivateKeyInfo (RFC 5208) for P-256.
 *   ECPrivateKey ::= SEQUENCE { version INTEGER (1), privateKey OCTET STRING,
 *                               parameters [0] OID OPTIONAL, publicKey [1] BIT STRING OPTIONAL }
 * The curve moves to the AlgorithmIdentifier; the inner key keeps version, key and public key.
 */
export function sec1ToPkcs8(sec1: Uint8Array): Uint8Array {
  const outer = readTLV(sec1, 0);
  if (outer.tag !== 0x30) throw new RangeError("not a SEC1 key");
  const version = readTLV(sec1, outer.start);
  if (version.tag !== 0x02 || version.end - version.start !== 1 || sec1[version.start] !== 1) throw new RangeError("unsupported SEC1 version");
  const privateKey = readTLV(sec1, version.end);
  if (privateKey.tag !== 0x04) throw new RangeError("SEC1 private key missing");
  let publicKey: Uint8Array | undefined;
  for (let at = privateKey.end; at < outer.end;) {
    const field = readTLV(sec1, at);
    if (field.tag === 0xa0) {
      const oid = sec1.slice(field.start, field.end);
      if (!equalBytes(oid, OID_P256)) throw new BrokerError("invalid_request", "Coinbase keys must be ECDSA P-256 (ES256); this key uses another curve.");
    } else if (field.tag === 0xa1) {
      publicKey = sec1.slice(at, field.end);
    }
    at = field.end;
  }
  const inner = tlv(
    0x30,
    Uint8Array.of(0x02, 0x01, 0x01),
    sec1.slice(version.end, privateKey.end),
    ...(publicKey ? [publicKey] : []),
  );
  return tlv(0x30, Uint8Array.of(0x02, 0x01, 0x00), tlv(0x30, OID_EC_PUBLIC_KEY, OID_P256), tlv(0x04, inner));
}

/** PEM (SEC1 or PKCS#8, real or "\n"-escaped newlines) → PKCS#8 DER. */
export function pemToPkcs8(pem: string): Uint8Array {
  const text = pem.replace(/\\n/g, "\n").trim();
  const match = text.match(/-----BEGIN ([A-Z ]+)-----([\s\S]*?)-----END \1-----/);
  if (!match) throw new BrokerError("invalid_request", "The Coinbase private key isn't a PEM block.");
  const label = match[1];
  let der: Uint8Array;
  try {
    der = base64ToBytes(match[2].replace(/\s+/g, ""));
  } catch {
    throw new BrokerError("invalid_request", "The Coinbase private key isn't valid base64.");
  }
  if (label === "PRIVATE KEY") return der;
  if (label === "EC PRIVATE KEY") {
    try {
      return sec1ToPkcs8(der);
    } catch (error) {
      if (error instanceof BrokerError) throw error;
      throw new BrokerError("invalid_request", "The Coinbase private key couldn't be read.");
    }
  }
  throw new BrokerError("invalid_request", `Unsupported key type "${label}": Coinbase keys must be ECDSA (ES256).`);
}

export async function importSigningKey(privateKeyPEM: string): Promise<CryptoKey> {
  const der = pemToPkcs8(privateKeyPEM);
  try {
    return await crypto.subtle.importKey("pkcs8", new Uint8Array(der), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  } catch {
    throw new BrokerError("invalid_request", "The Coinbase private key couldn't be imported: it must be an ECDSA P-256 (ES256) key. Ed25519 keys aren't supported by Coinbase.");
  }
}

function randomHex(bytes: number): string {
  const buffer = new Uint8Array(bytes);
  crypto.getRandomValues(buffer);
  return Array.from(buffer, (b) => b.toString(16).padStart(2, "0")).join("");
}

export interface JWTInput {
  keyName: string;
  key: CryptoKey;
  method: string;
  /** "api.coinbase.com" */
  host: string;
  /** "/api/v3/brokerage/orders" — no query string. */
  path: string;
  nowMs: number;
  /** Injected for tests; random 16 bytes of hex otherwise. */
  nonce?: string;
}

/** A signed ES256 JWT for one request. WebCrypto's ECDSA signature is already JOSE's raw r‖s. */
export async function buildJWT(input: JWTInput): Promise<string> {
  const nbf = Math.floor(input.nowMs / 1000);
  const header = { alg: "ES256", kid: input.keyName, nonce: input.nonce ?? randomHex(16), typ: "JWT" };
  const claims = { sub: input.keyName, iss: "cdp", nbf, exp: nbf + 120, uri: `${input.method} ${input.host}${input.path}` };
  const signingInput = `${base64url(textEncoder.encode(JSON.stringify(header)))}.${base64url(textEncoder.encode(JSON.stringify(claims)))}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, input.key, textEncoder.encode(signingInput)));
  return `${signingInput}.${base64url(signature)}`;
}
