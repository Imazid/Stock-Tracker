// The order-intent state machine. The database enforces the same table by trigger
// (oms_intent_can_transition in the migration), so a bug here can't skip a state.
//
//   draft → risk_checked → awaiting_approval → approved → submitting → submitted
//         → partially_filled → filled
//   exits: rejected · expired · cancelled · failed · reconciliation_required
//
// `reconciliation_required` is entered whenever we don't know what the provider did (timeout
// on submit, stream gap, provider status we can't map). Nothing may be submitted for that
// intent again until a provider lookup settles it.

import type { BrokerOrderStatus } from "../brokers/types.ts";
import type { IntentStatus } from "./api.ts";

const NEXT: Record<IntentStatus, readonly IntentStatus[]> = {
  draft: ["risk_checked", "rejected", "expired", "cancelled"],
  risk_checked: ["awaiting_approval", "risk_checked", "rejected", "expired", "cancelled"],
  awaiting_approval: ["approved", "risk_checked", "rejected", "expired", "cancelled"],
  approved: ["submitting", "rejected", "expired", "cancelled"],
  submitting: ["submitted", "partially_filled", "filled", "rejected", "failed", "reconciliation_required", "cancelled", "expired"],
  submitted: ["partially_filled", "filled", "cancelled", "expired", "rejected", "reconciliation_required"],
  partially_filled: ["partially_filled", "filled", "cancelled", "expired", "reconciliation_required"],
  reconciliation_required: ["submitted", "partially_filled", "filled", "cancelled", "expired", "rejected", "failed", "reconciliation_required"],
  filled: [],
  rejected: [],
  expired: [],
  cancelled: [],
  failed: [],
};

export const TERMINAL: readonly IntentStatus[] = ["filled", "rejected", "expired", "cancelled", "failed"];
/** States in which an order may be live at the provider (counts against limits, can be cancelled there). */
export const AT_PROVIDER: readonly IntentStatus[] = ["submitting", "submitted", "partially_filled", "reconciliation_required"];
/** States that reserve exposure before submission (so concurrent intents can't jointly exceed limits). */
export const RESERVING: readonly IntentStatus[] = ["risk_checked", "awaiting_approval", "approved", ...AT_PROVIDER];

export function canTransition(from: IntentStatus, to: IntentStatus): boolean {
  return NEXT[from].includes(to);
}

export class TransitionError extends Error {
  constructor(readonly from: IntentStatus, readonly to: IntentStatus) {
    super(`An order can't go from ${from} to ${to}.`);
    this.name = "TransitionError";
  }
}

export function assertTransition(from: IntentStatus, to: IntentStatus): void {
  if (!canTransition(from, to)) throw new TransitionError(from, to);
}

export const isTerminal = (status: IntentStatus): boolean => TERMINAL.includes(status);

/** Where a provider's order status puts our intent. `unknown` (unmapped) means reconcile. */
export function statusFromBroker(status: BrokerOrderStatus): IntentStatus {
  switch (status) {
    case "pending_new":
    case "accepted":
    case "pending_cancel":
    case "pending_replace":
      return "submitted";
    case "partially_filled":
      return "partially_filled";
    case "filled":
      return "filled";
    case "canceled":
      return "cancelled";
    case "expired":
      return "expired";
    case "rejected":
      return "rejected";
    case "replaced":
      // The original was replaced by a new provider order; the intent follows the new order.
      // Until we've fetched it, we don't know its state.
      return "reconciliation_required";
    case "unknown":
      return "reconciliation_required";
  }
}

/** The step from `from` towards the provider's state, or undefined if it's not a legal move (or no change). */
export function nextFromBroker(from: IntentStatus, status: BrokerOrderStatus): IntentStatus | undefined {
  const to = statusFromBroker(status);
  if (to === from && to !== "partially_filled") return undefined;
  return canTransition(from, to) ? to : undefined;
}
