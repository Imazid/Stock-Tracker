import type { SupabaseClient } from "@supabase/supabase-js";
import type { AgentActivityPeriod, AgentActivitySummary } from "@engine/activity.ts";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "@/lib/env";

export async function accountAgentActivity(db: SupabaseClient, period: AgentActivityPeriod, timeZone: string, signal?: AbortSignal) {
  const { data } = await db.auth.getSession();
  const token = data.session?.access_token;
  if (!token) return undefined;
  const response = await fetch(`${SUPABASE_URL}/functions/v1/trading-api`, {
    method: "POST", cache: "no-store", signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(25_000)]) : AbortSignal.timeout(25_000),
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ action: "agentActivitySummary", period, timeZone }),
  });
  if (!response.ok) return undefined;
  return ((await response.json()) as { data?: { summary?: AgentActivitySummary } }).data?.summary;
}
