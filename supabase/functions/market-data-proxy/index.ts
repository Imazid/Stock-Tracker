import { authenticatedUserId, errorResponse, serviceClient } from "../_shared/secure/edge.ts";
import { alpacaRequest } from "./alpaca.ts";
import { fundamentalsRequest } from "./fundamentals.ts";

const cache = new Map<string, { body: string; expires: number }>();
const pending = new Map<string, Promise<{ status: number; body: string }>>();

Deno.serve(async (req) => {
  if (req.method !== "GET") return errorResponse(405, "METHOD_NOT_ALLOWED", "use GET");
  const url = new URL(req.url);
  const fundamentals = url.searchParams.has("provider") ? fundamentalsRequest(url) : undefined;
  const target = fundamentals?.target ?? alpacaRequest(url);
  if (!target) return errorResponse(400, "INVALID_QUERY", "unsupported market data request");

  try {
    const admin = serviceClient();
    const userId = await authenticatedUserId(req, admin);
    if (!userId) return errorResponse(401, "UNAUTHENTICATED", "sign in first");

    const { data, error } = await admin.rpc("consume_market_data_quota", { p_user_id: userId });
    if (error) return errorResponse(503, "UNAVAILABLE", "Market data is temporarily unavailable");
    if (data !== true) return errorResponse(429, "RATE_LIMITED", "Market data request limit reached");

    const cacheKey = target.href;
    const upstreamHeaders: Record<string, string> = {};
    if (fundamentals) {
      const key = Deno.env.get(fundamentals.keyName);
      if (!key) return errorResponse(503, "NOT_CONFIGURED", "This market data source is unavailable");
      if (fundamentals.auth === "query") target.searchParams.set("apikey", key);
      else upstreamHeaders[fundamentals.auth] = key;
    } else {
      const key = Deno.env.get("ALPACA_DATA_KEY_ID");
      const secret = Deno.env.get("ALPACA_DATA_SECRET");
      if (!key || !secret) return errorResponse(503, "NOT_CONFIGURED", "Alpaca data is unavailable");
      upstreamHeaders["APCA-API-KEY-ID"] = key;
      upstreamHeaders["APCA-API-SECRET-KEY"] = secret;
    }
    const cached = cache.get(cacheKey);
    const headers = { "Content-Type": "application/json", "Cache-Control": "private, no-store" };
    if (cached && cached.expires > Date.now()) return new Response(cached.body, { headers });

    let request = pending.get(cacheKey);
    if (!request) {
      request = fetch(target, {
        headers: upstreamHeaders,
        signal: AbortSignal.timeout(10_000),
        redirect: "error",
      }).then(async (reply) => {
        if (!reply.ok) {
          await reply.body?.cancel();
          return { status: reply.status, body: "" };
        }
        const body = await reply.text();
        if (body.length <= 128_000) {
          if (cache.size >= 32) cache.delete(cache.keys().next().value!);
          cache.set(cacheKey, { body, expires: Date.now() + (fundamentals ? 60_000 : 10_000) });
        }
        return { status: reply.status, body };
      }).finally(() => pending.delete(cacheKey));
      pending.set(cacheKey, request);
    }
    const reply = await request;
    if (reply.status !== 200) {
      // Keep plan and rate-limit statuses so callers can retain their feed fallback.
      const status = [400, 402, 403, 404, 422, 429].includes(reply.status) ? reply.status : 502;
      return errorResponse(status, "UPSTREAM_ERROR", "The provider could not supply market data");
    }
    return new Response(reply.body, { headers });
  } catch {
    return errorResponse(502, "UNAVAILABLE", "Market data is temporarily unavailable");
  }
});
