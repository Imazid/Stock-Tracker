import { csvField } from "@/lib/csv";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";
import { transactionPages } from "@/server/portfolio/transactions";

const columns = [
  "Transaction ID", "Holding ID", "Transaction time (UTC)", "Ticker", "Exchange", "Asset type",
  "Side", "Quantity", "Price per share (USD)", "Fees (USD)",
];

export async function GET(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "unavailable", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser();
  if (!user) return jsonError(401, "unauthenticated", "Sign in to export your transactions.");

  const records: string[] = [columns.map(csvField).join(",")];
  try {
    for await (const page of transactionPages(db, user.id, request.signal)) {
      for (const row of page) {
        const holding = row.portfolio_holdings;
        const time = new Date(row.transaction_date);
        records.push([
          row.id, row.holding_id, Number.isFinite(time.getTime()) ? time.toISOString() : row.transaction_date, holding?.asset_symbol ?? null,
          holding?.asset_exchange ?? null, holding?.asset_kind ?? null, row.type, row.shares, row.price_per_share, row.fees,
        ].map(csvField).join(","));
      }
    }
  } catch {
    return jsonError(503, "unavailable", "Couldn’t export your transactions. Try again.");
  }

  return new Response(records.join("\r\n") + "\r\n", {
    headers: {
      "Cache-Control": "private, no-store",
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="stock-tracker-transactions.csv"',
    },
  });
}
