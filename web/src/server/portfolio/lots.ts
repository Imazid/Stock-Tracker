import type { TransactionRow } from "./transactions.ts";

type Amounts = { gross?: bigint; fee?: bigint };
type Lot = { purchase: TransactionRow; units: bigint; usd: Amounts; aud: Amounts };
type Holding = { lots: Lot[]; next: number; invalid: boolean };
export type LotRow = {
  kind: "Sale match" | "Unmatched sale" | "Open lot" | "Archived holding lot" | "Invalid transaction" | "Position record";
  transaction: TransactionRow;
  purchase?: TransactionRow;
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

export function calculateLots(transactions: TransactionRow[], start?: string, end?: string, audRates?: ReadonlyMap<string, string>) {
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
    const rate = audRates?.get(transaction.id);
    const aud = audAmounts(transaction, units, scaled(rate));
    if (holding.invalid) {
      if (transaction.type === "Sell") {
        rows.push({
          kind: "Unmatched sale", transaction, units, saleProceeds: gross, saleFee: fee,
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
    const usd = { gross, fee };
    while (remaining > 0n && holding.next < holding.lots.length) {
      const lot = holding.lots[holding.next];
      const matched = remaining < lot.units ? remaining : lot.units;
      const purchase = takeAmounts(lot.usd, matched, lot.units);
      const sale = takeAmounts(usd, matched, remaining);
      const audPurchase = takeAmounts(lot.aud, matched, lot.units);
      const audSale = takeAmounts(aud, matched, remaining);
      if (visible) {
        const usdResult = result(purchase, sale);
        rows.push({
          kind: usdResult === undefined ? "Unmatched sale" : "Sale match", transaction, purchase: lot.purchase, units: matched,
          purchaseCost: purchase.gross, purchaseFee: purchase.fee, saleProceeds: sale.gross, saleFee: sale.fee,
          result: usdResult, note: usdResult === undefined ? "These units need an acquisition record with the trade date and cost." : undefined,
          aud: { purchaseCost: audPurchase.gross, purchaseFee: audPurchase.fee, saleProceeds: audSale.gross,
            saleFee: audSale.fee, result: result(audPurchase, audSale) },
        });
      }
      remaining -= matched;
      lot.units -= matched;
      if (lot.units === 0n) holding.next++;
    }
    if (remaining > 0n) {
      rows.push({
        kind: "Unmatched sale", transaction, units: remaining, saleProceeds: usd.gross, saleFee: usd.fee,
        aud: { saleProceeds: aud.gross, saleFee: aud.fee },
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
        kind: lot.usd.gross === undefined ? "Position record" : needsReview ? "Archived holding lot" : "Open lot",
        transaction: lot.purchase, purchase: lot.purchase,
        units: lot.units, purchaseCost: lot.usd.gross, purchaseFee: lot.usd.fee,
        aud: { purchaseCost: lot.aud.gross, purchaseFee: lot.aud.fee },
        note: lot.usd.gross === undefined ? "Use an acquisition record with the trade date and cost to establish basis for these units."
          : needsReview ? "The holding was archived. Check your iPhone and broker records for a closing trade or removal." : undefined,
      });
    }
  }
  return rows;
}
