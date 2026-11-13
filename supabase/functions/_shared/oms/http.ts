// HTTP plumbing for broker-connections and broker-orders. Same envelope as trading-api:
//   success  { ok: true, data }
//   refusal  { ok: false, error: { code, message, details? } }
// The caller is identified by asking the auth server about their token (signature, expiry,
// session still alive) — never from the request body.
//
// NOTE: trading-api has equivalent helpers in _shared/server (not yet committed when this
// was written). Fold these into those once both are on one branch.

import type { ApiErrorCode } from "./api.ts";

export class HttpError extends Error {
  constructor(readonly status: number, readonly code: ApiErrorCode | "unauthenticated" | "unavailable", message: string, readonly details?: Record<string, unknown>) {
    super(message);
    this.name = "HttpError";
  }
}

export interface Caller {
  userID: string;
  aal: "aal1" | "aal2";
}

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type, idempotency-key, apikey, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...CORS } });
}

export const ok = (data: unknown): Response => json(200, { ok: true, data });

export function refusal(status: number, code: string, message: string, details?: Record<string, unknown>): Response {
  return json(status, { ok: false, error: details === undefined ? { code, message } : { code, message, details } });
}

export const preflight = (): Response => new Response(null, { status: 204, headers: CORS });

const STATUS: Partial<Record<ApiErrorCode, number>> = {
  unauthorized: 401, step_up_required: 403, forbidden: 403, not_found: 404, invalid: 422, conflict: 409,
  feature_disabled: 403, kill_switch_engaged: 423, risk_rejected: 422, approval_invalid: 409, approval_expired: 409,
  approval_used: 409, intent_changed: 409, stale_price: 409, provider_error: 502, reconciliation_required: 409, rate_limited: 429,
};
export const statusFor = (code: ApiErrorCode): number => STATUS[code] ?? 400;

/** Logs one JSON line. Keys that could carry secrets are dropped, whatever the caller passes. */
export function logEvent(event: string, fields: Record<string, unknown> = {}): void {
  const safe: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(fields)) {
    if (/secret|key|token|password|pem|credential|authorization/i.test(k)) continue;
    safe[k] = typeof v === "string" && v.length > 300 ? `${v.slice(0, 300)}…` : v;
  }
  console.log(JSON.stringify({ event, at: new Date().toISOString(), ...safe }));
}

export async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (text.length > 64_000) throw new HttpError(413, "invalid", "That request is too large.");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid", "Send a JSON object.");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw new HttpError(400, "invalid", "Send a JSON object.");
  return body as Record<string, unknown>;
}

function claims(token: string): Record<string, unknown> {
  try {
    const part = token.split(".")[1] ?? "";
    return JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=")));
  } catch {
    return {};
  }
}

export async function authenticate(request: Request, env: { url?: string; anonKey?: string; fetch?: typeof fetch }): Promise<Caller> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token) throw new HttpError(401, "unauthenticated", "Sign in to continue.");
  if (!env.url || !env.anonKey) throw new HttpError(503, "unavailable", "Sign-in can't be checked right now.");
  let response: Response;
  try {
    response = await (env.fetch ?? fetch)(`${env.url.replace(/\/+$/, "")}/auth/v1/user`, {
      headers: { authorization: `Bearer ${token}`, apikey: env.anonKey },
      signal: AbortSignal.timeout(8_000),
    });
  } catch {
    throw new HttpError(503, "unavailable", "Sign-in can't be checked right now.");
  }
  if (response.status === 401 || response.status === 403) {
    await response.body?.cancel().catch(() => {});
    throw new HttpError(401, "unauthenticated", "Your session has ended. Sign in again.");
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw new HttpError(503, "unavailable", "Sign-in can't be checked right now.");
  }
  const user = await response.json().catch(() => null) as Record<string, unknown> | null;
  const payload = claims(token);
  const userID = typeof user?.id === "string" ? user.id.toLowerCase() : "";
  if (userID === "" || payload.sub !== user?.id || payload.role !== "authenticated") {
    throw new HttpError(401, "unauthenticated", "Sign in to continue.");
  }
  return { userID, aal: payload.aal === "aal2" ? "aal2" : "aal1" };
}

export function idempotencyKey(request: Request): string | undefined {
  const key = request.headers.get("idempotency-key") ?? undefined;
  if (key !== undefined && !/^[A-Za-z0-9._:-]{8,128}$/.test(key)) throw new HttpError(400, "invalid", "The Idempotency-Key must be 8 to 128 letters, digits or . _ : -");
  return key;
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) return refusal(error.status, error.code, error.message, error.details);
  logEvent("oms_internal_error", { error: error instanceof Error ? `${error.name}: ${error.message}` : "unknown" });
  return refusal(500, "internal", "Something went wrong on our side. If you were sending an order, check Orders before trying again — an order is never sent twice.");
}
