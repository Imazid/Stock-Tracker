import { SUPABASE_ANON_KEY, SUPABASE_URL } from "@/lib/env";
import { json, jsonError, rateLimited } from "@/server/http/respond";

export async function GET(request: Request) {
  const limited = rateLimited(request, 30);
  if (limited) return limited;
  const secret = process.env.WORKSPACE_OVERVIEW_SECRET;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !secret) {
    return jsonError(503, "explore_unavailable", "Market rankings are awaiting configuration.");
  }
  try {
    const response = await fetch(`${SUPABASE_URL.replace(/\/$/, "")}/functions/v1/market-workspace`, {
      method: "POST",
      headers: {
        apikey: SUPABASE_ANON_KEY,
        "Content-Type": "application/json",
        "X-Workspace-Overview-Secret": secret,
      },
      body: JSON.stringify({ action: "explore" }),
      signal: AbortSignal.timeout(20_000),
      next: { revalidate: 60 },
    });
    if (response.ok) {
      const payload = await response.json();
      if (payload.ok && payload.data) return json(payload.data, 30);
    }
  } catch {
    // The catalog and search still work when the ranking service is unreachable.
  }
  return jsonError(503, "explore_unavailable", "Market rankings are temporarily unavailable.");
}
