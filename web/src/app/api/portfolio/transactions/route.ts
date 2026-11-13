import { csvField } from "@/lib/csv";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";
import { tradeConversion, tradeSource, transactionPages } from "@/server/portfolio/transactions";

const columns = [
  "Transaction ID", "Holding ID", "Transaction time (UTC)", "Ticker", "Exchange", "Asset type",
  "Side", "Quantity", "Price per share (USD)", "Fees (USD)",
  "Record source", "Input currency", "Input unit price", "Input fees",
  "Bookkeeping FX (USD per input currency unit)", "Bookkeeping FX method", "Bookkeeping FX saved at (UTC)",
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
        const source = row.trade_provenance;
        records.push([
          row.id, row.holding_id, row.transaction_date, holding?.asset_symbol ?? null,
          holding?.asset_exchange ?? null, holding?.asset_kind ?? null, row.type, row.shares, row.price_per_share, row.fees,
          tradeSource(source), source?.currency ?? null, source?.unitPrice ?? null, source?.fees ?? null,
          source?.usdPerUnit ?? null, tradeConversion(source), source?.conversionRecordedAt ?? null,
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
