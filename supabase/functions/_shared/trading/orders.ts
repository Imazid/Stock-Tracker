// Orders and fills. A port of TradingCore/Sources/TradingCore/Orders.swift.

import type { Instrument } from "./market.ts";
import { money } from "./rounding.ts";

export type OrderSide = "buy" | "sell";
export const ORDER_SIDES: OrderSide[] = ["buy", "sell"];

export type OrderType = "market" | "limit" | "stop" | "stopLimit";
export const ORDER_TYPES: OrderType[] = ["market", "limit", "stop", "stopLimit"];

export function orderTypeDisplayName(type: OrderType): string {
  switch (type) {
    case "market": return "Market";
    case "limit": return "Limit";
    case "stop": return "Stop";
    case "stopLimit": return "Stop limit";
  }
}

export const needsLimitPrice = (type: OrderType): boolean => type === "limit" || type === "stopLimit";
export const needsStopPrice = (type: OrderType): boolean => type === "stop" || type === "stopLimit";

export type TimeInForce = "day" | "gtc" | "ioc" | "fok";
export const TIMES_IN_FORCE: TimeInForce[] = ["day", "gtc", "ioc", "fok"];

export function timeInForceDisplayName(tif: TimeInForce): string {
  switch (tif) {
    case "day": return "Day";
    case "gtc": return "Good till cancelled";
    case "ioc": return "Immediate or cancel";
    case "fok": return "Fill or kill";
  }
}

/**
 * Paper money or real money. Carried on every order, fill, proposal and ledger so the two
 * can never be mixed up.
 */
export type ExecutionMode = "paper" | "live";

export type OrderStatus = "pendingSubmit" | "accepted" | "partiallyFilled" | "filled" | "canceled" | "rejected" | "expired";
export const ORDER_STATUSES: OrderStatus[] = ["pendingSubmit", "accepted", "partiallyFilled", "filled", "canceled", "rejected", "expired"];

export function isOpenStatus(status: OrderStatus): boolean {
  return status === "pendingSubmit" || status === "accepted" || status === "partiallyFilled";
}

export const isTerminalStatus = (status: OrderStatus): boolean => !isOpenStatus(status);

/**
 * The only moves an order may make. Anything else is a bug or a bad broker message, and
 * the engine refuses it rather than guessing. (The database enforces the same table.)
 */
export function canTransition(from: OrderStatus, to: OrderStatus): boolean {
  switch (from) {
    case "pendingSubmit": return ["accepted", "partiallyFilled", "filled", "canceled", "rejected", "expired"].includes(to);
    case "accepted": return ["partiallyFilled", "filled", "canceled", "rejected", "expired"].includes(to);
    case "partiallyFilled": return ["partiallyFilled", "filled", "canceled", "expired"].includes(to);
    default: return false;
  }
}

export function orderStatusDisplayName(status: OrderStatus): string {
  switch (status) {
    case "pendingSubmit": return "Sending";
    case "accepted": return "Working";
    case "partiallyFilled": return "Partly filled";
    case "filled": return "Filled";
    case "canceled": return "Cancelled";
    case "rejected": return "Rejected";
    case "expired": return "Expired";
  }
}

/** Who asked for an order. */
export interface OrderSource {
  kind: "manual" | "agent";
  agentID?: string;
  proposalID?: string;
}

export const manualSource: OrderSource = { kind: "manual" };

export function agentSource(agentID: string, proposalID?: string): OrderSource {
  const source: OrderSource = { kind: "agent", agentID };
  if (proposalID !== undefined) source.proposalID = proposalID;
  return source;
}

/** What someone wants to trade, before any check has run. */
export interface OrderRequest {
  /** Idempotency key: the same key is never accepted twice. */
  clientOrderID: string;
  ledgerID: string;
  instrument: Instrument;
  side: OrderSide;
  type: OrderType;
  /** Units to trade. Give this or `notional`. */
  quantity?: number;
  /** Cash amount to trade (market orders only). */
  notional?: number;
  limitPrice?: number;
  stopPrice?: number;
  timeInForce: TimeInForce;
  source: OrderSource;
  mode: ExecutionMode;
  /** The completed bar an agent's signal came from. */
  signalBarTime?: number;
}

export function makeRequest(fields: Partial<OrderRequest> & Pick<OrderRequest, "clientOrderID" | "ledgerID" | "instrument" | "side">): OrderRequest {
  return { type: "market", timeInForce: "day", source: { kind: "manual" }, mode: "paper", ...fields };
}

export interface Order {
  id: string;
  clientOrderID: string;
  ledgerID: string;
  instrument: Instrument;
  side: OrderSide;
  type: OrderType;
  quantity: number;
  limitPrice?: number;
  stopPrice?: number;
  timeInForce: TimeInForce;
  source: OrderSource;
  mode: ExecutionMode;
  status: OrderStatus;
  filledQuantity: number;
  averageFillPrice: number;
  fees: number;
  /** The price the order was sized and checked against. A fill far from it is refused. */
  referencePrice: number;
  createdAt: number;
  updatedAt: number;
  expiresAt?: number;
  stopTriggeredAt?: number;
  /** Why the order was rejected, cancelled or is waiting. */
  statusNote?: string;
  signalBarTime?: number;
  /** The venue's own id for the order (live only). */
  brokerOrderID?: string;
}

export function remainingQuantity(order: Order): number {
  return Math.max(order.quantity - order.filledQuantity, 0);
}

/** Moves the order to `next`, or returns false and changes nothing if that move isn't allowed. */
export function transition(order: Order, next: OrderStatus, time: number, note?: string): boolean {
  if (!canTransition(order.status, next)) return false;
  order.status = next;
  order.updatedAt = time;
  if (note !== undefined) order.statusNote = note;
  return true;
}

export interface Fill {
  id: string;
  orderID: string;
  ledgerID: string;
  instrument: Instrument;
  side: OrderSide;
  quantity: number;
  price: number;
  fee: number;
  time: number;
  source: OrderSource;
  mode: ExecutionMode;
  /** Profit banked by this fill (sells only), after fees. Set when the ledger applies it. */
  realizedPnL?: number;
  signalBarTime?: number;
}

/** Quantity × price, to the cent, before fees. */
export function fillGross(fill: Fill): number {
  return money(fill.quantity * fill.price);
}
