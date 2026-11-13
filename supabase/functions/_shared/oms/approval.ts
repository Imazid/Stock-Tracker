// Approval rules for an order intent.
//
// An approval is bound to: the intent id, the exact intent hash the person saw, the person
// (only the owner may approve — never an agent, never another user), the authentication level
// at the moment of approval, and a short expiry. It can be consumed once. All of this is
// checked again at submission, after the intent is re-read from the database.

import type { TradingEnvironment } from "../brokers/types.ts";
import { compare } from "../decimal.ts";
import { sameHash } from "./intent.ts";

export interface ApprovalPolicy {
  /** How long an approval stays valid (ms). Short on purpose: prices move. */
  approvalTtlMs: number;
  /** How long an unapproved intent lives (ms). */
  intentTtlMs: number;
  /** Live orders always need a verified second factor (aal2). */
  stepUpForLive: true;
  /** Paper orders at or above this notional also need aal2 (decimal string, account currency). */
  stepUpPaperNotional: string;
}

export const DEFAULT_APPROVAL_POLICY: ApprovalPolicy = {
  approvalTtlMs: 2 * 60_000,
  intentTtlMs: 15 * 60_000,
  stepUpForLive: true,
  stepUpPaperNotional: "25000",
};

export interface ApprovalRecord {
  intentID: string;
  approverID: string;
  approvedIntentHash: string;
  aal: "aal1" | "aal2";
  approvedAt: number;
  expiresAt: number;
  consumedAt?: number;
}

export type ApprovalProblem =
  | { code: "approval_invalid"; message: string }
  | { code: "approval_expired"; message: string }
  | { code: "approval_used"; message: string }
  | { code: "intent_changed"; message: string }
  | { code: "step_up_required"; message: string }
  | { code: "forbidden"; message: string };

/** Does this caller need a second factor to approve this order? */
export function needsStepUp(environment: TradingEnvironment, estimatedNotional: string | undefined, policy: ApprovalPolicy): boolean {
  if (environment === "live") return true;
  if (estimatedNotional === undefined) return false;
  return compare(estimatedNotional, policy.stepUpPaperNotional) >= 0;
}

/** Checks done when the person presses Approve. */
export function checkApprove(args: {
  callerID: string;
  callerAAL: "aal1" | "aal2";
  ownerID: string;
  storedHash: string;
  presentedHash: string;
  environment: TradingEnvironment;
  estimatedNotional?: string;
  intentExpiresAt: number;
  now: number;
  policy?: ApprovalPolicy;
}): ApprovalProblem | undefined {
  const policy = args.policy ?? DEFAULT_APPROVAL_POLICY;
  if (args.callerID !== args.ownerID) return { code: "forbidden", message: "Only the account owner can approve this order." };
  if (args.now >= args.intentExpiresAt) return { code: "approval_expired", message: "This order expired before it was approved. Prepare it again." };
  if (!sameHash(args.storedHash, args.presentedHash)) {
    return { code: "intent_changed", message: "The order changed after you opened it. Review it again before approving." };
  }
  if (needsStepUp(args.environment, args.estimatedNotional, policy) && args.callerAAL !== "aal2") {
    return { code: "step_up_required", message: "Confirm with your second factor to approve this order." };
  }
  return undefined;
}

/** Checks done at submission, against the stored approval and a freshly recomputed hash. */
export function checkSubmit(args: {
  callerID: string;
  callerAAL: "aal1" | "aal2";
  ownerID: string;
  approval: ApprovalRecord | undefined;
  currentHash: string;
  environment: TradingEnvironment;
  estimatedNotional?: string;
  now: number;
  policy?: ApprovalPolicy;
}): ApprovalProblem | undefined {
  const policy = args.policy ?? DEFAULT_APPROVAL_POLICY;
  const a = args.approval;
  if (args.callerID !== args.ownerID) return { code: "forbidden", message: "Only the account owner can submit this order." };
  if (!a) return { code: "approval_invalid", message: "This order hasn't been approved." };
  if (a.approverID !== args.ownerID) return { code: "approval_invalid", message: "This approval wasn't given by the account owner." };
  if (a.consumedAt !== undefined) return { code: "approval_used", message: "This approval has already been used." };
  if (args.now >= a.expiresAt) return { code: "approval_expired", message: "The approval expired. Approve the order again." };
  if (!sameHash(a.approvedIntentHash, args.currentHash)) {
    return { code: "intent_changed", message: "The order is not the one that was approved. Approve it again." };
  }
  if (needsStepUp(args.environment, args.estimatedNotional, policy)) {
    if (a.aal !== "aal2") return { code: "step_up_required", message: "This order needs an approval confirmed with your second factor." };
    if (args.callerAAL !== "aal2") return { code: "step_up_required", message: "Confirm with your second factor to send this order." };
  }
  return undefined;
}
