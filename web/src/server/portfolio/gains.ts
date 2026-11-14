import type { OpenCost, PortfolioGains } from "../../lib/portfolio-gains.ts";
import { calculateLots, ledgerFeeCents, lotNumber, UNIT_DECIMALS, sydneyDate } from "./lots.ts";
import type { readLotLedger } from "./lot-ledger.ts";

export function portfolioGains(owner: string, asOf: string, { transactions, splits, transfers }: Awaited<ReturnType<typeof readLotLedger>>): PortfolioGains {
  const day = sydneyDate(asOf)!;
  const through = Date.parse(asOf);
  const trades = transactions.filter((trade) => trade.reinvestment ? trade.reinvestment.acquired_on <= day
    : !Number.isFinite(Date.parse(trade.transaction_date)) || Date.parse(trade.transaction_date) <= through);
  const rows = calculateLots(trades, undefined, day, undefined, splits, transfers);
  const sales = new Map<string, { matched: boolean; missing: boolean }>();
  let realised = 0n;
  let matchedRows = 0;
  let fees = 0n;
  let tradeRecords = 0;
  let feeRecords = 0;
  for (const trade of trades) {
    if (trade.reinvestment || !["Buy", "Sell"].includes(trade.type) ||
        trade.trade_provenance?.source === "broker_position" || trade.trade_provenance?.source === "csv_position") continue;
    tradeRecords++;
    const fee = ledgerFeeCents(trade.fees);
    if (fee !== undefined) {
      feeRecords++;
      fees += fee;
    }
    if (trade.type === "Sell") sales.set(trade.id, { matched: false, missing: false });
  }

  const openLots = new Map<string, { units: bigint; cost: bigint; unknown: boolean }>();
  const splitDates = new Map<string, string>();
  const archived = new Set<string>();
  let pendingTransfers = 0;
  for (const row of rows) {
    if ("transfer" in row) {
      if (row.kind !== "Stock transfer") pendingTransfers++;
      continue;
    }
    if ("split" in row) {
      splitDates.set(row.split.holding_id, row.split.effective_date);
      continue;
    }
    const sale = sales.get(row.transaction.id);
    if (sale) {
      if (row.result === undefined) sale.missing = true;
      else {
        sale.matched = true;
        matchedRows++;
        realised += row.result;
      }
      continue;
    }
    if (!row.units || !["Open lot", "Archived holding lot", "Position record"].includes(row.kind)) continue;
    const { holding_id: id, portfolio_holdings: holding } = row.transaction;
    if (holding?.deleted_at && Date.parse(holding.deleted_at) <= through) {
      archived.add(id);
      continue;
    }
    const lot = openLots.get(id) ?? { units: 0n, cost: 0n, unknown: false };
    lot.units += row.units;
    if (row.purchaseCost === undefined || row.purchaseFee === undefined) lot.unknown = true;
    else lot.cost += row.purchaseCost + row.purchaseFee;
    openLots.set(id, lot);
  }
  let matchedSales = 0;
  let partialSales = 0;
  for (const sale of sales.values()) {
    if (sale.matched && !sale.missing) matchedSales++;
    if (sale.matched && sale.missing) partialSales++;
  }
  const open = Object.fromEntries([...openLots].map(([id, lot]) => [id, {
    units: lotNumber(lot.units, UNIT_DECIMALS), costUsd: lot.unknown ? null : Number(lotNumber(lot.cost, 2)), lastSplit: splitDates.get(id),
  } satisfies OpenCost]));
  return {
    owner, asOf, realisedUsd: matchedRows ? Number(lotNumber(realised, 2)) : null,
    sales: sales.size, matchedSales, partialSales, feesUsd: feeRecords ? Number(lotNumber(fees, 2)) : null,
    tradeRecords, feeRecords, archivedLots: archived.size, pendingTransfers, open,
  };
}
