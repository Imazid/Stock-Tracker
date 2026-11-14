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
import { activityPageSize, activityTypes, normalizeActivityPage, protectCachedCashFlows, stockTransferActivityTypes, validActivityDay } from "./activities.ts";

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
  | "accountAllPositions"
  | "accountPositions"
  | "accountHoldings"
  | "accountActivities"
  | "portfolioCash"
  | "deleteUser";

export const SNAPTRADE_OPERATIONS: readonly SnapTradeOperation[] = [
  "status",
  "registerUser",
  "importLegacyUser",
  "loginLink",
  "listBrokerages",
  "listAuthorizations",
  "listAccounts",
  "accountAllPositions",
  "accountPositions",
  "accountHoldings",
  "accountActivities",
  "portfolioCash",
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
  readActivityCache?: (userId: string, request: {
    accountId: string;
    startDate: string;
    endDate: string;
    offset: number;
    snapshot: string | null;
  }) => Promise<unknown>;
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
  prefix = API_PREFIX,
): Promise<{ url: string; init: RequestInit }> {
  const fullPath = `${prefix}${path}`;
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
      return listInvestmentAccounts(userId, deps);
    case "accountAllPositions":
    case "accountPositions":
    case "accountHoldings": {
      const accountId = params.accountId;
      if (typeof accountId !== "string" || !UUID.test(accountId)) {
        return fail(400, "INVALID_ACCOUNT_ID", "accountId must be a SnapTrade account UUID");
      }
      return withUser(userId, deps, (u) => {
        if (operation === "accountAllPositions") {
          return forward(deps, "GET", `/accounts/${accountId}/positions/all`, u, null, "");
        }
        // Older releases still expect the legacy response shapes.
        const suffix = operation === "accountPositions" ? "positions" : "holdings";
        return forward(deps, "GET", `/accounts/${accountId}/${suffix}`, u, null);
      });
    }
    case "portfolioCash":
      return portfolioCash(userId, deps);
    case "accountActivities": {
      const { accountId, startDate, endDate, offset = 0 } = params;
      if (typeof accountId !== "string" || !UUID.test(accountId)) {
        return fail(400, "INVALID_ACCOUNT_ID", "Select a linked brokerage account.");
      }
      if (!validActivityDay(startDate) || !validActivityDay(endDate) || startDate > endDate) {
        return fail(400, "INVALID_ACTIVITY_DATES", "Enter a valid activity date range.");
      }
      if (typeof offset !== "number" || !Number.isSafeInteger(offset) || offset < 0 || offset > 2147483600) {
        return fail(400, "INVALID_ACTIVITY_PAGE", "Choose a valid activity page.");
      }
      const { preferCached, snapshot = null } = params;
      const stockTransfersOnly = params.stockTransfersOnly === true;
      if (snapshot !== null && (typeof snapshot !== "string" || !UUID.test(snapshot))) {
        return fail(400, "INVALID_ACTIVITY_SNAPSHOT", "Reload brokerage activity.");
      }
      if (!stockTransfersOnly && preferCached === true && (offset === 0 || snapshot !== null)) {
        const cached = await deps.readActivityCache?.(userId, { accountId, startDate, endDate, offset, snapshot })
          .catch(() => null);
        const safePage = protectCachedCashFlows(cached);
        if (safePage) return { status: 200, body: safePage };
        if (snapshot !== null) return fail(409, "ACTIVITY_SNAPSHOT_CHANGED", "Broker activity changed. Reload from the first page.");
      }
      return withUser(userId, deps, async (user) => {
        const result = await call(deps, "GET", `/accounts/${accountId}/activities`, {
          ...user, startDate, endDate, limit: String(activityPageSize), offset: String(offset),
          type: stockTransfersOnly ? stockTransferActivityTypes : activityTypes,
        }, null, "");
        if ("error" in result) return result.error;
        const normalized = await normalizeActivityPage(result.json, accountId, startDate, endDate, offset, stockTransfersOnly);
        return normalized ? { status: 200, body: normalized } :
          fail(502, "INVALID_ACTIVITY_RESPONSE", "The brokerage returned an unreadable page of activity.");
      });
    }
    case "deleteUser":
      return withUser(userId, deps, async (u) => {
        const result = await forward(deps, "DELETE", "/snapTrade/deleteUser", { userId: u.userId }, null);
        if (result.status >= 200 && result.status < 300) await deps.store.remove(userId);
        return result;
      });
  }
}

type ProviderUser = { userId: string; userSecret: string };
type InvestmentRow = Record<string, unknown> & { id: string; connection_id: string };

async function investmentRows(user: ProviderUser, deps: SnapTradeProxyDeps) {
  const accounts = await call(deps, "GET", "/accounts/all", user, null, "");
  if ("error" in accounts) return { error: accounts.error };
  const rows = isRecord(accounts.json) ? accounts.json.results : null;
  if (!Array.isArray(rows) || rows.some((row) => !isRecord(row) || typeof row.kind !== "string")) {
    return { error: fail(502, "INVALID_ACCOUNTS_RESPONSE", "The brokerage returned an unreadable list of accounts.") };
  }
  const investments = new Map<string, InvestmentRow>();
  for (const row of rows) {
    if (row.kind !== "investment") continue;
    if (typeof row.id !== "string" || !UUID.test(row.id) ||
      typeof row.connection_id !== "string" || !UUID.test(row.connection_id)) {
      return { error: fail(502, "INVALID_ACCOUNTS_RESPONSE", "The brokerage returned an unreadable investment account.") };
    }
    investments.set(row.id.toLowerCase(), { ...row, id: row.id.toLowerCase(), connection_id: row.connection_id.toLowerCase() });
  }
  return { rows: [...investments.values()] };
}

function accountText(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function accountDetails(row: InvestmentRow, connection: Record<string, unknown> | undefined) {
  const brokerage = isRecord(connection?.brokerage) ? connection.brokerage : null;
  const total = isRecord(row.net_value) && typeof row.net_value.amount === "number" &&
      Number.isFinite(row.net_value.amount) && typeof row.net_value.currency === "string" &&
      /^[A-Z]{3}$/.test(row.net_value.currency)
    ? { amount: row.net_value.amount, currency: row.net_value.currency }
    : null;
  const suffix = accountText(row.masked_account_number)?.match(/[a-z0-9]{1,4}$/i)?.[0];
  const status = accountText(row.status);
  const waiting = isRecord(row.sync_status) && row.sync_status.positions === null;
  return {
    id: row.id,
    brokerage_authorization: row.connection_id,
    institution_name: accountText(brokerage?.display_name) ?? accountText(brokerage?.name) ?? "Brokerage account",
    name: accountText(row.display_name),
    number: suffix ? `••••${suffix}` : "",
    meta: { type: accountText(row.raw_type) },
    balance: total ? { total } : null,
    positions_status: status === "closed" || status === "archived" || status === "unavailable"
      ? status : !connection ? "unavailable" : connection.disabled === true ? "disconnected" : waiting ? "pending" : "available",
  };
}

async function investmentDirectory(user: ProviderUser, deps: SnapTradeProxyDeps, includeDetails: boolean) {
  const found = await investmentRows(user, deps);
  if (!found.rows) return { error: found.error };
  const connections = new Map<string, Record<string, unknown>>();
  if (includeDetails && found.rows.length) {
    const result = await call(deps, "GET", "/authorizations", user, null, "");
    if ("error" in result) return { error: result.error };
    if (!Array.isArray(result.json)) {
      return { error: fail(502, "INVALID_ACCOUNTS_RESPONSE", "The brokerage returned an unreadable list of connections.") };
    }
    for (const connection of result.json) {
      if (isRecord(connection) && typeof connection.id === "string") {
        connections.set(connection.id.toLowerCase(), connection);
      }
    }
  }
  return { rows: found.rows, connections };
}

/** Use the current account API and keep the array contract used by existing clients. */
export function listInvestmentAccounts(userId: string, deps: SnapTradeProxyDeps, includeDetails = true): Promise<ProxyResponse> {
  if (!UUID.test(userId)) return Promise.resolve(fail(401, "UNAUTHENTICATED", "no signed-in user"));
  return withUser(userId, deps, async (user) => {
    const directory = await investmentDirectory(user, deps, includeDetails);
    if (!directory.rows) return directory.error;
    return {
      status: 200,
      body: directory.rows.map((row) => includeDetails ? accountDetails(row, directory.connections.get(row.connection_id)) : { id: row.id }),
    };
  });
}

function cashEntries(payload: unknown) {
  if (!Array.isArray(payload)) return null;
  const entries = new Map<string, { amount: string | null; buyingPower: string | null }>();
  const duplicates = new Set<string>();
  let incomplete = false;
  for (const row of payload) {
    const code = isRecord(row) && isRecord(row.currency) ? row.currency.code : undefined;
    if (typeof code !== "string" || !/^[A-Z]{3}$/.test(code) || !isRecord(row)) {
      incomplete = true;
      continue;
    }
    if (entries.has(code)) duplicates.add(code);
    const amount = balanceAmount(row.cash);
    entries.set(code, { amount, buyingPower: balanceAmount(row.buying_power) });
    if (amount === null) incomplete = true;
  }
  return {
    balances: [...entries].sort(([a], [b]) => a.localeCompare(b))
      .map(([currency, values]) => ({ currency, ...(duplicates.has(currency) ? { amount: null, buyingPower: null } : values) })),
    incomplete: incomplete || duplicates.size > 0,
  };
}

function balanceAmount(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER ? String(value) : null;
}

function balanceSyncTime(row: InvestmentRow, now: number) {
  const value = isRecord(row.sync_status) ? row.sync_status.balances : null;
  if (typeof value !== "string" || !/(?:Z|[+-]\d{2}:?\d{2})$/i.test(value)) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) && time <= now ? new Date(time).toISOString() : null;
}

async function portfolioCash(userId: string, deps: SnapTradeProxyDeps): Promise<ProxyResponse> {
  const record = await deps.store.get(userId);
  if (!record) return { status: 200, body: { accounts: [], duplicatesSkipped: 0 } };
  const user = { userId: record.snapTradeUserId, userSecret: record.userSecret };
  const deadline = performance.now() + 43_000;
  const directory = await investmentDirectory(user, deps, true);
  if (!directory.rows) return directory.error;
  const distinct = new Map<string, { id: string; label: string; paper: boolean; status: string; syncedAt: string | null;
    netValue: { amount: string; currency: string } | null }>();
  for (const row of directory.rows) {
    const account = accountDetails(row, directory.connections.get(row.connection_id));
    if (account.positions_status === "closed" || account.positions_status === "archived") continue;
    const institution = typeof row.institution_id === "string" && UUID.test(row.institution_id) ? row.institution_id.toLowerCase() : null;
    const institutionAccount = accountText(row.institution_account_id);
    const paper = row.is_paper === true;
    const key = institution && institutionAccount ? JSON.stringify([institution, institutionAccount, paper]) : row.id;
    const status = account.positions_status === "pending" ? "available" : account.positions_status;
    const syncedAt = balanceSyncTime(row, deps.now());
    const priority = (value: string) => value === "available" ? 2 : value === "disconnected" ? 1 : 0;
    const prior = distinct.get(key);
    if (prior && (priority(prior.status) > priority(status) ||
      (priority(prior.status) === priority(status) && (prior.syncedAt ?? "") >= (syncedAt ?? "")))) continue;
    const total = account.balance?.total;
    const amount = balanceAmount(total?.amount);
    const netValue = total && amount !== null ? { amount, currency: total.currency } : null;
    distinct.set(key, { id: row.id, label: [account.institution_name, account.number].filter(Boolean).join(" "), paper, status, syncedAt, netValue });
  }

  const selected = [...distinct.values()];
  const output = new Array(selected.length);
  let next = 0;
  async function readBalances() {
    while (next < selected.length) {
      const index = next++;
      const account = selected[index];
      const remaining = deadline - performance.now();
      if (account.status === "unavailable" || remaining <= 0) {
        output[index] = { ...account, status: "unavailable", balances: [] };
        continue;
      }
      try {
        const result = await call({ ...deps, config: { ...deps.config, timeoutMs: Math.min(15_000, Math.ceil(remaining)) } },
          "GET", `/accounts/${account.id}/balances`, user, null, "");
        const entries = "error" in result ? null : cashEntries(result.json);
        if (entries) {
          output[index] = { ...account, ...entries, status: account.status };
          continue;
        }
      } catch {
        // Keep the other accounts usable when this provider response fails.
      }
      output[index] = { ...account, status: account.status === "disconnected" ? "disconnected" : "unavailable", balances: [] };
    }
  }
  await Promise.all(Array.from({ length: Math.min(selected.length, 4) }, readBalances));
  const openAccounts = directory.rows.filter((row) => row.status !== "closed" && row.status !== "archived").length;
  return { status: 200, body: { accounts: output, duplicatesSkipped: openAccounts - selected.length } };
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
  if (params.connectionPortalVersion !== undefined) {
    if (params.connectionPortalVersion !== "v2" && params.connectionPortalVersion !== "v3" && params.connectionPortalVersion !== "v4") {
      return { error: fail(400, "INVALID_PORTAL_VERSION", "connectionPortalVersion must be v2, v3 or v4") };
    }
    body.connectionPortalVersion = params.connectionPortalVersion;
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
  prefix = API_PREFIX,
): Promise<ProxyResponse> {
  const result = await call(deps, method, path, query, body, prefix);
  if ("error" in result) return result.error;
  return { status: result.status, body: scrubSecrets(result.json) };
}

async function call(
  deps: SnapTradeProxyDeps,
  method: "GET" | "POST" | "DELETE",
  path: string,
  query: Record<string, string>,
  body: Record<string, unknown> | null,
  prefix = API_PREFIX,
): Promise<{ status: number; json: unknown } | { error: ProxyResponse }> {
  const { url, init } = await buildSignedRequest(deps.config, method, path, query, body, deps.now(), prefix);
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
