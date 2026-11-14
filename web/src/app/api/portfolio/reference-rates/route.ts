import { serverSupabase } from "@/lib/supabase/server";
import { json, jsonError } from "@/server/http/respond";
import { portfolioReferenceRates } from "@/server/portfolio/reference-rates";

export async function GET(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "unavailable", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser();
  if (!user) return jsonError(401, "unauthenticated", "Sign in to view portfolio exchange rates.");
  try {
    return json(await portfolioReferenceRates(request.signal), 900);
  } catch {
    return jsonError(503, "fx_unavailable", "ECB reference rates are temporarily unavailable.");
  }
}
