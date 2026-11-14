import type { TransactionRow } from "./transactions.ts";
import type { StockSplit } from "../../lib/portfolio-splits.ts";
import { matchesReceivingSnapshot, sameListedStock, sydneyDate, type StockTransfer } from "../../lib/portfolio-transfers.ts";

type Amounts = { gross?: bigint; fee?: bigint };
type Lot = { purchase: TransactionRow; units: bigint; usd: Amounts; aud: Amounts; transfers?: string[] };
type Holding = { lots: Lot[]; next: number; invalid: boolean };
type TradeLotRow = {
  kind: "Sale match" | "Unmatched sale" | "Open lot" | "Archived holding lot" | "Invalid transaction" | "Position record";
  transaction: TransactionRow;
  purchase?: TransactionRow;
  transfers?: string[];
  units?: bigint;
  purchaseCost?: bigint;
  purchaseFee?: bigint;
  saleProceeds?: bigint;
  saleFee?: bigint;
  result?: bigint;
  aud?: {
    purchaseCost?: bigint;
    purchaseFee?: bigint;
    saleProceeds?: bigint;
    saleFee?: bigint;
    result?: bigint;
  };
  note?: string;
};
type TransferRow = {
  kind: "Stock transfer" | "Transfer in transit" | "Unreconciled transfer";
  transfer: StockTransfer;
  purchases?: TransactionRow[];
  usd?: Amounts;
  aud?: Amounts;
  note: string;
};
export type LotRow = TradeLotRow | TransferRow | { kind: "Stock split" | "Reverse stock split"; split: StockSplit; note: string };

export { sydneyDate } from "../../lib/portfolio-transfers.ts";

function transactionTime(timestamp: string) {
  const milliseconds = Date.parse(timestamp);
  const fraction = (timestamp.match(/\.(\d+)/)?.[1] ?? "").padEnd(6, "0");
  return {
    milliseconds: Number.isFinite(milliseconds) ? milliseconds : -Infinity,
    subMillisecond: Number(fraction.slice(3, 6)),
  };
}

export const UNIT_DECIMALS = 18;
const UNIT_SCALE = 10n ** BigInt(UNIT_DECIMALS);

function scaled(value: number | string | null | undefined) {
  if (value == null) return undefined;
  if (typeof value === "number" && (!Number.isFinite(value) || value < 0 || value >= 1e15)) return undefined;
  if (typeof value === "string" && !/^(?:0|[1-9]\d{0,14})(?:\.\d{1,18})?$/.test(value)) return undefined;
  // Use the shortest decimal representation of the stored double.
  const [significand, exponent = "0"] = String(value).split("e");
  const [whole, fraction = ""] = significand.split(".");
  const units = BigInt(whole + fraction);
  const scale = UNIT_DECIMALS + Number(exponent) - fraction.length;
  return scale >= 0 ? units * 10n ** BigInt(scale) : roundedDivide(units, 10n ** BigInt(-scale));
}

function roundedDivide(numerator: bigint, denominator: bigint) {
  return (numerator + denominator / 2n) / denominator;
}

function audAmounts(transaction: TransactionRow, units: bigint, rate: bigint | undefined): Amounts {
  if (!rate) return {};
  if (transaction.reinvestment) {
    const basis = scaled(transaction.reinvestment.reinvested_amount);
    return { gross: basis === undefined ? undefined : roundedDivide(basis * rate * 100n, UNIT_SCALE ** 2n), fee: 0n };
  }
  const source = transaction.trade_provenance;
  if (source?.source === "csv_position" || source?.source === "broker_position") return {};
  const price = scaled(source?.unitPrice);
  const fee = scaled(source?.fees);
  return {
    gross: price === undefined ? undefined : roundedDivide(units * price * rate * 100n, UNIT_SCALE ** 3n),
    fee: fee === undefined ? undefined : roundedDivide(fee * rate * 100n, UNIT_SCALE ** 2n),
  };
}

function takeAmounts(amounts: Amounts, taken: bigint, remaining: bigint): Amounts {
  const gross = amounts.gross === undefined ? undefined : roundedDivide(amounts.gross * taken, remaining);
  const fee = amounts.fee === undefined ? undefined : roundedDivide(amounts.fee * taken, remaining);
  if (amounts.gross !== undefined && gross !== undefined) amounts.gross -= gross;
  if (amounts.fee !== undefined && fee !== undefined) amounts.fee -= fee;
  return { gross, fee };
}

function result(purchase: Amounts, sale: Amounts) {
  if (purchase.gross === undefined || purchase.fee === undefined || sale.gross === undefined || sale.fee === undefined) return undefined;
  return sale.gross - sale.fee - purchase.gross - purchase.fee;
}

export function lotNumber(value: bigint | undefined, scale: number) {
  if (value === undefined) return "";
  const negative = value < 0n;
  const digits = (negative ? -value : value).toString().padStart(scale + 1, "0");
  const fraction = digits.slice(-scale).replace(/0+$/, "");
  return (negative ? "-" : "") + digits.slice(0, -scale) + (fraction ? "." + fraction : "");
}

function datedTransaction(transaction: TransactionRow) {
  return { transaction, date: transaction.reinvestment?.acquired_on ?? sydneyDate(transaction.transaction_date),
    time: transactionTime(transaction.transaction_date) };
}

function compareTransactions(a: ReturnType<typeof datedTransaction>, b: ReturnType<typeof datedTransaction>) {
  return (a.date ?? "").localeCompare(b.date ?? "") ||
    Number(Boolean(a.transaction.reinvestment)) - Number(Boolean(b.transaction.reinvestment)) ||
    a.time.milliseconds - b.time.milliseconds || a.time.subMillisecond - b.time.subMillisecond ||
    Number(b.transaction.type === "Sell") - Number(a.transaction.type === "Sell") ||
    a.transaction.id.localeCompare(b.transaction.id);
}

function sumAmounts(lots: Lot[], currency: "usd" | "aud"): Amounts {
  let gross: bigint | undefined = 0n;
  let fee: bigint | undefined = 0n;
  for (const lot of lots) {
    const amount = lot[currency];
    gross = gross === undefined || amount.gross === undefined ? undefined : gross + amount.gross;
    fee = fee === undefined || amount.fee === undefined ? undefined : fee + amount.fee;
  }
  return { gross, fee };
}

function commonDivisor(a: bigint, b: bigint): bigint {
  while (b) [a, b] = [b, a % b];
  return a;
}

export function calculateLots(transactions: TransactionRow[], start?: string, end?: string, audRates?: ReadonlyMap<string, string>): TradeLotRow[];
export function calculateLots(transactions: TransactionRow[], start: string | undefined, end: string | undefined,
  audRates: ReadonlyMap<string, string> | undefined, splits: readonly StockSplit[]): Exclude<LotRow, TransferRow>[];
export function calculateLots(transactions: TransactionRow[], start: string | undefined, end: string | undefined,
  audRates: ReadonlyMap<string, string> | undefined, splits: readonly StockSplit[], transfers: readonly StockTransfer[]): LotRow[];
export function calculateLots(transactions: TransactionRow[], start?: string, end?: string, audRates?: ReadonlyMap<string, string>,
  splits: readonly StockSplit[] = [], transfers: readonly StockTransfer[] = []): LotRow[] {
  const rows: LotRow[] = [];
  const holdings = new Map<string, Holding>();
  const datedTransfers = transfers.filter((transfer) => !end || transfer.sent_on <= end);
  const validSnapshots = new Set<string>();
  const unsafeTransfers = new Set<string>();
  for (const transfer of datedTransfers) {
    if (!transfer.receiving_snapshot_id) continue;
    const snapshot = transfer.receiving_snapshot;
    if (snapshot?.id === transfer.receiving_snapshot_id && matchesReceivingSnapshot(transfer, sydneyDate(snapshot.transaction_date)) &&
        scaled(snapshot.shares) === scaled(transfer.shares)) {
      validSnapshots.add(snapshot.id);
    } else {
      unsafeTransfers.add(transfer.id);
    }
  }
  const sorted = transactions.filter((transaction) => !validSnapshots.has(transaction.id))
    .map(datedTransaction).sort(compareTransactions);
  const tradeOrder = new Map(sorted.map(({ transaction }, index) => [transaction.id, index]));
  const datedSplits = splits.filter((split) => !end || split.effective_date <= end)
    .sort((a, b) => a.effective_date.localeCompare(b.effective_date) || a.id.localeCompare(b.id));
  // A common integer unit per holding makes ratios such as 1 for 3 exact
  // internally. On the effective day the conversion factor changes. Original
  // lot costs, fees and acquisition dates stay attached to the same units.
  const factors = new Map<string, bigint>();
  for (const split of datedSplits) {
    factors.set(split.holding_id, (factors.get(split.holding_id) ?? 1n) * BigInt(split.new_shares));
  }
  let nextSplit = 0;
  function applySplits(through: string) {
    while (nextSplit < datedSplits.length && datedSplits[nextSplit].effective_date <= through) {
      const split = datedSplits[nextSplit++];
      const factor = factors.get(split.holding_id) ?? 1n;
      factors.set(split.holding_id, factor / BigInt(split.new_shares) * BigInt(split.old_shares));
      rows.push({
        kind: split.new_shares > split.old_shares ? "Stock split" : "Reverse stock split",
        split, note: "Statement adjustment effective before trades dated that day.",
      });
    }
  }
  const transferDays = new Map<string, { arrivals: StockTransfer[]; departures: StockTransfer[] }>();
  const stockHoldings = new Map<string, TransactionRow["portfolio_holdings"]>();
  const inTransit = new Map<string, { lots: Lot[]; factor: bigint }>();

  function eventsOn(day: string) {
    const events = transferDays.get(day) ?? { arrivals: [], departures: [] };
    transferDays.set(day, events);
    return events;
  }

  for (const transfer of datedTransfers) {
    eventsOn(transfer.sent_on).departures.push(transfer);
    if (transfer.received_on > transfer.sent_on && (!end || transfer.received_on <= end)) {
      eventsOn(transfer.received_on).arrivals.push(transfer);
    }
    stockHoldings.set(transfer.from_holding_id, transfer.source);
    stockHoldings.set(transfer.to_holding_id, transfer.destination);
  }

  function holdingFor(id: string) {
    const holding = holdings.get(id) ?? { lots: [], next: 0, invalid: false };
    holdings.set(id, holding);
    return holding;
  }

  function flagTransfer(transfer: StockTransfer, note: string) {
    holdingFor(transfer.from_holding_id).invalid = true;
    holdingFor(transfer.to_holding_id).invalid = true;
    rows.push({ kind: "Unreconciled transfer", transfer, note });
  }

  function receive(transfer: StockTransfer) {
    const shipment = inTransit.get(transfer.id);
    if (!shipment) return;
    const destination = holdingFor(transfer.to_holding_id);
    const priorFactor = factors.get(transfer.to_holding_id) ?? 1n;
    // Preserve fractions exactly even when the two holdings have different split histories.
    const multiplier = shipment.factor / commonDivisor(shipment.factor, priorFactor);
    const factor = priorFactor * multiplier;
    if (multiplier > 1n) {
      factors.set(transfer.to_holding_id, factor);
      for (const lot of destination.lots) lot.units *= multiplier;
    }
    for (const lot of shipment.lots) lot.units *= factor / shipment.factor;
    destination.lots = destination.lots.slice(destination.next).concat(shipment.lots)
      .sort((a, b) => tradeOrder.get(a.purchase.id)! - tradeOrder.get(b.purchase.id)!);
    destination.next = 0;
    inTransit.delete(transfer.id);
  }

  function dispatch(transfer: StockTransfer) {
    const source = holdingFor(transfer.from_holding_id);
    const destination = holdingFor(transfer.to_holding_id);
    const shares = scaled(transfer.shares);
    if (!shares || !sameListedStock(transfer.source, transfer.destination) || unsafeTransfers.has(transfer.id)) {
      flagTransfer(transfer, "Check the two stock holdings and the receiving position snapshot against the transfer statement.");
      return;
    }
    if (datedSplits.some((split) => [transfer.from_holding_id, transfer.to_holding_id].includes(split.holding_id) &&
        split.effective_date > transfer.sent_on && split.effective_date <= transfer.received_on)) {
      flagTransfer(transfer, "A split occurred while these shares were in transit. Reconcile the quantity with both statements.");
      return;
    }
    const factor = factors.get(transfer.from_holding_id) ?? 1n;
    let remaining = shares * factor;
    const available = source.lots.slice(source.next).reduce((sum, lot) => sum + lot.units, 0n);
    if (source.invalid || destination.invalid || available < remaining) {
      flagTransfer(transfer, "The transfer cannot be reconciled against the earlier lots. Check the source history and transfer order before using later matches.");
      return;
    }
    const moved: Lot[] = [];
    while (remaining > 0n) {
      const lot = source.lots[source.next];
      const units = remaining < lot.units ? remaining : lot.units;
      moved.push({ purchase: lot.purchase, units, usd: takeAmounts(lot.usd, units, lot.units),
        aud: takeAmounts(lot.aud, units, lot.units), transfers: [...(lot.transfers ?? []), transfer.id] });
      remaining -= units;
      lot.units -= units;
      if (!lot.units) source.next++;
    }
    inTransit.set(transfer.id, { lots: moved, factor });
    if (transfer.sent_on === transfer.received_on) receive(transfer);
    const pending = Boolean(end && transfer.received_on > end);
    rows.push({
      kind: pending ? "Transfer in transit" : "Stock transfer",
      transfer, purchases: moved.map((lot) => lot.purchase), usd: sumAmounts(moved, "usd"), aud: sumAmounts(moved, "aud"),
      note: pending ? "The shares had left the sending holding and were still in transit at the report end."
        : "Earlier FIFO lots moved with their original acquisition dates and cost. The transfer did not create sale proceeds.",
    });
  }

  const transferDates = [...transferDays.keys()].sort();
  let nextTransferDay = 0;
  function applyTransfersBefore(through: string) {
    while (nextTransferDay < transferDates.length && transferDates[nextTransferDay] < through) {
      const day = transferDates[nextTransferDay++];
      applySplits(day);
      const events = transferDays.get(day)!;
      for (const transfer of events.arrivals.sort((a, b) => a.id.localeCompare(b.id))) receive(transfer);
      for (const transfer of events.departures.sort((a, b) => a.same_day_order - b.same_day_order || a.id.localeCompare(b.id))) dispatch(transfer);
    }
  }

  for (const { transaction, date } of sorted) {
    if (date && end && date > end) continue;
    if (date) {
      applyTransfersBefore(date);
      applySplits(date);
    }
    const holding = holdingFor(transaction.holding_id);
    const visible = date && (!start || date >= start);
    const tradeUnits = scaled(transaction.shares);
    const price = scaled(transaction.price_per_share);
    const fees = scaled(transaction.fees);
    if (!date || !tradeUnits || price === undefined || fees === undefined || !["Buy", "Sell"].includes(transaction.type)) {
      holding.invalid = true;
      rows.push({
        kind: "Invalid transaction", transaction,
        note: "Review the date, side, quantity, price and fees in the transaction records. Matching stops here for this holding.",
      });
      continue;
    }
    const factor = factors.get(transaction.holding_id) ?? 1n;
    const units = tradeUnits * factor;
    const reinvestment = transaction.reinvestment;
    const recordedBasis = reinvestment && scaled(reinvestment.currency === "USD" ? reinvestment.reinvested_amount : reinvestment.basis_usd);
    const gross = reinvestment ? (recordedBasis === undefined ? undefined : roundedDivide(recordedBasis * 100n, UNIT_SCALE))
      : roundedDivide(tradeUnits * price * 100n, UNIT_SCALE * UNIT_SCALE);
    const fee = roundedDivide(fees * 100n, UNIT_SCALE);
    const rate = audRates?.get(transaction.id);
    const aud = audAmounts(transaction, tradeUnits, scaled(rate));
    if (holding.invalid) {
      if (transaction.type === "Sell") {
        rows.push({
          kind: "Unmatched sale", transaction, units: tradeUnits, saleProceeds: gross, saleFee: fee,
          aud: { saleProceeds: aud.gross, saleFee: aud.fee }, note: "An earlier transaction in this holding needs review.",
        });
      }
      continue;
    }
    if (transaction.type === "Buy") {
      const source = transaction.trade_provenance;
      const unknown = source && (source.source === "csv_position" || source.source === "broker_position" || source.unitPrice == null);
      holding.lots.push({ purchase: transaction, units, usd: unknown ? {} : { gross, fee }, aud });
      continue;
    }

    let remaining = units;
    let displayedRemaining = tradeUnits;
    const usd = { gross, fee };
    while (remaining > 0n && holding.next < holding.lots.length) {
      const lot = holding.lots[holding.next];
      const matched = remaining < lot.units ? remaining : lot.units;
      const displayed = roundedDivide(matched * displayedRemaining, remaining);
      const purchase = takeAmounts(lot.usd, matched, lot.units);
      const sale = takeAmounts(usd, matched, remaining);
      const audPurchase = takeAmounts(lot.aud, matched, lot.units);
      const audSale = takeAmounts(aud, matched, remaining);
      if (visible) {
        const usdResult = result(purchase, sale);
        const audResult = result(audPurchase, audSale);
        const knownReinvestment = lot.purchase.reinvestment !== undefined;
        rows.push({
          kind: usdResult !== undefined || knownReinvestment ? "Sale match" : "Unmatched sale", transaction, purchase: lot.purchase,
          units: displayed, transfers: lot.transfers,
          purchaseCost: purchase.gross, purchaseFee: purchase.fee, saleProceeds: sale.gross, saleFee: sale.fee,
          result: usdResult, note: knownReinvestment && usdResult === undefined
            ? "The statement does not have a USD basis for these reinvested shares."
            : usdResult === undefined ? "These units need an acquisition record with the trade date and cost." : undefined,
          aud: { purchaseCost: audPurchase.gross, purchaseFee: audPurchase.fee, saleProceeds: audSale.gross,
            saleFee: audSale.fee, result: audResult },
        });
      }
      remaining -= matched;
      displayedRemaining -= displayed;
      lot.units -= matched;
      if (lot.units === 0n) holding.next++;
    }
    if (remaining > 0n) {
      rows.push({
        kind: "Unmatched sale", transaction, units: displayedRemaining, saleProceeds: usd.gross, saleFee: usd.fee,
        aud: { saleProceeds: aud.gross, saleFee: aud.fee },
        note: "The ledger has insufficient earlier purchases for this quantity.",
      });
    }
  }

  applyTransfersBefore("9999-01-01");
  applySplits(end ?? "9998-12-31");
  for (const [holdingId, { lots, next, invalid }] of holdings) {
    if (invalid) continue;
    for (const lot of lots.slice(next)) {
      const holding = stockHoldings.get(holdingId) ?? lot.purchase.portfolio_holdings;
      const archived = holding?.deleted_at;
      const transaction = lot.transfers ? { ...lot.purchase, holding_id: holdingId, portfolio_holdings: holding } : lot.purchase;
      const archiveDate = archived && sydneyDate(archived);
      const needsReview = archiveDate && (!end || archiveDate <= end);
      rows.push({
        kind: lot.usd.gross === undefined && !lot.purchase.reinvestment ? "Position record" : needsReview ? "Archived holding lot" : "Open lot",
        transaction, purchase: lot.purchase, transfers: lot.transfers,
        units: roundedDivide(lot.units, factors.get(holdingId) ?? 1n), purchaseCost: lot.usd.gross, purchaseFee: lot.usd.fee,
        aud: { purchaseCost: lot.aud.gross, purchaseFee: lot.aud.fee },
        note: lot.usd.gross === undefined ? (lot.purchase.reinvestment
            ? "The statement does not have a USD basis for these reinvested shares."
            : "Use an acquisition record with the trade date and cost to establish basis for these units.")
          : needsReview ? "The holding was archived. Check your iPhone and broker records for a closing trade or removal." : undefined,
      });
    }
  }
  return rows;
}
