// Small HTTP pieces shared by the trading functions: JSON answers, refusals with a
// reason, and structured logs.
//
// Logging rule: one JSON object per line, and never a token, a key, a header or a request
// body. Callers pass the handful of fields worth knowing (action, status, duration,
// counts); `safeFields` drops anything whose name looks like a credential anyway.

import { TradingError } from "../trading/state.ts";

export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string, readonly details?: unknown) {
    super(message);
    this.name = "HttpError";
  }
}

const SENSITIVE = /(authorization|token|secret|password|apikey|api_key|cookie|jwt|key_id)/i;

function safeFields(fields: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(fields)) {
    if (SENSITIVE.test(name)) continue;
    if (typeof value === "string") out[name] = value.length > 300 ? `${value.slice(0, 300)}…` : value;
    else if (typeof value === "number" || typeof value === "boolean" || value === null) out[name] = value;
    else if (Array.isArray(value) && value.every((item) => typeof item === "string" || typeof item === "number")) out[name] = value.slice(0, 50);
    // Anything else (objects, request bodies) is deliberately not logged.
  }
  return out;
}

export function logEvent(event: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ event, at: new Date().toISOString(), ...safeFields(fields) }));
}

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export const ok = (data: unknown): Response => json(200, { ok: true, data });

export function refusal(status: number, code: string, message: string, details?: unknown): Response {
  return json(status, { ok: false, error: details === undefined ? { code, message } : { code, message, details } });
}

/** The HTTP status and code for a refusal the engine raised. */
export function tradingErrorStatus(error: TradingError): { status: number; code: string } {
  switch (error.kind) {
    case "invalid": return { status: 422, code: "invalid" };
    case "liveNotAvailable": return { status: 403, code: "live_not_available" };
    case "notFound": return { status: 404, code: "not_found" };
    case "notAllowed": return { status: 409, code: "not_allowed" };
  }
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) return refusal(error.status, error.code, error.message, error.details);
  if (error instanceof TradingError) {
    const { status, code } = tradingErrorStatus(error);
    return refusal(status, code, error.description, { reasons: error.messages });
  }
  // The cause is logged by the caller; the person is told nothing about the inside.
  return refusal(500, "internal", "Something went wrong on our side. Nothing was changed.");
}

/** Reads a JSON object body, refusing anything too large or not an object. */
export async function readJSONObject(request: Request, maxBytes = 262_144): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (text.length > maxBytes) throw new HttpError(413, "too_large", "The request is too large.");
  if (text.trim() === "") return {};
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new HttpError(400, "bad_request", "The request isn't valid JSON.");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpError(400, "bad_request", "The request must be a JSON object.");
  }
  return value as Record<string, unknown>;
}

/** Compares two secrets without leaking where they differ. */
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let difference = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) difference |= (x[i % Math.max(x.length, 1)] ?? 0) ^ (y[i % Math.max(y.length, 1)] ?? 0);
  return difference === 0;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const Field = {
  object(value: unknown, name: string): Record<string, unknown> {
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new HttpError(400, "bad_request", `"${name}" is missing or isn't an object.`);
    return value as Record<string, unknown>;
  },
  uuid(value: unknown, name: string): string {
    if (typeof value !== "string" || !UUID.test(value)) throw new HttpError(400, "bad_request", `"${name}" must be an id.`);
    return value.toLowerCase();
  },
  optionalUUID(value: unknown, name: string): string | undefined {
    return value === undefined || value === null ? undefined : Field.uuid(value, name);
  },
  string(value: unknown, name: string, maxLength = 200): string {
    if (typeof value !== "string" || value.length > maxLength) throw new HttpError(400, "bad_request", `"${name}" must be text of at most ${maxLength} characters.`);
    return value;
  },
  optionalString(value: unknown, name: string, maxLength = 200): string | undefined {
    return value === undefined || value === null ? undefined : Field.string(value, name, maxLength);
  },
  number(value: unknown, name: string): number {
    if (typeof value !== "number" || !Number.isFinite(value)) throw new HttpError(400, "bad_request", `"${name}" must be a number.`);
    return value;
  },
  optionalNumber(value: unknown, name: string): number | undefined {
    return value === undefined || value === null ? undefined : Field.number(value, name);
  },
  integer(value: unknown, name: string): number {
    if (typeof value !== "number" || !Number.isInteger(value)) throw new HttpError(400, "bad_request", `"${name}" must be a whole number.`);
    return value;
  },
  boolean(value: unknown, name: string): boolean {
    if (typeof value !== "boolean") throw new HttpError(400, "bad_request", `"${name}" must be true or false.`);
    return value;
  },
  oneOf<T extends string>(value: unknown, allowed: readonly T[], name: string): T {
    if (typeof value !== "string" || !allowed.includes(value as T)) throw new HttpError(400, "bad_request", `"${name}" isn't a value this version understands.`);
    return value as T;
  },
};
