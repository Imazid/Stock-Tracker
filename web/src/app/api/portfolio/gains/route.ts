import { serverSupabase } from "@/lib/supabase/server";
import { json, jsonError } from "@/server/http/respond";
import { portfolioGains } from "@/server/portfolio/gains";
import { readLotLedger } from "@/server/portfolio/lot-ledger";
import { sydneyDate } from "@/server/portfolio/lots";

export async function GET(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "unavailable", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser();
  if (!user) return jsonError(401, "unauthenticated", "Sign in to view portfolio gains.");
  try {
    const asOf = new Date().toISOString();
    const ledger = await readLotLedger(db, user.id, request.signal, sydneyDate(asOf)!, asOf);
    return json(portfolioGains(user.id, asOf, ledger));
  } catch {
    return jsonError(503, "unavailable", "Couldn’t load your portfolio gains. Try again.");
  }
}
