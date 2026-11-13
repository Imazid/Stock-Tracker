// The seam where a real-money broker would plug in. THERE IS NO IMPLEMENTATION, ON PURPOSE.
//
// Only paper (simulated) execution exists in this build. This file describes what a live
// adapter would have to provide, so that adding one later is a deliberate, reviewable
// change — and it guards the seam so that nothing can reach a live venue by accident:
// every entry point throws "live trading is not enabled".
//
// To add a venue later, all of this has to change together, in review:
//   1. an adapter class implementing `LiveBrokerAdapter`, with its own trading credentials
//      held as function secrets (never the market-data keys, never in a table);
//   2. the capability in ../trading/broker.ts (`LiveVenues`) switched to executable;
//   3. the database constraint `live_trading_not_available_in_this_build` (risk_policies)
//      dropped by a migration, and a person's live flag set by a server-side process;
//   4. the Swift core changed the same way, with new shared vectors.
// Until then no file in this repository calls a broker's order endpoint.

import type { Order } from "../trading/orders.ts";

export interface LiveSubmitResult {
  brokerOrderID: string;
  acceptedAt: number;
}

export interface LiveOrderState {
  brokerOrderID: string;
  status: "pendingSubmit" | "accepted" | "partiallyFilled" | "filled" | "canceled" | "rejected" | "expired";
  filledQuantity: number;
  averageFillPrice: number;
  updatedAt: number;
}

/** What a live venue adapter would implement. Nothing implements it. */
export interface LiveBrokerAdapter {
  readonly adapterID: string;
  /** Sends an order the risk engine has approved. Must be idempotent on `order.clientOrderID`. */
  submit(order: Order): Promise<LiveSubmitResult>;
  cancel(brokerOrderID: string): Promise<void>;
  fetchOrder(brokerOrderID: string): Promise<LiveOrderState>;
  /** Brings our record of open orders back in line with the venue's. */
  reconcile(orders: Order[]): Promise<LiveOrderState[]>;
}

export class LiveTradingDisabledError extends Error {
  constructor(what = "live trading is not enabled") {
    super(what);
    this.name = "LiveTradingDisabledError";
  }
}

/** The registry of live adapters. It is empty and frozen. */
export const liveAdapters: Readonly<Record<string, LiveBrokerAdapter>> = Object.freeze({});

/** Always throws: there is no live adapter to return. */
export function liveAdapter(_adapterID: string): never {
  throw new LiveTradingDisabledError();
}

/**
 * Reconciliation for the scheduler. Paper orders live entirely in our own database, so
 * there is nothing outside to reconcile with: a no-op. A live order must not exist; if one
 * is ever seen, this refuses loudly rather than touching a venue.
 */
export function reconcile(orders: Order[]): { reconciled: number } {
  const live = orders.filter((order) => order.mode === "live");
  if (live.length > 0) throw new LiveTradingDisabledError(`live trading is not enabled: ${live.length} live order(s) can't be reconciled`);
  return { reconciled: 0 };
}
