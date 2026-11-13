// Server-side SnapTrade gateway.
//
// Before this, the iOS app held SnapTrade's consumer key (which signs requests for EVERY
// user of the client id) and each user's userSecret in the bundle/Keychain. Anyone who
// unpacked the app could act as any user. Now:
//
//   * the consumer key lives only in Edge Function secrets and signs here;
//   * each user's SnapTrade userSecret is sealed with envelope encryption server-side and
//     is never returned to a device (responses are scrubbed of any `userSecret` field);
//   * the SnapTrade user is bound to the signed-in Supabase user — a device cannot name
//     another person's SnapTrade user;
//   * only a fixed list of operations exists (no user listing, no trading, no transfers),
//     and connection portals default to read-only.

import { canonicalJson, fromUtf8, toBase64, utf8 } from "../secure/encoding.ts";

export const SNAPTRADE_DEFAULT_BASE = "https://api.snaptrade.com";
const API_PREFIX = "/api/v1";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BROKER_SLUG = /^[A-Za-z0-9_-]{1,40}$/;
const LEGACY_USER_ID = /^[A-Za-z0-9@._-]{1,100}$/;

export type SnapTradeOperation =
  | "status"
  | "registerUser"
  | "importLegacyUser"
  | "loginLink"
  | "listBrokerages"
  | "listAuthorizations"
  | "listAccounts"
  | "accountPositions"
  | "accountHoldings"
  | "deleteUser";

export const SNAPTRADE_OPERATIONS: readonly SnapTradeOperation[] = [
  "status",
  "registerUser",
  "importLegacyUser",
  "loginLink",
  "listBrokerages",
  "listAuthorizations",
  "listAccounts",
  "accountPositions",
  "accountHoldings",
  "deleteUser",
];

export interface SnapTradeUserRecord {
  snapTradeUserId: string;
  userSecret: string;
}

/** Persistence for each person's SnapTrade identity. Implementations seal `userSecret`. */
export interface SnapTradeUserStore {
  get(userId: string): Promise<SnapTradeUserRecord | null>;
  save(userId: string, record: SnapTradeUserRecord): Promise<void>;
  remove(userId: string): Promise<void>;
}

export interface SnapTradeProxyConfig {
  clientId: string;
  consumerKey: string;
  baseUrl?: string;
  /** Off by default: connection portals open read-only. Trading connections need a deliberate server change. */
  allowTradeConnections?: boolean;
  /** Redirect targets the portal may return to. Anything else is refused. */
  redirectPrefixes?: readonly string[];
  timeoutMs?: number;
}

export interface SnapTradeProxyDeps {
  config: SnapTradeProxyConfig;
  store: SnapTradeUserStore;
  fetch: typeof fetch;
  /** Milliseconds since the epoch. */
  now: () => number;
}

export interface ProxyResponse {
  status: number;
  body: unknown;
}

export function snapTradeUserIdFor(userId: string): string {
  return `st-${userId.toLowerCase()}`;
}

/** Signs and builds a SnapTrade request exactly as SnapTrade verifies it. */
export async function buildSignedRequest(
  config: SnapTradeProxyConfig,
  method: "GET" | "POST" | "DELETE",
  path: string,
  query: Record<string, string>,
  body: Record<string, unknown> | null,
  nowMs: number,
): Promise<{ url: string; init: RequestInit }> {
  const fullPath = `${API_PREFIX}${path}`;
  const params: Record<string, string> = { ...query, clientId: config.clientId, timestamp: String(Math.floor(nowMs / 1000)) };
  const queryString = Object.keys(params)
    .sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`)
    .join("&");
  const content = body && Object.keys(body).length > 0 ? body : null;
  const signature = await hmacSha256Base64(
    config.consumerKey,
    canonicalJson({ content, path: fullPath, query: queryString }),
  );
  const headers: Record<string, string> = { "Signature": signature, "Accept": "application/json" };
  const init: RequestInit = { method, headers };
  if (content) {
    headers["Content-Type"] = "application/json";
    init.body = canonicalJson(content);
  }
  return { url: `${config.baseUrl ?? SNAPTRADE_DEFAULT_BASE}${fullPath}?${queryString}`, init };
}

export async function hmacSha256Base64(key: string, message: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey("raw", utf8(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toBase64(new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, utf8(message))));
}

/** Handles one request from a signed-in user. `userId` comes from the verified JWT, never the body. */
export async function handleSnapTradeRequest(userId: string, input: unknown, deps: SnapTradeProxyDeps): Promise<ProxyResponse> {
  if (!UUID.test(userId)) return fail(401, "UNAUTHENTICATED", "no signed-in user");
  if (!deps.config.clientId || !deps.config.consumerKey) {
    return fail(503, "SNAPTRADE_NOT_CONFIGURED", "SnapTrade is not configured on the server");
  }
  if (!isRecord(input)) return fail(400, "INVALID_REQUEST", "body must be a JSON object");
  const operation = input.operation;
  if (typeof operation !== "string" || !SNAPTRADE_OPERATIONS.includes(operation as SnapTradeOperation)) {
    return fail(400, "UNKNOWN_OPERATION", "operation is not supported");
  }
  const params = isRecord(input.params) ? input.params : {};

  switch (operation as SnapTradeOperation) {
    case "status": {
      const record = await deps.store.get(userId);
      return { status: 200, body: { registered: record !== null } };
    }
    case "registerUser":
      return registerUser(userId, deps);
    case "importLegacyUser":
      return importLegacyUser(userId, params, deps);
    case "listBrokerages":
      return forward(deps, "GET", "/brokerages", {}, null);
    case "loginLink": {
      const body = loginBody(params, deps.config);
      if ("error" in body) return body.error;
      return withUser(userId, deps, (u) => forward(deps, "POST", "/snapTrade/login", u, body.value));
    }
    case "listAuthorizations":
      return withUser(userId, deps, (u) => forward(deps, "GET", "/authorizations", u, null));
    case "listAccounts":
      return withUser(userId, deps, (u) => forward(deps, "GET", "/accounts", u, null));
    case "accountPositions":
    case "accountHoldings": {
      const accountId = params.accountId;
      if (typeof accountId !== "string" || !UUID.test(accountId)) {
        return fail(400, "INVALID_ACCOUNT_ID", "accountId must be a SnapTrade account UUID");
      }
      const suffix = operation === "accountPositions" ? "positions" : "holdings";
      return withUser(userId, deps, (u) => forward(deps, "GET", `/accounts/${accountId}/${suffix}`, u, null));
    }
    case "deleteUser":
      return withUser(userId, deps, async (u) => {
        const result = await forward(deps, "DELETE", "/snapTrade/deleteUser", { userId: u.userId }, null);
        if (result.status >= 200 && result.status < 300) await deps.store.remove(userId);
        return result;
      });
  }
}

async function registerUser(userId: string, deps: SnapTradeProxyDeps): Promise<ProxyResponse> {
  if (await deps.store.get(userId)) return { status: 200, body: { registered: true, created: false } };
  const snapTradeUserId = snapTradeUserIdFor(userId);
  const upstream = await call(deps, "POST", "/snapTrade/registerUser", {}, { userId: snapTradeUserId });
  if ("error" in upstream) return upstream.error;
  const secret = isRecord(upstream.json) ? upstream.json.userSecret : undefined;
  if (typeof secret !== "string" || !secret) {
    return fail(502, "SNAPTRADE_UPSTREAM", "SnapTrade did not return a user secret");
  }
  await deps.store.save(userId, { snapTradeUserId, userSecret: secret });
  return { status: 201, body: { registered: true, created: true } };
}

/**
 * One-time move of a SnapTrade identity that an older app version kept in the iOS Keychain.
 * The pair is proven by a real authenticated SnapTrade call before it is stored, then the
 * device deletes its copy. The database enforces that one SnapTrade user maps to one person.
 */
async function importLegacyUser(userId: string, params: Record<string, unknown>, deps: SnapTradeProxyDeps): Promise<ProxyResponse> {
  if (await deps.store.get(userId)) return fail(409, "ALREADY_REGISTERED", "a SnapTrade identity is already stored for this account");
  const legacyUserId = params.snapTradeUserId;
  const legacySecret = params.userSecret;
  if (typeof legacyUserId !== "string" || !LEGACY_USER_ID.test(legacyUserId) ||
      typeof legacySecret !== "string" || legacySecret.length < 8 || legacySecret.length > 200) {
    return fail(400, "INVALID_LEGACY_CREDENTIALS", "snapTradeUserId and userSecret are required");
  }
  const probe = await call(deps, "GET", "/authorizations", { userId: legacyUserId, userSecret: legacySecret }, null);
  if ("error" in probe) {
    return probe.error.status === 401 || probe.error.status === 403 || probe.error.status === 400
      ? fail(422, "LEGACY_CREDENTIALS_REJECTED", "SnapTrade did not accept these credentials")
      : probe.error;
  }
  await deps.store.save(userId, { snapTradeUserId: legacyUserId, userSecret: legacySecret });
  return { status: 201, body: { registered: true, imported: true } };
}

function loginBody(
  params: Record<string, unknown>,
  config: SnapTradeProxyConfig,
): { value: Record<string, unknown> } | { error: ProxyResponse } {
  const body: Record<string, unknown> = {};
  const requested = params.connectionType ?? "read";
  if (requested !== "read" && requested !== "trade") {
    return { error: fail(400, "INVALID_CONNECTION_TYPE", "connectionType must be read or trade") };
  }
  if (requested === "trade" && !config.allowTradeConnections) {
    return { error: fail(403, "TRADE_CONNECTIONS_DISABLED", "trading connections are not enabled on this server") };
  }
  body.connectionType = requested;
  if (params.broker !== undefined) {
    if (typeof params.broker !== "string" || !BROKER_SLUG.test(params.broker)) {
      return { error: fail(400, "INVALID_BROKER", "broker must be a SnapTrade brokerage slug") };
    }
    body.broker = params.broker;
  }
  if (params.reconnect !== undefined) {
    if (typeof params.reconnect !== "string" || !UUID.test(params.reconnect)) {
      return { error: fail(400, "INVALID_RECONNECT", "reconnect must be an authorization UUID") };
    }
    body.reconnect = params.reconnect;
  }
  if (params.immediateRedirect !== undefined) {
    if (typeof params.immediateRedirect !== "boolean") {
      return { error: fail(400, "INVALID_REQUEST", "immediateRedirect must be a boolean") };
    }
    body.immediateRedirect = params.immediateRedirect;
  }
  if (params.customRedirect !== undefined) {
    const prefixes = config.redirectPrefixes ?? ["stocktracker://"];
    if (typeof params.customRedirect !== "string" || params.customRedirect.length > 300 ||
        !prefixes.some((p) => (params.customRedirect as string).startsWith(p))) {
      return { error: fail(400, "INVALID_REDIRECT", "customRedirect is not an allowed redirect target") };
    }
    body.customRedirect = params.customRedirect;
  }
  return { value: body };
}

async function withUser(
  userId: string,
  deps: SnapTradeProxyDeps,
  run: (user: { userId: string; userSecret: string }) => Promise<ProxyResponse>,
): Promise<ProxyResponse> {
  const record = await deps.store.get(userId);
  if (!record) return fail(409, "NOT_REGISTERED", "register with SnapTrade first (operation registerUser)");
  return run({ userId: record.snapTradeUserId, userSecret: record.userSecret });
}

async function forward(
  deps: SnapTradeProxyDeps,
  method: "GET" | "POST" | "DELETE",
  path: string,
  query: Record<string, string>,
  body: Record<string, unknown> | null,
): Promise<ProxyResponse> {
  const result = await call(deps, method, path, query, body);
  if ("error" in result) return result.error;
  return { status: result.status, body: scrubSecrets(result.json) };
}

async function call(
  deps: SnapTradeProxyDeps,
  method: "GET" | "POST" | "DELETE",
  path: string,
  query: Record<string, string>,
  body: Record<string, unknown> | null,
): Promise<{ status: number; json: unknown } | { error: ProxyResponse }> {
  const { url, init } = await buildSignedRequest(deps.config, method, path, query, body, deps.now());
  let response: Response;
  try {
    response = await deps.fetch(url, { ...init, signal: AbortSignal.timeout(deps.config.timeoutMs ?? 15_000) });
  } catch {
    return { error: fail(504, "SNAPTRADE_UNAVAILABLE", "SnapTrade did not respond") };
  }
  const text = fromUtf8(new Uint8Array(await response.arrayBuffer()));
  let json: unknown = null;
  if (text) {
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
  }
  if (!response.ok) {
    const detail = isRecord(json) ? (json.detail ?? json.message ?? json.error) : undefined;
    return {
      error: {
        status: response.status >= 500 ? 502 : response.status,
        body: {
          error: {
            code: "SNAPTRADE_UPSTREAM",
            upstreamStatus: response.status,
            upstreamCode: isRecord(json) && json.code !== undefined ? String(json.code) : undefined,
            message: typeof detail === "string" ? redact(detail).slice(0, 300) : "SnapTrade returned an error",
          },
        },
      },
    };
  }
  return { status: response.status, json };
}

/** Removes every `userSecret` field, at any depth, from what goes back to a device. */
export function scrubSecrets(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(scrubSecrets);
  if (isRecord(value)) {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      if (k.toLowerCase() === "usersecret") continue;
      out[k] = scrubSecrets(v);
    }
    return out;
  }
  return value;
}

function redact(text: string): string {
  return text.replace(/userSecret=[^&\s"]+/gi, "userSecret=[redacted]");
}

function fail(status: number, code: string, message: string): ProxyResponse {
  return { status, body: { error: { code, message } } };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
