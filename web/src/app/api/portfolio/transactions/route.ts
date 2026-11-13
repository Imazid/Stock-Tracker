import { csvField } from "@/lib/csv";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";

const columns = [
  "Transaction ID", "Holding ID", "Transaction time (UTC)", "Ticker", "Exchange", "Asset type",
  "Side", "Quantity", "Price per share (USD)", "Fees (USD)",
];

interface TransactionRow {
  id: string;
  holding_id: string;
  transaction_date: string;
  type: string;
  shares: number;
  price_per_share: number;
  fees: number;
  portfolio_holdings: { asset_symbol: string; asset_exchange: string | null; asset_kind: string } | null;
}

export async function GET(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "unavailable", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser();
  if (!user) return jsonError(401, "unauthenticated", "Sign in to export your transactions.");

  const records: string[] = [columns.map(csvField).join(",")];
  const pageSize = 500;
  let lastId: string | undefined;
  do {
    let query = db.from("transactions")
      .select("id,holding_id,transaction_date,type,shares,price_per_share,fees,portfolio_holdings(asset_symbol,asset_exchange,asset_kind)")
      .eq("user_id", user.id).is("deleted_at", null).order("id").limit(pageSize).abortSignal(request.signal);
    if (lastId) query = query.gt("id", lastId);
    const { data, error } = await query.overrideTypes<TransactionRow[], { merge: false }>();
    if (error) return jsonError(503, "unavailable", "Couldn’t export your transactions. Try again.");
    for (const row of data) {
      const holding = row.portfolio_holdings;
      records.push([
        row.id, row.holding_id, new Date(row.transaction_date).toISOString(), holding?.asset_symbol ?? null,
        holding?.asset_exchange ?? null, holding?.asset_kind ?? null, row.type, row.shares, row.price_per_share, row.fees,
      ].map(csvField).join(","));
    }
    lastId = data.length === pageSize ? data[data.length - 1].id : undefined;
  } while (lastId);

  return new Response(records.join("\r\n") + "\r\n", {
    headers: {
      "Cache-Control": "private, no-store",
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="stock-tracker-transactions.csv"',
    },
  });
}
