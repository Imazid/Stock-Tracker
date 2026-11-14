import { csvField } from "@/lib/csv";
import { serverSupabase } from "@/lib/supabase/server";
import { jsonError } from "@/server/http/respond";
import { audReferences, type AudReference } from "@/server/portfolio/aud-rates";
import { calculateLots, lotNumber, sydneyDate, UNIT_DECIMALS } from "@/server/portfolio/lots";
import { readLotLedger } from "@/server/portfolio/lot-ledger";
import { tradeSource, type TransactionRow } from "@/server/portfolio/transactions";

const disclaimer = "Preliminary USD FIFO records for review. This report does not calculate tax. Verify actual lots, transaction-date AUD values, transfers, corporate actions and missing transactions. Trades with identical timestamps use sales before purchases. Saved splits apply before trades on the Sydney effective date. Sales use units on the sale date and open lots use units at the report end. Check fractional shares and cash payments against your statement. Use the transaction CSV for source amounts and bookkeeping FX.";
const columns = [
  "Record type", "Holding ID", "Ticker", "Exchange", "Asset type", "Transaction ID", "Transaction time (UTC)", "Transaction date (Sydney)",
  "Purchase ID", "Purchase time (UTC)", "Quantity", "Purchase cost (USD)", "Purchase fees (USD)",
  "Sale proceeds (USD)", "Sale fees (USD)", "Estimated FIFO result (USD)", "Report note", "Transaction record source", "Purchase record source",
];
const noteColumn = columns.indexOf("Report note");
const splitColumns = ["Split ID", "Split effective date (Sydney)", "Split new shares", "Split old shares", "Split statement reference"];
const brokerSplitColumns = ["SnapTrade activity reference", "SnapTrade reported date", "SnapTrade reported activity", "SnapTrade reported symbol"];
const reinvestmentColumns = ["Reinvestment ID", "Reinvestment acquisition date (Sydney)", "Reinvested amount", "Reinvestment currency", "Reinvestment statement reference"];
const brokerReinvestmentColumns = [
  "Reinvestment SnapTrade reference", "Reinvestment SnapTrade reported date", "Reinvestment SnapTrade reported symbol",
  "Reinvestment SnapTrade reported currency", "Reinvestment SnapTrade reported amount", "Reinvestment SnapTrade reported units",
];
const transferColumns = [
  "Transfer ID", "Transfer sent date (Sydney)", "Transfer received date (Sydney)", "Sending holding ID", "Receiving holding ID",
  "Sending account", "Receiving account", "Transfer statement reference", "Receiving snapshot ID",
  "Acquisition transfer IDs", "Original purchase date (Sydney)",
];
const brokerTransferColumns = ["Transfer SnapTrade sending reference", "Transfer SnapTrade receiving reference",
  "Transfer SnapTrade reported sent date", "Transfer SnapTrade reported received date", "Transfer SnapTrade reported symbol",
  "Transfer SnapTrade reported exchange", "Transfer SnapTrade reported shares"];
const audColumns = [
  "Purchase cost (AUD)", "Purchase fees (AUD)", "Sale proceeds (AUD)", "Sale fees (AUD)", "Estimated FIFO result (AUD)",
  "Purchase input currency", "Purchase FX (AUD per input currency unit)", "Purchase FX observation date", "Purchase FX source",
  "Sale input currency", "Sale FX (AUD per input currency unit)", "Sale FX observation date", "Sale FX source",
];
const audDisclosure = "AUD figures use original amounts. Foreign amounts use the latest common ECB observation on or before each Sydney trade date within seven days. ECB reference rates are indicative. AUD input uses a rate of one. Blank fields indicate unavailable source amounts or rates. The AUD result requires both prices and fees.";

function referenceFields(references: ReadonlyMap<string, AudReference>, trade?: TransactionRow) {
  const reference = trade && references.get(trade.id);
  return [
    csvField(trade?.reinvestment?.currency ?? trade?.trade_provenance?.currency ?? null),
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

  let ledger;
  try {
    ledger = await readLotLedger(db, user.id, request.signal, end ?? undefined);
  } catch {
    return jsonError(503, "unavailable", "Couldn’t export your lot report. Try again.");
  }
  const { transactions, acquisitions, splits, transfers } = ledger;
  const includesAud = currency === "AUD";
  let rows = calculateLots(transactions, start ?? undefined, end ?? undefined, undefined, splits, transfers);
  let references: ReadonlyMap<string, AudReference> = new Map();
  if (includesAud) {
    const trades = new Map<string, TransactionRow>();
    for (const row of rows) {
      if ("transfer" in row) {
        for (const purchase of row.purchases ?? []) trades.set(purchase.id, purchase);
        continue;
      }
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
    rows = calculateLots(transactions, start ?? undefined, end ?? undefined, rates, splits, transfers);
  }
  const actionColumns = [...(splits.length ? splitColumns : []),
    ...(splits.some((split) => split.snaptrade_activity_id) ? brokerSplitColumns : [])];
  const hasReinvestments = acquisitions.length > 0;
  const hasBrokerReinvestments = acquisitions.some((acquisition) => acquisition.reinvestment?.snaptrade_activity_id);
  const hasBrokerTransfers = transfers.some((transfer) => transfer.snaptrade_reference);
  const reportColumns = [...columns, ...(includesAud ? audColumns : []), ...actionColumns,
    ...(hasReinvestments ? reinvestmentColumns : []), ...(hasBrokerReinvestments ? brokerReinvestmentColumns : []),
    ...(transfers.length ? transferColumns : []), ...(hasBrokerTransfers ? brokerTransferColumns : [])];
  const period = `Requested sale window (Sydney dates) from ${start ?? "first recorded trade"} through ${end ?? "latest recorded trade"}.`;
  const ordering = hasReinvestments ? " Date-only reinvestment acquisitions follow timestamped trades on the same Sydney day. Check same-day sales against the actual allotment records." : "";
  const transferOrdering = transfers.length
    ? " Stock transfers move after the trades and reinvestments on their Sydney dates. Shares received from earlier departures are posted before same-day departures. Verify the stated timing and both account records."
    : "";
  const information = `${disclaimer}${ordering}${transferOrdering} ${includesAud ? audDisclosure + " " : ""}${period}`;
  const records = [
    reportColumns.map(csvField).join(","),
    reportColumns.map((_, index) => index === 0 ? csvField("Report information")
      : index === noteColumn ? csvField(information) : "").join(","),
  ];
  for (const row of rows) {
    if ("transfer" in row) {
      const { transfer } = row;
      const broker = transfer.snaptrade_reference;
      const fields: Record<string, string | null> = {
        "Record type": row.kind,
        "Holding ID": transfer.from_holding_id,
        "Ticker": transfer.source?.asset_symbol ?? null,
        "Exchange": transfer.source?.asset_exchange ?? null,
        "Asset type": transfer.source?.asset_kind ?? null,
        "Transaction date (Sydney)": transfer.sent_on,
        "Quantity": transfer.shares,
        "Purchase cost (USD)": lotNumber(row.usd?.gross, 2) || null,
        "Purchase fees (USD)": lotNumber(row.usd?.fee, 2) || null,
        "Purchase cost (AUD)": lotNumber(row.aud?.gross, 2) || null,
        "Purchase fees (AUD)": lotNumber(row.aud?.fee, 2) || null,
        "Report note": row.note,
        "Transaction record source": "Broker statement entry",
        "Transfer ID": transfer.id,
        "Transfer sent date (Sydney)": transfer.sent_on,
        "Transfer received date (Sydney)": transfer.received_on,
        "Sending holding ID": transfer.from_holding_id,
        "Receiving holding ID": transfer.to_holding_id,
        "Sending account": transfer.from_account,
        "Receiving account": transfer.to_account,
        "Transfer statement reference": transfer.statement_reference || null,
        "Receiving snapshot ID": transfer.receiving_snapshot_id,
        "Transfer SnapTrade sending reference": broker?.sentId ?? null,
        "Transfer SnapTrade receiving reference": broker?.receivedId ?? null,
        "Transfer SnapTrade reported sent date": broker?.sentOn ?? null,
        "Transfer SnapTrade reported received date": broker?.receivedOn ?? null,
        "Transfer SnapTrade reported symbol": broker?.symbol ?? null,
        "Transfer SnapTrade reported exchange": broker?.exchange ?? null,
        "Transfer SnapTrade reported shares": broker?.shares ?? null,
      };
      records.push(reportColumns.map((column) => csvField(fields[column] ?? null)).join(","));
      continue;
    }
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
      holding?.asset_kind ?? null, transaction.id, transaction.reinvestment ? null : transaction.transaction_date,
      transaction.reinvestment?.acquired_on ?? sydneyDate(transaction.transaction_date), row.purchase?.id ?? null,
      row.purchase?.reinvestment ? null : row.purchase?.transaction_date ?? null,
    ].map(csvField);
    const numbers = [
      lotNumber(row.units, UNIT_DECIMALS), lotNumber(row.purchaseCost, 2), lotNumber(row.purchaseFee, 2),
      lotNumber(row.saleProceeds, 2), lotNumber(row.saleFee, 2), lotNumber(row.result, 2),
    ];
    const cells = [...text, ...numbers, csvField(row.note ?? null),
      csvField(transaction.reinvestment ? "Dividend reinvestment" : tradeSource(transaction.trade_provenance)),
      csvField(row.purchase?.reinvestment ? "Dividend reinvestment" : row.purchase ? tradeSource(row.purchase.trade_provenance) : null),
    ];
    if (includesAud) {
      cells.push(...[row.aud?.purchaseCost, row.aud?.purchaseFee, row.aud?.saleProceeds, row.aud?.saleFee, row.aud?.result]
        .map((value) => lotNumber(value, 2)),
        ...referenceFields(references, row.purchase),
        ...referenceFields(references, transaction.type === "Sell" ? transaction : undefined));
    }
    cells.push(...actionColumns.map(() => ""));
    if (hasReinvestments) {
      const reinvestment = row.purchase?.reinvestment ?? transaction.reinvestment;
      cells.push(...[reinvestment?.id, reinvestment?.acquired_on, reinvestment?.reinvested_amount, reinvestment?.currency,
        reinvestment?.statement_reference].map((value) => csvField(value || null)));
      if (hasBrokerReinvestments) {
        cells.push(...[reinvestment?.snaptrade_activity_id, reinvestment?.snaptrade_reported_on, reinvestment?.snaptrade_reported_symbol,
          reinvestment?.snaptrade_reported_currency, reinvestment?.snaptrade_reported_amount,
          reinvestment?.snaptrade_reported_units].map((value) => csvField(value ?? null)));
      }
    }
    if (transfers.length) {
      const purchaseDay = row.purchase?.reinvestment?.acquired_on ??
        (row.purchase && sydneyDate(row.purchase.transaction_date));
      cells.push(...transferColumns.map((column) => {
        if (column === "Acquisition transfer IDs") return csvField(row.transfers?.join(" · ") ?? null);
        if (column === "Original purchase date (Sydney)") return csvField(purchaseDay ?? null);
        return "";
      }));
      if (hasBrokerTransfers) cells.push(...brokerTransferColumns.map(() => ""));
    }
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
