import { SUPABASE_ANON_KEY, SUPABASE_URL } from "@/lib/env";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";

const allowed = new Set([
  "state", "createPortfolio", "previewOrder", "placeOrder", "cancelOrder",
  "createAgent", "runAgent", "pauseAgent", "resumeAgent", "approveProposal", "rejectProposal",
  "agentActivity", "agentActivityDetail",
]);

export async function POST(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "not_configured", "Practice accounts are unavailable.");
  // Browsers set Sec-Fetch-Site before any middleware or reverse proxy rewrites the URL.
  const site = request.headers.get("sec-fetch-site");
  const origin = request.headers.get("origin");
  if (site ? site !== "same-origin" : origin !== new URL(request.url).origin) {
    return jsonError(403, "invalid_origin", "Open Practice Trading in Stock Tracker.");
  }
  const { data } = await db.auth.getSession();
  if (!data.session) return jsonError(401, "unauthenticated", "Sign in to use practice trading.");

  let input: Record<string, unknown>;
  try {
    const raw = await request.text();
    if (raw.length > 40_000) return jsonError(413, "too_large", "The request is too large.");
    input = JSON.parse(raw);
  } catch {
    return jsonError(400, "invalid", "Send a valid practice request.");
  }
  const order = input?.order as { mode?: unknown } | undefined;
  const draft = input?.draft as { mode?: unknown } | undefined;
  if (typeof input?.action !== "string" || !allowed.has(input.action) || "fixture" in input ||
      (order?.mode !== undefined && order.mode !== "paper") ||
      (draft?.mode !== undefined && draft.mode !== "paper")) {
    return jsonError(400, "invalid", "This practice action is unavailable.");
  }

  const headers: Record<string, string> = {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${data.session.access_token}`,
    "Content-Type": "application/json",
  };
  const key = request.headers.get("idempotency-key");
  if (key) headers["Idempotency-Key"] = key;
  try {
    const response = await fetch(`${SUPABASE_URL}/functions/v1/trading-api`, {
      method: "POST", headers, body: JSON.stringify(input), signal: AbortSignal.timeout(25_000), cache: "no-store",
    });
    return new Response(response.body, {
      status: response.status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  } catch {
    return jsonError(503, "unavailable", "The practice server did not respond. Check your activity before retrying.");
  }
}
