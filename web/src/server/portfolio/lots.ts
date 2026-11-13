import type { TransactionRow } from "./transactions.ts";

type Lot = { purchase: TransactionRow; units: bigint; cost: bigint; fee: bigint };
type Holding = { lots: Lot[]; next: number; invalid: boolean };
export type LotRow = {
  kind: "Sale match" | "Unmatched sale" | "Open lot" | "Archived holding lot" | "Invalid transaction";
  transaction: TransactionRow;
  purchase?: TransactionRow;
  units?: bigint;
  purchaseCost?: bigint;
  purchaseFee?: bigint;
  saleProceeds?: bigint;
  saleFee?: bigint;
  result?: bigint;
  note?: string;
};

const sydneyDates = new Intl.DateTimeFormat("en-AU", { timeZone: "Australia/Sydney", year: "numeric", month: "2-digit", day: "2-digit" });

export function sydneyDate(timestamp: string) {
  const time = Date.parse(timestamp);
  if (!Number.isFinite(time)) return null;
  const { day, month, year } = Object.fromEntries(sydneyDates.formatToParts(time).map((part) => [part.type, part.value]));
  return `${year.padStart(4, "0")}-${month}-${day}`;
}

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

function scaled(value: number) {
  if (!Number.isFinite(value) || value < 0 || value >= 1e15) return undefined;
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

export function lotNumber(value: bigint | undefined, scale: number) {
  if (value === undefined) return "";
  const negative = value < 0n;
  const digits = (negative ? -value : value).toString().padStart(scale + 1, "0");
  const fraction = digits.slice(-scale).replace(/0+$/, "");
  return (negative ? "-" : "") + digits.slice(0, -scale) + (fraction ? "." + fraction : "");
}

export function calculateLots(transactions: TransactionRow[], start?: string, end?: string) {
  const rows: LotRow[] = [];
  const holdings = new Map<string, Holding>();
  const sorted = transactions.map((transaction) => ({ transaction, time: transactionTime(transaction.transaction_date) }))
    .sort((a, b) => a.time.milliseconds - b.time.milliseconds ||
      a.time.subMillisecond - b.time.subMillisecond ||
      Number(b.transaction.type === "Sell") - Number(a.transaction.type === "Sell") ||
      a.transaction.id.localeCompare(b.transaction.id));
  for (const { transaction } of sorted) {
    const date = sydneyDate(transaction.transaction_date);
    if (date && end && date > end) continue;
    const holding = holdings.get(transaction.holding_id) ?? { lots: [], next: 0, invalid: false };
    holdings.set(transaction.holding_id, holding);
    const visible = date && (!start || date >= start);
    const units = scaled(transaction.shares);
    const price = scaled(transaction.price_per_share);
    const fees = scaled(transaction.fees);
    if (!date || !units || price === undefined || fees === undefined || !["Buy", "Sell"].includes(transaction.type)) {
      holding.invalid = true;
      rows.push({
        kind: "Invalid transaction", transaction,
        note: "Review the date, side, quantity, price and fees in the transaction records. Matching stops here for this holding.",
      });
      continue;
    }
    const gross = roundedDivide(units * price * 100n, UNIT_SCALE * UNIT_SCALE);
    const fee = roundedDivide(fees * 100n, UNIT_SCALE);
    if (holding.invalid) {
      if (transaction.type === "Sell") {
        rows.push({
          kind: "Unmatched sale", transaction, units, saleProceeds: gross, saleFee: fee,
          note: "An earlier transaction in this holding needs review.",
        });
      }
      continue;
    }
    if (transaction.type === "Buy") {
      holding.lots.push({ purchase: transaction, units, cost: gross, fee });
      continue;
    }

    let remaining = units;
    let grossRemaining = gross;
    let feeRemaining = fee;
    while (remaining > 0n && holding.next < holding.lots.length) {
      const lot = holding.lots[holding.next];
      const matched = remaining < lot.units ? remaining : lot.units;
      const purchaseCost = roundedDivide(lot.cost * matched, lot.units);
      const purchaseFee = roundedDivide(lot.fee * matched, lot.units);
      const saleProceeds = roundedDivide(grossRemaining * matched, remaining);
      const saleFee = roundedDivide(feeRemaining * matched, remaining);
      if (visible) {
        rows.push({
          kind: "Sale match", transaction, purchase: lot.purchase, units: matched,
          purchaseCost, purchaseFee, saleProceeds, saleFee,
          result: saleProceeds - saleFee - purchaseCost - purchaseFee,
        });
      }
      remaining -= matched;
      grossRemaining -= saleProceeds;
      feeRemaining -= saleFee;
      lot.units -= matched;
      lot.cost -= purchaseCost;
      lot.fee -= purchaseFee;
      if (lot.units === 0n) holding.next++;
    }
    if (remaining > 0n) {
      rows.push({
        kind: "Unmatched sale", transaction, units: remaining, saleProceeds: grossRemaining, saleFee: feeRemaining,
        note: "The ledger has insufficient earlier purchases for this quantity.",
      });
    }
  }

  for (const { lots, next, invalid } of holdings.values()) {
    if (invalid) continue;
    for (const lot of lots.slice(next)) {
      const archived = lot.purchase.portfolio_holdings?.deleted_at;
      const archiveDate = archived && sydneyDate(archived);
      const needsReview = archiveDate && (!end || archiveDate <= end);
      rows.push({
        kind: needsReview ? "Archived holding lot" : "Open lot",
        transaction: lot.purchase, purchase: lot.purchase,
        units: lot.units, purchaseCost: lot.cost, purchaseFee: lot.fee,
        note: needsReview ? "The holding was archived. Check your iPhone and broker records for a closing trade or removal." : undefined,
      });
    }
  }
  return rows;
}
