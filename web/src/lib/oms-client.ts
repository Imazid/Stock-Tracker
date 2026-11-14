"use client";

// Client for the provider-facing edge functions (`broker-connections`, `broker-orders`),
// coded against the shared contract in supabase/functions/_shared/oms/api.ts. Every call is a
// POST `{ action, ... }` with the person's JWT; state-changing calls carry an Idempotency-Key
// so a double-click or a retried request can't act twice.

import type {
  ApiErrorCode,
  ConnectionsRequest,
  ConnectionsResponse,
  ConnectionView,
  OrderIntentView,
  OrdersRequest,
  OrdersResponse,
} from "@oms/api.ts";
import { SUPABASE_ANON_KEY, SUPABASE_URL, supabaseConfigured } from "@/lib/env";
import { accessToken } from "@/lib/session";
import { uuid } from "@/lib/uuid";

export type OmsErrorCode = ApiErrorCode | "not_deployed" | "not_configured" | "signed_out" | "network";

export class OmsError extends Error {
  constructor(readonly code: OmsErrorCode, message: string, readonly details?: Record<string, unknown>) {
    super(message);
    this.name = "OmsError";
  }
}

const READ_ACTIONS = new Set(["list", "get"]);

export function newIdempotencyKey(): string {
  return uuid();
}

async function call<T>(fn: "broker-connections" | "broker-orders", body: ConnectionsRequest | OrdersRequest, idempotencyKey?: string, expectedUserId?: string): Promise<T> {
  if (!supabaseConfigured) throw new OmsError("not_configured", "Accounts aren't configured for this site.");
  const token = await accessToken(expectedUserId);
  if (!token) throw new OmsError("signed_out", "Sign in to use order routing.");
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
    apikey: SUPABASE_ANON_KEY,
  };
  if (!READ_ACTIONS.has(body.action)) headers["Idempotency-Key"] = idempotencyKey ?? newIdempotencyKey();
  let response: Response;
  try {
    response = await fetch(`${SUPABASE_URL}/functions/v1/${fn}`, { method: "POST", headers, body: JSON.stringify(body) });
  } catch {
    throw new OmsError("not_deployed", "Order routing couldn't be reached. It may not be deployed yet.");
  }
  // Same envelope as trading-api: { ok: true, data } or { ok: false, error: { code, message, details? } }.
  const parsed = (await response.json().catch(() => undefined)) as
    | { ok?: boolean; data?: unknown; error?: { code?: string; message?: string; details?: Record<string, unknown> } }
    | undefined;
  if (response.ok && parsed?.ok === true && parsed.data !== undefined) return parsed.data as T;
  const err = parsed?.error;
  // A 404 without that shape is the gateway saying the function doesn't exist.
  if (!err?.code) {
    if (response.status === 404) throw new OmsError("not_deployed", "Order routing isn't deployed yet.");
    throw new OmsError("network", `Order routing answered ${response.status}.`);
  }
  if (err.code === "unauthenticated") throw new OmsError("signed_out", err.message ?? "Sign in again.");
  if (err.code === "unavailable") throw new OmsError("network", err.message ?? "Order routing is unavailable right now.");
  throw new OmsError(err.code as OmsErrorCode, err.message ?? "The request was refused.", err.details);
}

export const Connections = {
  list: (userId?: string) => call<{ connections: ConnectionView[] }>("broker-connections", { action: "list" } satisfies ConnectionsRequest, undefined, userId),
  connect: (request: Extract<ConnectionsRequest, { action: "connect" }>, key?: string) =>
    call<{ connection: ConnectionView }>("broker-connections", request, key),
  sync: (connectionID: string, key?: string) =>
    call<Extract<ConnectionsResponse, { synced: unknown }>>("broker-connections", { action: "sync", connectionID } satisfies ConnectionsRequest, key),
  revoke: (connectionID: string, key?: string) =>
    call<{ revoked: true }>("broker-connections", { action: "revoke", connectionID } satisfies ConnectionsRequest, key),
};

export const Orders = {
  list: (status: "open" | "closed" | "all" = "all", userId?: string) => call<{ intents: OrderIntentView[] }>("broker-orders", { action: "list", status } satisfies OrdersRequest, undefined, userId),
  get: (intentID: string, userId?: string) => call<{ intent: OrderIntentView }>("broker-orders", { action: "get", intentID } satisfies OrdersRequest, undefined, userId),
  act: (request: Exclude<OrdersRequest, { action: "list" } | { action: "get" }>, key?: string, userId?: string) =>
    call<Extract<OrdersResponse, { intent: unknown }>>("broker-orders", request, key, userId),
};

export function describeOmsError(error: unknown): { title: string; body: string; code: OmsErrorCode | "unknown" } {
  if (!(error instanceof OmsError)) return { title: "Something went wrong", body: "The request failed.", code: "unknown" };
  switch (error.code) {
    case "not_deployed": return { title: "Order routing isn't deployed yet", body: "The broker-orders and broker-connections functions aren't running on this backend. Nothing can be connected or sent until they are.", code: error.code };
    case "not_configured": return { title: "Accounts aren't configured", body: "Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY to enable sign-in and order routing.", code: error.code };
    case "signed_out": return { title: "Sign in required", body: error.message, code: error.code };
    case "step_up_required": return { title: "Confirm it's you", body: "This action needs a second factor (MFA). Verify with your authenticator and try again.", code: error.code };
    case "feature_disabled": return { title: "Turned off on this platform", body: error.message, code: error.code };
    case "kill_switch_engaged": return { title: "Trading is halted", body: "The kill switch is on. No new orders can be submitted until it's released.", code: error.code };
    case "risk_rejected": return { title: "Blocked by risk limits", body: error.message, code: error.code };
    case "approval_expired": return { title: "Approval expired", body: "Review the order again and approve the current version.", code: error.code };
    case "approval_used": return { title: "Already used", body: "That approval has already been used for a submission.", code: error.code };
    case "intent_changed": return { title: "The order changed", body: "What you approved no longer matches the order. Review it again.", code: error.code };
    case "stale_price": return { title: "Price too old", body: "The price used for checks is out of date. Refresh and check again.", code: error.code };
    case "reconciliation_required": return { title: "Checking with the broker", body: "The broker's answer was unclear, so the order is being reconciled before anything else happens. It will not be resent automatically.", code: error.code };
    case "rate_limited": return { title: "Slow down", body: "Too many requests — try again shortly.", code: error.code };
    default: return { title: "Request refused", body: error.message, code: error.code };
  }
}
