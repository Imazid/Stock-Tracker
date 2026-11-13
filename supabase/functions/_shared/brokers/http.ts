// The one way an adapter talks HTTP. Two entry points, deliberately different:
//
//   read(...)      for calls that are safe to repeat — GETs, cancels (cancelling twice is
//                  harmless), previews. Timeouts, network errors, 429 and 5xx are retried
//                  with exponential backoff and full jitter, honouring Retry-After.
//   sendOnce(...)  for calls that can create or change an order. Exactly one attempt. If we
//                  can't tell whether the provider acted — a timeout, a dropped connection,
//                  any 5xx after the request left — the answer is `unknown`, and the caller
//                  must look the order up by its clientOrderID before doing anything else.
//                  A second POST is how a person ends up owning twice what they approved.
//
// Credentials travel only in request headers. Error messages are built from the provider's
// response body, never from the request, and are scrubbed of any secret string the adapter
// passes in, in case a provider ever echoes one back.

import { type AdapterContext, BrokerError, type BrokerErrorCode } from "./types.ts";

export type Method = "GET" | "POST" | "PATCH" | "DELETE";

export interface HttpRequest {
  method: Method;
  url: string;
  headers: Record<string, string>;
  /** JSON-encoded when present. */
  body?: unknown;
}

export interface HttpResponse {
  status: number;
  headers: Headers;
  /** Parsed JSON, or undefined when the body was empty or not JSON. */
  body: unknown;
  text: string;
}

export interface RetryOptions {
  /** Total attempts including the first. Default 3. */
  maxAttempts?: number;
  baseDelayMs?: number;
  maxDelayMs?: number;
  /** A Retry-After longer than this isn't waited out; the 429 is returned to the caller. */
  maxRetryAfterMs?: number;
  sleep?: (ms: number) => Promise<void>;
  random?: () => number;
}

export const DEFAULT_TIMEOUT_MS = 10_000;

class TransportFailure extends Error {
  constructor(readonly kind: "timeout" | "network") {
    super(kind === "timeout" ? "the request timed out" : "the connection failed");
    this.name = "TransportFailure";
  }
}

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

async function once(ctx: AdapterContext, request: HttpRequest): Promise<HttpResponse> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ctx.timeoutMs ?? DEFAULT_TIMEOUT_MS);
  const doFetch = ctx.fetch ?? fetch;
  try {
    const response = await doFetch(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body === undefined ? undefined : JSON.stringify(request.body),
      signal: controller.signal,
    });
    const text = await response.text();
    let body: unknown = undefined;
    if (text.length > 0) {
      try {
        body = JSON.parse(text);
      } catch {
        body = undefined;
      }
    }
    return { status: response.status, headers: response.headers, body, text };
  } catch (_error) {
    throw new TransportFailure(controller.signal.aborted ? "timeout" : "network");
  } finally {
    clearTimeout(timer);
  }
}

/** Full jitter: a random delay in [0, min(maxDelay, base · 2^(attempt−1))). */
export function backoffMs(attempt: number, options: RetryOptions = {}): number {
  const base = options.baseDelayMs ?? 250;
  const cap = options.maxDelayMs ?? 4_000;
  const random = options.random ?? Math.random;
  return Math.floor(random() * Math.min(cap, base * 2 ** (attempt - 1)));
}

/** Retry-After as milliseconds: delta-seconds or an HTTP date. Undefined when absent/unreadable. */
export function retryAfterMs(headers: Headers, now: number = Date.now()): number | undefined {
  const raw = headers.get("retry-after");
  if (raw === null) return undefined;
  const trimmed = raw.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed) * 1000;
  const date = Date.parse(trimmed);
  return Number.isNaN(date) ? undefined : Math.max(0, date - now);
}

/** A repeatable call (GET / DELETE cancel / preview). Throws BrokerError only on transport failure after retries. */
export async function read(
  ctx: AdapterContext,
  request: HttpRequest,
  provider: string,
  options: RetryOptions = {},
): Promise<HttpResponse> {
  const attempts = Math.max(1, options.maxAttempts ?? ctx.readAttempts ?? 3);
  const sleep = options.sleep ?? defaultSleep;
  const maxRetryAfter = options.maxRetryAfterMs ?? 30_000;
  for (let attempt = 1; ; attempt++) {
    let response: HttpResponse;
    try {
      response = await once(ctx, request);
    } catch (error) {
      if (!(error instanceof TransportFailure)) throw error;
      if (attempt < attempts) {
        await sleep(backoffMs(attempt, options));
        continue;
      }
      throw new BrokerError("provider_unavailable", `${provider} didn't answer: ${error.message}.`);
    }
    const retryable = response.status === 429 || response.status >= 500;
    if (!retryable || attempt >= attempts) return response;
    const wait = response.status === 429 ? retryAfterMs(response.headers) : undefined;
    if (wait !== undefined && wait > maxRetryAfter) return response;
    await sleep(wait ?? backoffMs(attempt, options));
  }
}

export type SendOutcome =
  | { kind: "response"; response: HttpResponse }
  | { kind: "unknown"; reason: string };

/** A call that can create or change an order: one attempt, never retried. */
export async function sendOnce(ctx: AdapterContext, request: HttpRequest): Promise<SendOutcome> {
  let response: HttpResponse;
  try {
    response = await once(ctx, request);
  } catch (error) {
    if (!(error instanceof TransportFailure)) throw error;
    return { kind: "unknown", reason: `${error.message}; the provider may or may not have accepted the order` };
  }
  if (response.status >= 500) {
    return { kind: "unknown", reason: `the provider answered HTTP ${response.status}; it may or may not have accepted the order` };
  }
  return { kind: "response", response };
}

// MARK: - Errors

export function codeForStatus(status: number): BrokerErrorCode {
  if (status === 401) return "unauthorized";
  if (status === 403) return "forbidden";
  if (status === 404) return "not_found";
  if (status === 429) return "rate_limited";
  if (status === 400 || status === 409 || status === 422) return "invalid_request";
  if (status >= 500) return "provider_unavailable";
  return "unexpected_response";
}

/** The provider's own message from a JSON error body, if any. */
export function providerMessage(body: unknown): string | undefined {
  if (!body || typeof body !== "object") return undefined;
  const record = body as Record<string, unknown>;
  for (const key of ["message", "error_description"]) {
    if (typeof record[key] === "string" && record[key]) return record[key] as string;
  }
  const nested = record.error_response;
  if (nested && typeof nested === "object") {
    const message = (nested as Record<string, unknown>).message;
    if (typeof message === "string" && message) return message;
  }
  if (typeof record.error === "string" && record.error) return record.error;
  return undefined;
}

/** The provider's machine code (Alpaca numeric `code`, Coinbase `error`), as text. */
export function providerCode(body: unknown): string | undefined {
  if (!body || typeof body !== "object") return undefined;
  const record = body as Record<string, unknown>;
  if (typeof record.code === "number" || typeof record.code === "string") return String(record.code);
  if (typeof record.error === "string") return record.error;
  return undefined;
}

/** Remove any secret that appears in `text`, and keep messages short. */
export function scrub(text: string, secrets: readonly string[] = []): string {
  let out = text;
  for (const secret of secrets) {
    if (secret && secret.length >= 6) out = out.split(secret).join("[redacted]");
  }
  return out.length > 300 ? `${out.slice(0, 297)}...` : out;
}

export function errorFromResponse(provider: string, response: HttpResponse, secrets: readonly string[] = []): BrokerError {
  const code = codeForStatus(response.status);
  const message = providerMessage(response.body) ?? `HTTP ${response.status}`;
  return new BrokerError(code, scrub(`${provider}: ${message}`, secrets), {
    status: response.status,
    providerCode: providerCode(response.body),
    retryAfterMs: response.status === 429 ? retryAfterMs(response.headers) : undefined,
  });
}

/** Query string from a record; arrays repeat the key; undefined values are dropped. */
export function query(params: Record<string, string | number | boolean | readonly string[] | undefined>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) continue;
    if (Array.isArray(value)) for (const item of value) search.append(key, item);
    else search.append(key, String(value));
  }
  const text = search.toString();
  return text ? `?${text}` : "";
}
