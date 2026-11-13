import { csvField } from "@/lib/csv";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";
import { splitFields, type StockSplit } from "@/lib/portfolio-splits";
import { audReferences, type AudReference } from "@/server/portfolio/aud-rates";
import { calculateLots, lotNumber, sydneyDate, UNIT_DECIMALS } from "@/server/portfolio/lots";
import { tradeSource, transactionPages, type TransactionRow } from "@/server/portfolio/transactions";

const disclaimer = "Preliminary USD FIFO records for review. This report does not calculate tax. Verify actual lots, transaction-date AUD values, transfers, corporate actions and missing transactions. Trades with identical timestamps use sales before purchases. Saved splits apply before trades on the Sydney effective date. Sales use units on the sale date and open lots use units at the report end. Check fractional shares and cash payments against your statement. Use the transaction CSV for source amounts and bookkeeping FX.";
const columns = [
  "Record type", "Holding ID", "Ticker", "Exchange", "Asset type", "Transaction ID", "Transaction time (UTC)", "Transaction date (Sydney)",
  "Purchase ID", "Purchase time (UTC)", "Quantity", "Purchase cost (USD)", "Purchase fees (USD)",
  "Sale proceeds (USD)", "Sale fees (USD)", "Estimated FIFO result (USD)", "Report note", "Transaction record source", "Purchase record source",
];
const noteColumn = columns.indexOf("Report note");
const splitColumns = ["Split ID", "Split effective date (Sydney)", "Split new shares", "Split old shares", "Split statement reference"];
const brokerSplitColumns = ["SnapTrade activity reference", "SnapTrade reported date", "SnapTrade reported activity", "SnapTrade reported symbol"];
const audColumns = [
  "Purchase cost (AUD)", "Purchase fees (AUD)", "Sale proceeds (AUD)", "Sale fees (AUD)", "Estimated FIFO result (AUD)",
  "Purchase input currency", "Purchase FX (AUD per input currency unit)", "Purchase FX observation date", "Purchase FX source",
  "Sale input currency", "Sale FX (AUD per input currency unit)", "Sale FX observation date", "Sale FX source",
];
const audDisclosure = "AUD figures use original amounts. Foreign amounts use the latest common ECB observation on or before each Sydney trade date within seven days. ECB reference rates are indicative. AUD input uses a rate of one. Blank fields indicate unavailable source amounts or rates. The AUD result requires both prices and fees.";

function referenceFields(references: ReadonlyMap<string, AudReference>, trade?: TransactionRow) {
  const reference = trade && references.get(trade.id);
  return [
    csvField(trade?.trade_provenance?.currency ?? null),
    reference && "rate" in reference ? reference.rate : "",
    csvField(reference && "date" in reference ? reference.date : null),
    csvField(reference?.source ?? null),
  ];
}

function day(value: string | null) {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value) || value < "1900-01-01" || value > "9998-12-31") return null;
  const time = Date.parse(value + "T00:00:00Z");
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value ? value : null;
}

export async function GET(request: Request) {
  const db = await serverSupabase();
  if (!db) return jsonError(503, "unavailable", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser();
  if (!user) return jsonError(401, "unauthenticated", "Sign in to export your lot report.");

  const query = new URL(request.url).searchParams;
  const currency = query.get("currency") ?? "USD";
  if (currency !== "USD" && currency !== "AUD") {
    return jsonError(400, "invalid_currency", "Choose USD or AUD for your report.");
  }
  const start = day(query.get("from"));
  const end = day(query.get("through"));
  if ((query.has("from") && !start) || (query.has("through") && !end) || (start && end && start > end)) {
    return jsonError(400, "invalid_date_range", "Choose valid dates in chronological order.");
  }

  const transactions: TransactionRow[] = [];
  const splits: StockSplit[] = [];
  // Sydney midnight is earlier than UTC midnight. The query uses a broad UTC
  // cutoff and the calculation applies the exact Sydney day.
  const before = end ? new Date(Date.parse(end + "T00:00:00Z") + 86_400_000).toISOString() : undefined;
  try {
    await Promise.all([
      (async () => {
        for await (const page of transactionPages(db, user.id, request.signal, before)) transactions.push(...page);
      })(),
      (async () => {
        const pageSize = 500;
        let lastId: string | undefined;
        do {
          let query = db.from("portfolio_stock_splits").select(splitFields).eq("user_id", user.id)
            .order("id").limit(pageSize).abortSignal(request.signal);
          if (end) query = query.lte("effective_date", end);
          if (lastId) query = query.gt("id", lastId);
          const { data, error } = await query.overrideTypes<StockSplit[], { merge: false }>();
          if (error) throw error;
          splits.push(...data);
          lastId = data.length === pageSize ? data[data.length - 1].id : undefined;
        } while (lastId);
      })(),
    ]);
  } catch {
    return jsonError(503, "unavailable", "Couldn’t export your lot report. Try again.");
  }

  const includesAud = currency === "AUD";
  let rows = calculateLots(transactions, start ?? undefined, end ?? undefined, undefined, splits);
  let references: ReadonlyMap<string, AudReference> = new Map();
  if (includesAud) {
    const trades = new Map<string, TransactionRow>();
    for (const row of rows) {
      if ("split" in row) continue;
      const { transaction, purchase } = row;
      if (transaction.type === "Sell") trades.set(transaction.id, transaction);
      if (purchase) trades.set(purchase.id, purchase);
    }
    references = await audReferences([...trades.values()], request.signal);
    const rates = new Map<string, string>();
    for (const [id, reference] of references) {
      if ("rate" in reference) rates.set(id, reference.rate);
    }
    rows = calculateLots(transactions, start ?? undefined, end ?? undefined, rates, splits);
  }
  const actionColumns = [
    ...(splits.length ? splitColumns : []),
    ...(splits.some((split) => split.snaptrade_activity_id) ? brokerSplitColumns : []),
  ];
  const reportColumns = [...columns, ...(includesAud ? audColumns : []), ...actionColumns];
  const period = `Requested sale window (Sydney dates) from ${start ?? "first recorded trade"} through ${end ?? "latest recorded trade"}.`;
  const information = includesAud ? `${disclaimer} ${audDisclosure} ${period}` : `${disclaimer} ${period}`;
  const records = [
    reportColumns.map(csvField).join(","),
    reportColumns.map((_, index) => index === 0 ? csvField("Report information")
      : index === noteColumn ? csvField(information) : "").join(","),
  ];
  for (const row of rows) {
    if ("split" in row) {
      const { split } = row;
      const holding = split.portfolio_holdings;
      const fields: Record<string, string | number | null> = {
        "Record type": row.kind,
        "Holding ID": split.holding_id,
        "Ticker": holding?.asset_symbol ?? null,
        "Exchange": holding?.asset_exchange ?? null,
        "Asset type": holding?.asset_kind ?? null,
        "Report note": row.note,
        "Transaction record source": split.snaptrade_activity_id ? "Statement entry with reviewed SnapTrade reference" : "Broker statement entry",
        "Split ID": split.id,
        "Split effective date (Sydney)": split.effective_date,
        "Split new shares": split.new_shares,
        "Split old shares": split.old_shares,
        "Split statement reference": split.statement_reference || null,
        "SnapTrade activity reference": split.snaptrade_activity_id,
        "SnapTrade reported date": split.snaptrade_activity_date,
        "SnapTrade reported activity": split.snaptrade_activity_label,
        "SnapTrade reported symbol": split.snaptrade_activity_symbol,
      };
      records.push(reportColumns.map((column) => csvField(fields[column] ?? null)).join(","));
      continue;
    }
    const transaction = row.transaction;
    const holding = transaction.portfolio_holdings;
    const text = [
      row.kind, transaction.holding_id, holding?.asset_symbol ?? null, holding?.asset_exchange ?? null,
      holding?.asset_kind ?? null, transaction.id, transaction.transaction_date, sydneyDate(transaction.transaction_date), row.purchase?.id ?? null,
      row.purchase?.transaction_date ?? null,
    ].map(csvField);
    const numbers = [
      lotNumber(row.units, UNIT_DECIMALS), lotNumber(row.purchaseCost, 2), lotNumber(row.purchaseFee, 2),
      lotNumber(row.saleProceeds, 2), lotNumber(row.saleFee, 2), lotNumber(row.result, 2),
    ];
    const cells = [...text, ...numbers, csvField(row.note ?? null),
      csvField(tradeSource(transaction.trade_provenance)),
      csvField(row.purchase ? tradeSource(row.purchase.trade_provenance) : null),
    ];
    if (includesAud) {
      cells.push(...[row.aud?.purchaseCost, row.aud?.purchaseFee, row.aud?.saleProceeds, row.aud?.saleFee, row.aud?.result]
        .map((value) => lotNumber(value, 2)),
        ...referenceFields(references, row.purchase),
        ...referenceFields(references, transaction.type === "Sell" ? transaction : undefined));
    }
    cells.push(...actionColumns.map(() => ""));
    records.push(cells.join(","));
  }
  return new Response(records.join("\r\n") + "\r\n", {
    headers: {
      "Cache-Control": "private, no-store",
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="stock-tracker-preliminary-fifo-lots-${includesAud ? "aud" : "usd"}.csv"`,
    },
  });
}
