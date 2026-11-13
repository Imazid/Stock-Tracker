// JSON helpers for route handlers: one error shape everywhere ({ error: { code, message } }),
// and a small per-IP rate limit so a page left open can't hammer the upstream sources.

import type { ApiErrorBody } from "@/lib/market-types";

export function jsonError(status: number, code: string, message: string, details?: Record<string, unknown>): Response {
  const body: ApiErrorBody = { error: { code, message, ...(details ? { details } : {}) } };
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

export function json(body: unknown, maxAgeSeconds = 0): Response {
  return Response.json(body, {
    headers: { "Cache-Control": maxAgeSeconds > 0 ? `private, max-age=${maxAgeSeconds}` : "no-store" },
  });
}

interface Bucket { tokens: number; updated: number }
const g = globalThis as { __stRate?: Map<string, Bucket> };
const buckets = (g.__stRate ??= new Map<string, Bucket>());

/** Token bucket: `perMinute` requests per minute per client IP, bursting to that many. */
export function rateLimited(request: Request, perMinute = 180): Response | undefined {
  const ip = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || request.headers.get("x-real-ip") || "local";
  const now = Date.now();
  const bucket = buckets.get(ip) ?? { tokens: perMinute, updated: now };
  bucket.tokens = Math.min(perMinute, bucket.tokens + ((now - bucket.updated) / 60_000) * perMinute);
  bucket.updated = now;
  if (bucket.tokens < 1) {
    buckets.set(ip, bucket);
    return jsonError(429, "rate_limited", "Too many requests — try again in a few seconds.");
  }
  bucket.tokens -= 1;
  buckets.set(ip, bucket);
  if (buckets.size > 10_000) buckets.clear();
  return undefined;
}
