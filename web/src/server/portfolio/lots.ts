import type { TransactionRow } from "./transactions.ts";
import { fractionalShareCash, type StockSplit } from "../../lib/portfolio-splits.ts";
import { matchesReceivingSnapshot, sameListedStock, sydneyDate, type StockTransfer } from "../../lib/portfolio-transfers.ts";
import { distinctSpinOffHoldings, matchesSpinOffSnapshot, spinOffPercent, type StockSpinOff } from "../../lib/portfolio-spin-offs.ts";
import { lotUnits as scaled, UNIT_SCALE } from "../../lib/lot-numbers.ts";

export { UNIT_DECIMALS } from "../../lib/lot-numbers.ts";

type Amounts = { gross?: bigint; fee?: bigint };
type Lot = { purchase: TransactionRow; units: bigint; usd: Amounts; aud: Amounts; transfers?: string[]; spinOffs?: string[]; allottedOn?: string };
type Holding = { lots: Lot[]; next: number; invalid: boolean };
type TradeLotRow = {
  kind: "Sale match" | "Unmatched sale" | "Open lot" | "Archived holding lot" | "Invalid transaction" | "Position record";
  transaction: TransactionRow;
  purchase?: TransactionRow;
  transfers?: string[];
  spinOffs?: string[];
  allottedOn?: string;
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
type SpinOffRow = {
  kind: "Stock spin-off" | "Unreconciled spin-off";
  spinOff: StockSpinOff;
  purchases?: TransactionRow[];
  usd?: Amounts;
  aud?: Amounts;
  note: string;
};
export type LotRow = TradeLotRow | TransferRow | SpinOffRow | { kind: "Stock split" | "Reverse stock split"; split: StockSplit; note: string };

export { sydneyDate } from "../../lib/portfolio-transfers.ts";

function transactionTime(timestamp: string) {
  const milliseconds = Date.parse(timestamp);
  const fraction = (timestamp.match(/\.(\d+)/)?.[1] ?? "").padEnd(6, "0");
  return {
    milliseconds: Number.isFinite(milliseconds) ? milliseconds : -Infinity,
    subMillisecond: Number(fraction.slice(3, 6)),
  };
}

export function ledgerFeeCents(fee: number) {
  const units = scaled(fee);
  return units === undefined ? undefined : roundedDivide(units * 100n, UNIT_SCALE);
}

function roundedDivide(numerator: bigint, denominator: bigint) {
  return (numerator + denominator / 2n) / denominator;
}

function audAmounts(transaction: TransactionRow, units: bigint, rate: bigint | undefined): Amounts {
  if (!rate) return {};
  if (transaction.fractionalCash) {
    const gross = scaled(transaction.fractionalCash.fraction_proceeds)!;
    const fees = scaled(transaction.fractionalCash.fraction_fees)!;
    return { gross: roundedDivide(gross * rate * 100n, UNIT_SCALE ** 2n),
      fee: roundedDivide(fees * rate * 100n, UNIT_SCALE ** 2n) };
  }
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

function allocateBasis(amounts: Amounts, percent: bigint, scale: bigint): Amounts {
  const original = { ...amounts };
  const allocated = takeAmounts(amounts, percent, scale);
  if (original.gross !== undefined && original.fee !== undefined && allocated.fee !== undefined) {
    const total = roundedDivide((original.gross + original.fee) * percent, scale);
    allocated.gross = total - allocated.fee;
    amounts.gross = original.gross - allocated.gross;
  }
  return allocated;
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
  audRates: ReadonlyMap<string, string> | undefined, splits: readonly StockSplit[]): Exclude<LotRow, TransferRow | SpinOffRow>[];
export function calculateLots(transactions: TransactionRow[], start: string | undefined, end: string | undefined,
  audRates: ReadonlyMap<string, string> | undefined, splits: readonly StockSplit[], transfers: readonly StockTransfer[]): Exclude<LotRow, SpinOffRow>[];
export function calculateLots(transactions: TransactionRow[], start: string | undefined, end: string | undefined,
  audRates: ReadonlyMap<string, string> | undefined, splits: readonly StockSplit[], transfers: readonly StockTransfer[],
  spinOffs: readonly StockSpinOff[]): LotRow[];
export function calculateLots(transactions: TransactionRow[], start?: string, end?: string, audRates?: ReadonlyMap<string, string>,
  splits: readonly StockSplit[] = [], transfers: readonly StockTransfer[] = [], spinOffs: readonly StockSpinOff[] = []): LotRow[] {
  const rows: LotRow[] = [];
  const holdings = new Map<string, Holding>();
  const datedTransfers = transfers.filter((transfer) => !end || transfer.sent_on <= end);
  const datedSpinOffs = spinOffs.filter((action) => !end || action.effective_on <= end);
  const snapshotOwners = new Map<string, string[]>();
  const unsafeTransfers = new Set<string>();
  const unsafeSpinOffs = new Set<string>();
  function claimSnapshot(id: string, actionId: string) {
    const owners = snapshotOwners.get(id) ?? [];
    owners.push(actionId);
    snapshotOwners.set(id, owners);
  }
  for (const transfer of datedTransfers) {
    if (!transfer.receiving_snapshot_id) continue;
    const snapshot = transfer.receiving_snapshot;
    if (snapshot?.id === transfer.receiving_snapshot_id && matchesReceivingSnapshot(transfer, sydneyDate(snapshot.transaction_date)) &&
        scaled(snapshot.shares) === scaled(transfer.shares)) {
      claimSnapshot(snapshot.id, transfer.id);
    } else {
      unsafeTransfers.add(transfer.id);
    }
  }
  const positionSnapshots = new Map<string, TransactionRow[]>();
  if (datedSpinOffs.length) for (const transaction of transactions) {
    if (transaction.trade_provenance?.source !== "broker_position" && transaction.trade_provenance?.source !== "csv_position") continue;
    const snapshots = positionSnapshots.get(transaction.holding_id) ?? [];
    snapshots.push(transaction);
    positionSnapshots.set(transaction.holding_id, snapshots);
  }
  for (const action of datedSpinOffs) {
    if (!action.child_snapshot_id) {
      if (positionSnapshots.get(action.child_holding_id)?.some((transaction) => {
        const date = sydneyDate(transaction.transaction_date);
        return date && date >= action.effective_on && (!end || date <= end) && transaction.type === "Buy" &&
          scaled(transaction.shares) === scaled(action.child_shares);
      })) unsafeSpinOffs.add(action.id);
      continue;
    }
    const snapshot = action.child_snapshot;
    if (snapshot?.id === action.child_snapshot_id && matchesSpinOffSnapshot(snapshot, action.child_holding_id, action.effective_on, action.child_shares)) {
      claimSnapshot(snapshot.id, action.id);
    } else {
      unsafeSpinOffs.add(action.id);
    }
  }
  const validSnapshots = new Set<string>();
  for (const [id, owners] of snapshotOwners) {
    if (owners.length === 1) validSnapshots.add(id);
    else for (const owner of owners) {
      unsafeSpinOffs.add(owner);
      unsafeTransfers.add(owner);
    }
  }
  const sorted = transactions.filter((transaction) => !validSnapshots.has(transaction.id))
    .map(datedTransaction).sort(compareTransactions);
  const tradeOrder = new Map(sorted.map(({ transaction, date }, index) => [transaction.id, { index, date }]));
  function compareLots(a: Lot, b: Lot) {
    const aOrder = tradeOrder.get(a.purchase.id)!;
    const bOrder = tradeOrder.get(b.purchase.id)!;
    return (a.allottedOn ?? aOrder.date ?? "").localeCompare(b.allottedOn ?? bOrder.date ?? "") ||
      Number(Boolean(b.allottedOn)) - Number(Boolean(a.allottedOn)) || aOrder.index - bOrder.index;
  }
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
      const postSplitFactor = factor / BigInt(split.new_shares) * BigInt(split.old_shares);
      factors.set(split.holding_id, postSplitFactor);
      rows.push({
        kind: split.new_shares > split.old_shares ? "Stock split" : "Reverse stock split",
        split, note: "Statement adjustment effective before trades dated that day.",
      });
      applyFractionalCash(split, postSplitFactor);
    }
  }
  type DayActions = { arrivals: StockTransfer[]; departures: StockTransfer[]; spinOffs: StockSpinOff[] };
  const actionDays = new Map<string, DayActions>();
  const stockHoldings = new Map<string, TransactionRow["portfolio_holdings"]>();
  const inTransit = new Map<string, { lots: Lot[]; factor: bigint }>();

  function eventsOn(day: string) {
    const events = actionDays.get(day) ?? { arrivals: [], departures: [], spinOffs: [] };
    actionDays.set(day, events);
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

  for (const action of datedSpinOffs) {
    eventsOn(action.effective_on).spinOffs.push(action);
    stockHoldings.set(action.parent_holding_id, action.parent);
    stockHoldings.set(action.child_holding_id, action.child);
  }

  function holdingFor(id: string) {
    const holding = holdings.get(id) ?? { lots: [], next: 0, invalid: false };
    holdings.set(id, holding);
    return holding;
  }

  function applyFractionalCash(split: StockSplit, factor: bigint) {
    const cash = fractionalShareCash(split);
    if (!cash) return;
    const holding = holdingFor(split.holding_id);
    const transaction: TransactionRow = {
      id: split.id, holding_id: split.holding_id, transaction_date: "",
      type: "Sell", shares: cash.fraction_shares, price_per_share: 0, fees: 0, fractionalCash: cash,
      portfolio_holdings: split.portfolio_holdings && { ...split.portfolio_holdings, deleted_at: null },
    };
    const tradeUnits = scaled(cash.fraction_shares);
    const paid = !end || cash.fraction_paid_on <= end;
    const visible = paid && (!start || cash.fraction_paid_on >= start);
    let remaining = (tradeUnits ?? 0n) * factor;
    let displayedRemaining = tradeUnits ?? 0n;
    const available = holding.lots.slice(holding.next).reduce((sum, lot) => sum + lot.units, 0n);
    if (holding.invalid || !tradeUnits || available < remaining) {
      holding.invalid = true;
      if (visible || (!paid && (!start || split.effective_date >= start))) {
        rows.push({ kind: "Unmatched sale", transaction, units: tradeUnits,
          note: "The fractional units could not be matched against pre-split lots. Check the earlier acquisitions and statement quantity." });
      }
      return;
    }
    const net = scaled(cash.fraction_net_usd);
    const gross = scaled(cash.fraction_proceeds)!;
    const fees = scaled(cash.fraction_fees)!;
    const asCents = (amount: bigint) => roundedDivide(amount * 100n, UNIT_SCALE);
    const usd: Amounts = !paid ? {} : cash.fraction_currency === "USD"
      ? { gross: asCents(gross), fee: asCents(fees) }
      : net === undefined ? {} : { gross: asCents(net), fee: 0n };
    const aud = paid ? audAmounts(transaction, tradeUnits, scaled(audRates?.get(transaction.id))) : {};
    while (remaining > 0n) {
      const lot = holding.lots[holding.next];
      const matched = remaining < lot.units ? remaining : lot.units;
      const units = roundedDivide(matched * displayedRemaining, remaining);
      const purchase = takeAmounts(lot.usd, matched, lot.units);
      const sale = takeAmounts(usd, matched, remaining);
      const audPurchase = takeAmounts(lot.aud, matched, lot.units);
      const audSale = takeAmounts(aud, matched, remaining);
      if (visible || (!paid && (!start || split.effective_date >= start))) {
        const usdResult = result(purchase, sale);
        rows.push({
          kind: usdResult !== undefined ? "Sale match" : "Unmatched sale", transaction, purchase: lot.purchase, units,
          transfers: lot.transfers, spinOffs: lot.spinOffs, allottedOn: lot.allottedOn,
          purchaseCost: purchase.gross, purchaseFee: purchase.fee, saleProceeds: sale.gross, saleFee: sale.fee, result: usdResult,
          aud: { purchaseCost: audPurchase.gross, purchaseFee: audPurchase.fee, saleProceeds: audSale.gross,
            saleFee: audSale.fee, result: result(audPurchase, audSale) },
          note: !paid ? "The fractional units were removed. Payment is after the report end."
            : usdResult === undefined ? "Review the acquisition cost and the statement USD amount."
            : cash.fraction_currency === "USD" ? "Statement payment for fractional shares. Review actual lot selection."
            : "USD proceeds show the statement net amount. Original proceeds and fees are shown in the payment currency.",
        });
      }
      remaining -= matched;
      displayedRemaining -= units;
      lot.units -= matched;
      if (lot.units === 0n) holding.next++;
    }
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
      .sort(compareLots);
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
    if (datedSpinOffs.some((action) => [transfer.from_holding_id, transfer.to_holding_id].includes(action.parent_holding_id) &&
        action.effective_on > transfer.sent_on && action.effective_on <= transfer.received_on)) {
      flagTransfer(transfer, "A spin-off occurred while these shares were in transit. Check which account received the allotment.");
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
      moved.push({ ...lot, units, usd: takeAmounts(lot.usd, units, lot.units),
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

  function applySpinOff(action: StockSpinOff, conflicts: boolean) {
    const parent = holdingFor(action.parent_holding_id);
    const child = holdingFor(action.child_holding_id);
    const lots = parent.lots.slice(parent.next);
    const total = lots.reduce((sum, lot) => sum + lot.units, 0n);
    const parentShares = scaled(action.parent_shares);
    const childShares = scaled(action.child_shares);
    const usdPercent = spinOffPercent(action.child_basis_pct_usd);
    const audPercent = spinOffPercent(action.child_basis_pct_aud);
    const percentScale = UNIT_SCALE * 100n;
    if (conflicts || unsafeSpinOffs.has(action.id) || !distinctSpinOffHoldings(action.parent, action.child) ||
        parent.invalid || child.invalid || !parentShares || !childShares || (!usdPercent && !audPercent) ||
        roundedDivide(total, factors.get(action.parent_holding_id) ?? 1n) !== parentShares) {
      parent.invalid = true;
      child.invalid = true;
      rows.push({ kind: "Unreconciled spin-off", spinOff: action,
        note: conflicts ? "More than one spin-off affects a holding on this date. Check the action order and combined basis."
          : "Check the stock listings, parent quantity before the allotment, earlier lots and the child position snapshot." });
      return;
    }
    const oldChildFactor = factors.get(action.child_holding_id) ?? 1n;
    const multiplier = total / commonDivisor(total, childShares * oldChildFactor);
    const childFactor = oldChildFactor * multiplier;
    factors.set(action.child_holding_id, childFactor);
    if (multiplier > 1n) for (const lot of child.lots) lot.units *= multiplier;

    const totalChildUnits = childShares * childFactor;
    const average = action.average_aud_basis && audPercent ? sumAmounts(lots, "aud") : undefined;
    const averageChild = average && audPercent ? allocateBasis(average, audPercent, percentScale) : undefined;
    let previousUnits = 0n;
    // Allocate each averaged pool cumulatively so both sides keep their full
    // cents and a rounding remainder never becomes dependent on later sales.
    function averagedPart(pool: Amounts, until: bigint): Amounts {
      const part = (amount?: bigint) => amount === undefined ? undefined
        : roundedDivide(amount * until, total) - roundedDivide(amount * previousUnits, total);
      return { gross: part(pool.gross), fee: part(pool.fee) };
    }
    const allotted = lots.map((lot): Lot => {
      const until = previousUnits + lot.units;
      const usd = usdPercent ? allocateBasis(lot.usd, usdPercent, percentScale) : {};
      if (!usdPercent) lot.usd = {};
      const aud = averageChild ? averagedPart(averageChild, until) : audPercent ? allocateBasis(lot.aud, audPercent, percentScale) : {};
      if (average) lot.aud = averagedPart(average, until);
      else if (!audPercent) lot.aud = {};
      previousUnits = until;
      lot.spinOffs = [...(lot.spinOffs ?? []), action.id];
      return { ...lot, units: totalChildUnits * lot.units / total, usd, aud, allottedOn: action.effective_on };
    });
    child.lots = child.lots.slice(child.next).concat(allotted).sort(compareLots);
    child.next = 0;
    const usd = sumAmounts(allotted, "usd");
    const aud = sumAmounts(allotted, "aud");
    const missingBasis = (usdPercent && (usd.gross === undefined || usd.fee === undefined)) ||
      (audPercent && (aud.gross === undefined || aud.fee === undefined));
    rows.push({ kind: "Stock spin-off", spinOff: action, purchases: lots.map((lot) => lot.purchase), usd, aud,
      note: missingBasis ? "Shares were allotted. Some original acquisition amounts are missing. Review the basis before using later matches."
        : "Original costs and fees were apportioned without a sale. Check the allocation method and dates against your source." });
  }

  const actionDates = [...actionDays.keys()].sort();
  let nextActionDay = 0;
  let pendingTransfers: DayActions | undefined;
  function finishTransfers() {
    if (!pendingTransfers) return;
    for (const transfer of pendingTransfers.arrivals.sort((a, b) => a.id.localeCompare(b.id))) receive(transfer);
    for (const transfer of pendingTransfers.departures.sort((a, b) =>
      a.same_day_order - b.same_day_order || a.id.localeCompare(b.id))) dispatch(transfer);
    pendingTransfers = undefined;
  }

  function applyActions(through: string) {
    while (nextActionDay < actionDates.length && actionDates[nextActionDay] <= through) {
      const day = actionDates[nextActionDay++];
      finishTransfers();
      applySplits(day);
      const events = actionDays.get(day)!;
      const counts = new Map<string, number>();
      for (const action of events.spinOffs) {
        for (const id of [action.parent_holding_id, action.child_holding_id]) counts.set(id, (counts.get(id) ?? 0) + 1);
      }
      for (const action of events.spinOffs) {
        applySpinOff(action, counts.get(action.parent_holding_id)! > 1 || counts.get(action.child_holding_id)! > 1);
      }
      pendingTransfers = events;
      if (day < through) finishTransfers();
    }
    applySplits(through);
  }

  let processingDay: string | null = null;
  for (const { transaction, date } of sorted) {
    if (date && end && date > end) continue;
    if (date && date !== processingDay) {
      finishTransfers();
      applyActions(date);
      processingDay = date;
    }
    const holding = holdingFor(transaction.holding_id);
    const visible = date && (!start || date >= start);
    const tradeUnits = scaled(transaction.shares);
    const price = scaled(transaction.price_per_share);
    const fee = ledgerFeeCents(transaction.fees);
    if (!date || !tradeUnits || price === undefined || fee === undefined || !["Buy", "Sell"].includes(transaction.type)) {
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
          units: displayed, transfers: lot.transfers, spinOffs: lot.spinOffs, allottedOn: lot.allottedOn,
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

  finishTransfers();
  applyActions(end ?? "9998-12-31");
  finishTransfers();
  for (const [holdingId, { lots, next, invalid }] of holdings) {
    if (invalid) continue;
    for (const lot of lots.slice(next)) {
      const holding = stockHoldings.get(holdingId) ?? lot.purchase.portfolio_holdings;
      const archived = holding?.deleted_at;
      const transaction = lot.transfers || lot.allottedOn ? { ...lot.purchase, holding_id: holdingId, portfolio_holdings: holding } : lot.purchase;
      const archiveDate = archived && sydneyDate(archived);
      const needsReview = archiveDate && (!end || archiveDate <= end);
      rows.push({
        kind: lot.usd.gross === undefined && !lot.purchase.reinvestment ? "Position record" : needsReview ? "Archived holding lot" : "Open lot",
        transaction, purchase: lot.purchase, transfers: lot.transfers, spinOffs: lot.spinOffs, allottedOn: lot.allottedOn,
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
