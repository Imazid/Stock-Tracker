import { csvField } from "@/lib/csv";
import { incomeDay, incomeFields, incomeKinds, incomeNotice, type IncomeRow } from "@/lib/portfolio-income";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";

const columns = [
  "Record type", "Payment ID", "Payment date (Sydney)", "Payment type", "Payer or ticker", "Account label", "Currency",
  "Cash received", "Gross payment", "Withholding", "Franking credit (AUD)", "Statement reference",
  "SnapTrade activity reference", "SnapTrade reported date", "SnapTrade reported currency", "SnapTrade reported amount", "Report note",
];

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

  const records = [
    columns.map(csvField).join(","),
    columns.map((_, i) => i === 0 ? csvField("Report information") : i === columns.length - 1 ? csvField(incomeNotice) : "").join(","),
  ];
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
        ].map(csvField).join(","));
      }
      last = data.length === pageSize ? data[data.length - 1] : undefined;
    } while (last);
  } catch {
    return jsonError(503, "unavailable", "Couldn’t export your cash income. Try again.");
  }

  return new Response(records.join("\r\n") + "\r\n", {
    headers: {
      "Cache-Control": "private, no-store",
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="stock-tracker-cash-income.csv"',
    },
  });
}
