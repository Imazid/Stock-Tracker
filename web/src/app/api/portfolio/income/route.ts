import { csvField } from "@/lib/csv";
import { incomeDay, incomeFields, incomeKinds, incomeNotice, type IncomeRow } from "@/lib/portfolio-income";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";
import { reinvestmentPages } from "@/server/portfolio/reinvestments";

const columns = [
  "Record type", "Payment ID", "Payment date (Sydney)", "Payment type", "Payer or ticker", "Account label", "Currency",
  "Cash received", "Gross payment", "Withholding", "Franking credit (AUD)", "Statement reference",
  "SnapTrade activity reference", "SnapTrade reported date", "SnapTrade reported currency", "SnapTrade reported amount", "Report note",
];
const reinvestmentColumns = ["Reinvested amount", "Shares acquired", "Acquisition date (Sydney)", "Acquisition basis (USD)"];

export async function GET(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "unavailable", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser();
  if (!user) return jsonError(401, "unauthenticated", "Sign in to export your cash income.");

  const params = new URL(request.url).searchParams;
  const from = incomeDay(params.get("from"));
  const through = incomeDay(params.get("through"));
  if ((params.has("from") && !from) || (params.has("through") && !through) || (from && through && from > through)) {
    return jsonError(400, "invalid_date_range", "Choose valid dates in chronological order.");
  }

  const records: (string | null)[][] = [];
  const reinvestments: (string | null)[][] = [];
  try {
    const pageSize = 500;
    let last: IncomeRow | undefined;
    do {
      let query = db.from("portfolio_cash_income").select(incomeFields).eq("user_id", user.id)
        .order("paid_on", { ascending: false }).order("id", { ascending: false }).limit(pageSize).abortSignal(request.signal);
      if (from) query = query.gte("paid_on", from);
      if (through) query = query.lte("paid_on", through);
      if (last) query = query.or(`paid_on.lt.${last.paid_on},and(paid_on.eq.${last.paid_on},id.lt.${last.id})`);
      const { data, error } = await query.overrideTypes<IncomeRow[], { merge: false }>();
      if (error) throw error;
      for (const payment of data) {
        records.push([
          "Cash payment", payment.id, payment.paid_on, incomeKinds[payment.kind], payment.payer, payment.account_label,
          payment.currency, payment.cash_received, payment.gross_amount, payment.withholding, payment.franking_credit_aud,
          payment.statement_reference, payment.snaptrade_activity_id, payment.snaptrade_reported_on,
          payment.snaptrade_reported_currency, payment.snaptrade_reported_amount, null,
        ]);
      }
      last = data.length === pageSize ? data[data.length - 1] : undefined;
    } while (last);
    for await (const page of reinvestmentPages(db, user.id, request.signal, { field: "paid_on", from, through })) {
      for (const entry of page) {
        reinvestments.push([
          "Dividend reinvestment", entry.id, entry.paid_on, "Dividend", entry.portfolio_holdings?.asset_symbol ?? null,
          null, entry.currency, null, entry.dividend_amount, null, entry.franking_credit_aud, entry.statement_reference,
          null, null, null, null, "The gross dividend may include cash paid separately. Use the statement to reconcile both entries.",
          entry.reinvested_amount, entry.shares, entry.acquired_on,
          entry.currency === "USD" ? entry.reinvested_amount : entry.basis_usd,
        ]);
      }
    }
  } catch {
    return jsonError(503, "unavailable", "Couldn’t export your cash income. Try again.");
  }

  const header = reinvestments.length ? [...columns, ...reinvestmentColumns] : columns;
  const note = header.map((name, i) => i === 0 ? "Report information" : name === "Report note" ? incomeNotice : null);
  const rows = [...records, ...reinvestments].sort((a, b) => b[2]!.localeCompare(a[2]!) || b[1]!.localeCompare(a[1]!));
  return new Response([header, note, ...rows].map((row) => header.map((_, i) => csvField(row[i] ?? null)).join(",")).join("\r\n") + "\r\n", {
    headers: {
      "Cache-Control": "private, no-store",
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="stock-tracker-cash-income.csv"',
    },
  });
}
