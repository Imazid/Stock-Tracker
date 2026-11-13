// POST /functions/v1/ai-proxy   { "purpose": "chat" | "insight" | "copilot", "messages": [...] }
//
// The only path from the app to a language model. Secrets (Edge Function secrets only):
//   GEMINI_API_KEY and/or OPENAI_API_KEY
//   AI_DAILY_LIMIT  — per-user daily request ceiling (default 50)
// See supabase/functions/_shared/ai/proxy.ts for limits and the server policy.

import { AI_LIMITS, handleAiRequest } from "../_shared/ai/proxy.ts";
import { authenticatedUserId, errorResponse, jsonResponse, readJson, serviceClient } from "../_shared/secure/edge.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return errorResponse(405, "METHOD_NOT_ALLOWED", "use POST");

  let admin;
  try {
    admin = serviceClient();
  } catch {
    return errorResponse(503, "SERVER_NOT_CONFIGURED", "server is not configured");
  }
  const userId = await authenticatedUserId(req, admin);
  if (!userId) return errorResponse(401, "UNAUTHENTICATED", "sign in first");

  let body: unknown;
  try {
    body = await readJson(req, 200_000);
  } catch {
    return errorResponse(400, "INVALID_JSON", "body must be JSON under 200 KB");
  }

  const parsedLimit = Number.parseInt(Deno.env.get("AI_DAILY_LIMIT") ?? "", 10);
  try {
    const result = await handleAiRequest(userId, body, {
      config: {
        geminiKey: Deno.env.get("GEMINI_API_KEY") ?? undefined,
        openAIKey: Deno.env.get("OPENAI_API_KEY") ?? undefined,
        dailyLimit: Number.isFinite(parsedLimit) && parsedLimit >= 0 ? parsedLimit : AI_LIMITS.defaultDailyLimit,
      },
      quota: {
        async consume(uid, limit) {
          const { data, error } = await admin.rpc("consume_ai_quota", { p_user_id: uid, p_limit: limit });
          if (error) throw new Error(`consume_ai_quota failed: ${error.code}`);
          const row = Array.isArray(data) ? data[0] : data;
          return { allowed: row?.allowed === true, used: Number(row?.used ?? 0) };
        },
      },
      fetch,
    });
    return jsonResponse(result.status, result.body);
  } catch (error) {
    console.error("ai-proxy failure", (error as Error).name, (error as Error).message.slice(0, 120));
    return errorResponse(500, "INTERNAL", "unexpected server error");
  }
});
