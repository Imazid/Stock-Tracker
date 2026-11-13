// Cash and positions for one book — a paper portfolio or one agent's budget. A port of
// TradingCore/Sources/TradingCore/Ledger.swift. Every change goes through `applyFill`, so
// cash, cost and realised profit can't drift apart.
//
// Swift's Ledger is a value type; here it is a plain object that these functions change
// in place. Callers that need a copy (the risk engine's view of "today") take one first.

import { dayKeyInZone } from "./calendar.ts";
import { currencyTimeZone } from "./currencies.ts";
import { type Instrument, instrumentID, isRealMarketData, type Quote } from "./market.ts";
import { type ExecutionMode, type Fill, fillGross } from "./orders.ts";
import * as Rounding from "./rounding.ts";

export interface Position {
  instrument: Instrument;
  quantity: number;
  /** What the held quantity cost, buy fees included. */
  costBasis: number;
  openedAt: number;
  lastPrice: number;
  lastPriceTime?: number;
}

export const positionID = (position: Position): string => instrumentID(position.instrument);
export const averageCost = (position: Position): number => position.quantity > 0 ? position.costBasis / position.quantity : 0;
export const marketValue = (position: Position): number => position.quantity * position.lastPrice;
export const positionUnrealizedPnL = (position: Position): number => marketValue(position) - position.costBasis;
export const positionUnrealizedPct = (position: Position): number =>
  position.costBasis > 0 ? positionUnrealizedPnL(position) / position.costBasis * 100 : 0;

export interface EquityPoint {
  time: number;
  equity: number;
  cash: number;
}

/** `manualPaper`: a simulated portfolio the person trades by hand. `agentPaper`: one owned by an agent. */
export type LedgerKind = "manualPaper" | "agentPaper";

export interface Ledger {
  id: string;
  name: string;
  kind: LedgerKind;
  mode: ExecutionMode;
  currency: string;
  agentID?: string;
  startingCash: number;
  cash: number;
  positions: Position[];
  realizedPnL: number;
  feesPaid: number;
  createdAt: number;
  equityHistory: EquityPoint[];
  peakEquity: number;

  // Daily counters, reset when the ledger's trading day changes.
  dayKey: string;
  dayStartEquity: number;
  realizedToday: number;
  notionalToday: number;

  lastFillAt: Record<string, number>;
  lastBuyAt: Record<string, number>;
  lastExitAt: Record<string, number>;
}

/**
 * The ledger's trading day, counted in its currency's home market (Sydney for AUD, London
 * for GBP, Tokyo for JPY…; New York for USD).
 */
export function ledgerDayKey(time: number, currency: string): string {
  return dayKeyInZone(currencyTimeZone(currency), time);
}

export function makeLedger(fields: { id: string; name: string; kind: LedgerKind; currency?: string; agentID?: string; startingCash: number; createdAt: number }): Ledger {
  const currency = fields.currency ?? "USD";
  const cash = Rounding.money(fields.startingCash);
  const ledger: Ledger = {
    id: fields.id, name: fields.name, kind: fields.kind, mode: "paper", currency,
    startingCash: cash, cash, positions: [], realizedPnL: 0, feesPaid: 0, createdAt: fields.createdAt,
    equityHistory: [{ time: fields.createdAt, equity: cash, cash }], peakEquity: cash,
    dayKey: ledgerDayKey(fields.createdAt, currency), dayStartEquity: cash, realizedToday: 0, notionalToday: 0,
    lastFillAt: {}, lastBuyAt: {}, lastExitAt: {},
  };
  if (fields.agentID !== undefined) ledger.agentID = fields.agentID;
  return ledger;
}

export function positionsValue(ledger: Ledger): number {
  let total = 0;
  for (const position of ledger.positions) total += marketValue(position);
  return total;
}

export const equity = (ledger: Ledger): number => ledger.cash + positionsValue(ledger);

export function unrealizedPnL(ledger: Ledger): number {
  let total = 0;
  for (const position of ledger.positions) total += positionUnrealizedPnL(position);
  return total;
}

export const totalReturn = (ledger: Ledger): number => equity(ledger) - ledger.startingCash;
export const totalReturnPct = (ledger: Ledger): number => ledger.startingCash > 0 ? totalReturn(ledger) / ledger.startingCash * 100 : 0;

/** How far equity sits below its highest point, in percent. */
export const drawdownPct = (ledger: Ledger): number =>
  ledger.peakEquity > 0 ? Rounding.swiftMax(0, (ledger.peakEquity - equity(ledger)) / ledger.peakEquity * 100) : 0;

/** Today's change in equity as a percent of where the day started. */
export const dayChangePct = (ledger: Ledger): number =>
  ledger.dayStartEquity > 0 ? (equity(ledger) - ledger.dayStartEquity) / ledger.dayStartEquity * 100 : 0;

export function position(ledger: Ledger, id: string): Position | undefined {
  return ledger.positions.find((p) => positionID(p) === id);
}

/** Starts a new trading day if the date has moved on. */
export function rollDayIfNeeded(ledger: Ledger, now: number): void {
  const key = ledgerDayKey(now, ledger.currency);
  if (key === ledger.dayKey) return;
  ledger.dayKey = key;
  ledger.dayStartEquity = equity(ledger);
  ledger.realizedToday = 0;
  ledger.notionalToday = 0;
}

/** The ledger as it stands "today" at `now`, without touching the original. */
export function rolledCopy(ledger: Ledger, now: number): Ledger {
  const copy: Ledger = { ...ledger };
  rollDayIfNeeded(copy, now);
  return copy;
}

/**
 * Books a fill and returns it with the realised profit filled in.
 * Buys add their fee to the cost; sells take theirs off the proceeds.
 */
export function applyFill(ledger: Ledger, incoming: Fill): Fill {
  const fill: Fill = { ...incoming };
  rollDayIfNeeded(ledger, fill.time);
  const id = instrumentID(fill.instrument);
  const gross = fillGross(fill);
  const index = ledger.positions.findIndex((p) => positionID(p) === id);
  if (fill.side === "buy") {
    ledger.cash = Rounding.money(ledger.cash - gross - fill.fee);
    if (index >= 0) {
      const held = ledger.positions[index];
      held.quantity = Rounding.round(held.quantity + fill.quantity, 9);
      held.costBasis = Rounding.money(held.costBasis + gross + fill.fee);
      held.lastPrice = fill.price;
      held.lastPriceTime = fill.time;
    } else {
      ledger.positions.push({
        instrument: fill.instrument, quantity: fill.quantity, costBasis: Rounding.money(gross + fill.fee),
        openedAt: fill.time, lastPrice: fill.price, lastPriceTime: fill.time,
      });
    }
    ledger.lastBuyAt[id] = fill.time;
  } else {
    if (index < 0) return fill;
    const current = ledger.positions[index];
    const held = current.quantity;
    const sold = Math.min(fill.quantity, held);
    const closing = held - sold <= 1e-9;
    const costRemoved = closing ? current.costBasis : Rounding.money(current.costBasis / held * sold);
    const realized = Rounding.money(gross - fill.fee - costRemoved);
    ledger.cash = Rounding.money(ledger.cash + gross - fill.fee);
    ledger.realizedPnL = Rounding.money(ledger.realizedPnL + realized);
    ledger.realizedToday = Rounding.money(ledger.realizedToday + realized);
    fill.realizedPnL = realized;
    if (closing) {
      ledger.positions.splice(index, 1);
      ledger.lastExitAt[id] = fill.time;
    } else {
      current.quantity = Rounding.round(held - sold, 9);
      current.costBasis = Rounding.money(current.costBasis - costRemoved);
      current.lastPrice = fill.price;
      current.lastPriceTime = fill.time;
    }
  }
  ledger.feesPaid = Rounding.money(ledger.feesPaid + fill.fee);
  ledger.notionalToday = Rounding.money(ledger.notionalToday + gross);
  ledger.lastFillAt[id] = fill.time;
  return fill;
}

/** Reprices positions from real quotes and records the equity point. */
export function mark(ledger: Ledger, quotes: Record<string, Quote>, now: number): void {
  rollDayIfNeeded(ledger, now);
  for (const held of ledger.positions) {
    const quote = quotes[positionID(held)];
    if (!quote || !(isRealMarketData(quote.provenance) || quote.provenance.kind === "fixture") || !(quote.last > 0)) continue;
    held.lastPrice = quote.last;
    held.lastPriceTime = quote.time;
  }
  recordEquity(ledger, now);
}

/** Adds an equity point, keeping at most one per hour for older history. */
export function recordEquity(ledger: Ledger, now: number): void {
  const point: EquityPoint = { time: now, equity: Rounding.money(equity(ledger)), cash: ledger.cash };
  const history = ledger.equityHistory;
  const last = history[history.length - 1];
  if (last !== undefined && (now - last.time) / 1_000 < 3_600 && history.length > 1) {
    history[history.length - 1] = point;
  } else {
    history.push(point);
  }
  if (history.length > 3_000) history.splice(0, history.length - 3_000);
  ledger.peakEquity = Math.max(ledger.peakEquity, point.equity);
}

export const Ledgers = {
  make: makeLedger, dayKey: ledgerDayKey, positionsValue, equity, unrealizedPnL, totalReturn, totalReturnPct, drawdownPct,
  dayChangePct, position, rollDayIfNeeded, rolledCopy, applyFill, mark, recordEquity,
};
