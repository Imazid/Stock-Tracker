// Submission, reconciliation and cancellation of an approved order intent.
//
// This is the only code that calls a provider's order endpoint, and it does so only after
// every layer has said yes, in this order (the brief's ten steps):
//
//   1. the caller is authenticated (done by the function) and owns the intent
//   2. platform gate for the environment is open; the person's kill switch is off
//   3. the connection is active, granted `trade`, and in the intent's environment
//   4. the stored approval covers the exact intent hash (recomputed now), is unexpired and
//      unused, and carries a second factor where one is required
//   5. the provider says the account can trade right now
//   6. the risk engine passes again, on a quote fresh enough for the policy
//   7. the approval is consumed atomically (single use, even under concurrent requests)
//   8. the intent moves approved → submitting atomically (only one submitter can win)
//   9. the adapter submits with our clientOrderID as the provider idempotency key
//  10. the outcome is recorded; an unknown outcome becomes `reconciliation_required` and is
//      looked up by clientOrderID — never resubmitted.
//
// Dependencies are injected so the whole pipeline is tested without a database or network.

import type { AdapterContext, BrokerAdapter, BrokerOrder } from "../brokers/types.ts";
import { BrokerError } from "../brokers/types.ts";
import type { ApiErrorCode, GateID, IntentStatus, OrderIntentInput, RiskEvaluationView } from "./api.ts";
import type { ApprovalPolicy, ApprovalRecord } from "./approval.ts";
import { checkSubmit } from "./approval.ts";
import type { GateRow } from "./gates.ts";
import { GateClosedError, gateForEnvironment, requireGates } from "./gates.ts";
import { canonicalIntent, intentHash } from "./intent.ts";
import { AT_PROVIDER, canTransition } from "./lifecycle.ts";
import type { ProviderID, TradingEnvironment } from "../brokers/types.ts";

export interface IntentRecord {
  id: string;
  userID: string;
  provider: ProviderID;
  environment: TradingEnvironment;
  input: OrderIntentInput;
  clientOrderID: string;
  intentHash: string;
  status: IntentStatus;
  createdAt: number;
  /** When the order entered submitting, independent of polling or audit writes. */
  submittingAt?: number;
  expiresAt: number;
  estimatedNotional?: string;
  providerOrderID?: string;
  /** When the intent entered reconciliation_required (ms), for the give-up grace period. */
  reconcilingSince?: number;
}

export interface ConnectionState {
  id: string;
  userID: string;
  provider: ProviderID;
  environment: TradingEnvironment;
  status: "active" | "needs_attention" | "revoked";
  permissions: ("read" | "trade")[];
  providerAccountID?: string;
}

export interface OmsStore {
  /** Compare-and-set: moves the intent only if it is still in `from`. Records the transition row. */
  transition(intentID: string, from: IntentStatus, to: IntentStatus, note?: string): Promise<boolean>;
  loadApproval(intentID: string): Promise<ApprovalRecord | undefined>;
  /** Marks the approval used iff it is unused and unexpired at `now`. Returns false otherwise. */
  consumeApproval(intentID: string, now: number): Promise<boolean>;
  /** Record a provider observation and the matching legal intent transition atomically. */
  recordBrokerOrder(intentID: string, from: IntentStatus, order: BrokerOrder): Promise<IntentStatus>;
  recordRisk(intentID: string, risk: RiskEvaluationView): Promise<void>;
  audit(event: { userID: string; intentID: string; kind: string; detail: Record<string, unknown> }): Promise<void>;
}

export interface ReconciliationDeps {
  store: OmsStore;
  adapter: BrokerAdapter;
  /** Credentials already decrypted for this call. `allowLive` is set here, from the gate, nowhere else. */
  adapterContext: Omit<AdapterContext, "allowLive">;
  now(): number;
}

export interface ExecutionDeps extends ReconciliationDeps {
  gates: Record<GateID, GateRow>;
  killSwitchEngaged: boolean;
  connection: ConnectionState;
  /** Re-runs the deterministic risk engine with a freshly fetched quote. */
  evaluateRisk(intent: IntentRecord): Promise<RiskEvaluationView>;
  /** Oldest acceptable quote for submission (ms). */
  maxQuoteAgeMs: number;
  approvalPolicy?: ApprovalPolicy;
  /** Runs `fn` holding the person's trading lock (a Postgres advisory lock in production). */
  serialize?<T>(fn: () => Promise<T>): Promise<T>;
}

export interface Caller {
  userID: string;
  aal: "aal1" | "aal2";
}

export type ExecutionOutcome =
  | { ok: true; status: IntentStatus; brokerOrder?: BrokerOrder; risk?: RiskEvaluationView }
  | { ok: false; code: ApiErrorCode; message: string; status: IntentStatus; details?: Record<string, unknown> };

const refuse = (code: ApiErrorCode, message: string, status: IntentStatus, details?: Record<string, unknown>): ExecutionOutcome => ({ ok: false, code, message, status, details });

/** Recomputes the intent hash from the stored fields — the approval must match this, not the stored hash. */
export function recomputeHash(intent: IntentRecord): Promise<string> {
  return intentHash(canonicalIntent({ userID: intent.userID, provider: intent.provider, environment: intent.environment, clientOrderID: intent.clientOrderID, input: intent.input }));
}

function brokerRequest(intent: IntentRecord) {
  const i = intent.input;
  return {
    clientOrderID: intent.clientOrderID,
    symbol: i.symbol,
    assetClass: i.assetClass,
    side: i.side,
    type: i.type,
    timeInForce: i.timeInForce,
    quantity: i.quantity,
    notional: i.notional,
    limitPrice: i.limitPrice,
    stopPrice: i.stopPrice,
  };
}

export async function submitIntent(deps: ExecutionDeps, intent: IntentRecord, caller: Caller): Promise<ExecutionOutcome> {
  const now = deps.now();
  const s = intent.status;

  // 1. Ownership and state.
  if (caller.userID !== intent.userID) return refuse("forbidden", "Only the account owner can submit this order.", s);
  if (AT_PROVIDER.includes(s)) {
    return refuse(s === "reconciliation_required" ? "reconciliation_required" : "conflict", s === "reconciliation_required"
      ? "We're confirming this order with the provider. It won't be sent again."
      : "This order has already been sent.", s);
  }
  if (s !== "approved") return refuse("conflict", "Only an approved order can be sent.", s);

  // 2. Platform gate and kill switch. Approvals are per order, so this is never "automated".
  const gateIDs = gateForEnvironment(intent.environment, false);
  try {
    requireGates(deps.gates, gateIDs);
  } catch (error) {
    if (error instanceof GateClosedError) return refuse("feature_disabled", error.reason, s, { gate: error.gate });
    throw error;
  }
  if (deps.killSwitchEngaged) return refuse("kill_switch_engaged", "Trading is halted by your kill switch. Nothing will be sent until you turn it off.", s);

  // 3. Connection.
  const c = deps.connection;
  if (c.userID !== intent.userID || c.id !== intent.input.connectionID) return refuse("forbidden", "That account isn't yours.", s);
  if (c.status !== "active") return refuse("provider_error", "This connection needs attention before it can trade. Reconnect it in Connections.", s);
  if (!c.permissions.includes("trade")) return refuse("forbidden", "This connection is read-only. It was never given permission to trade.", s);
  if (c.environment !== intent.environment || c.provider !== intent.provider) return refuse("intent_changed", "The order no longer matches its account.", s);

  // 4. Approval against the hash recomputed from what we'd actually send.
  const currentHash = await recomputeHash(intent);
  const approval = await deps.store.loadApproval(intent.id);
  const problem = checkSubmit({
    callerID: caller.userID,
    callerAAL: caller.aal,
    ownerID: intent.userID,
    approval,
    currentHash,
    environment: intent.environment,
    estimatedNotional: intent.estimatedNotional,
    now,
    policy: deps.approvalPolicy,
  });
  if (problem) {
    if (problem.code === "approval_expired" && canTransition(s, "expired")) await deps.store.transition(intent.id, s, "expired", "approval expired");
    return refuse(problem.code, problem.message, problem.code === "approval_expired" ? "expired" : s);
  }

  const ctx: AdapterContext = { ...deps.adapterContext, allowLive: intent.environment === "live" && deps.gates.live_execution.enabled };

  // 5. The provider must say the account can trade now.
  let accounts;
  try {
    accounts = await deps.adapter.accounts(ctx);
  } catch (error) {
    return refuse("provider_error", "The provider couldn't be reached to confirm the account. Nothing was sent.", s, brokerDetails(error));
  }
  const account = c.providerAccountID ? accounts.find((a) => a.providerAccountID === c.providerAccountID) : accounts[0];
  if (!account) return refuse("provider_error", "The provider no longer lists this account. Nothing was sent.", s);
  if (!account.tradingEnabled) {
    return refuse("provider_error", `The provider isn't accepting orders on this account: ${account.tradingBlockers.join("; ") || "no reason given"}. Nothing was sent.`, s);
  }

  // 6–8 run under the person's lock: the risk verdict sees every other order already
  // reserving exposure (risk_checked … submitting), and this order starts reserving before
  // the lock is released. So two orders that each pass alone can't both go through when
  // together they'd break a limit.
  const serialize = deps.serialize ?? (<T>(fn: () => Promise<T>) => fn());
  const gate = await serialize(async (): Promise<ExecutionOutcome | { risk: RiskEvaluationView }> => {
    // 6. Risk again, now, on a fresh quote.
    const risk = await deps.evaluateRisk(intent);
    await deps.store.recordRisk(intent.id, risk);
    const quoteAge = now - Date.parse(risk.price.observedAt);
    if (!Number.isFinite(quoteAge) || quoteAge > deps.maxQuoteAgeMs) {
      return refuse("stale_price", "The latest price is too old to send this order safely. Try again in a moment.", s, { observedAt: risk.price.observedAt });
    }
    if (risk.result !== "pass") {
      await deps.store.transition(intent.id, s, "rejected", `risk: ${risk.reasonCodes.join(",")}`);
      await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.risk_rejected_at_submit", detail: { reasonCodes: risk.reasonCodes, policyVersion: risk.policyVersion } });
      return refuse("risk_rejected", "The order no longer passes your risk limits, so it wasn't sent.", "rejected", { reasonCodes: risk.reasonCodes });
    }
    // 7–8. Single use, single submitter.
    if (!(await deps.store.consumeApproval(intent.id, now))) return refuse("approval_used", "This approval has already been used or has expired.", s);
    if (!(await deps.store.transition(intent.id, "approved", "submitting"))) return refuse("conflict", "This order is already being sent.", s);
    return { risk };
  });
  if ("ok" in gate) return gate;
  const risk = gate.risk;
  await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.submitting", detail: { provider: intent.provider, environment: intent.environment, clientOrderID: intent.clientOrderID } });

  // 9. Submit. Never retried here or in the adapter.
  let result;
  let submitLatencyMs: number;
  const started = performance.now();
  try {
    result = await deps.adapter.submit(ctx, brokerRequest(intent));
    submitLatencyMs = Math.max(0, Math.round(performance.now() - started));
  } catch (error) {
    submitLatencyMs = Math.max(0, Math.round(performance.now() - started));
    // A refusal raised before any request left (environment, capability, validation) is a
    // known non-submission. Anything else is uncertain.
    if (error instanceof BrokerError && ["environment_refused", "unsupported", "invalid_request", "forbidden", "unauthorized", "insufficient_funds", "market_closed"].includes(error.code)) {
      const to: IntentStatus = error.code === "environment_refused" || error.code === "unsupported" ? "failed" : "rejected";
      await deps.store.transition(intent.id, "submitting", to, `adapter: ${error.code}`);
      await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.submit_refused", detail: { code: error.code, submitLatencyMs } });
      return refuse(error.code === "environment_refused" ? "feature_disabled" : "provider_error", error.message, to, brokerDetails(error));
    }
    result = { outcome: "unknown" as const, reason: error instanceof Error ? error.name : "unknown error" };
  }

  // 10. Record what happened.
  if (result.outcome === "accepted") {
    const status = await deps.store.recordBrokerOrder(intent.id, "submitting", result.order);
    await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.submitted", detail: { providerOrderID: result.order.providerOrderID, status: result.order.status, submitLatencyMs } });
    return { ok: true, status, brokerOrder: result.order, risk };
  }
  if (result.outcome === "rejected") {
    await deps.store.transition(intent.id, "submitting", "rejected", `provider: ${result.code}`);
    await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.provider_rejected", detail: { code: result.code, submitLatencyMs } });
    return refuse("provider_error", result.message, "rejected", { providerCode: result.code });
  }
  await deps.store.transition(intent.id, "submitting", "reconciliation_required", `unknown outcome: ${result.reason}`);
  await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.outcome_unknown", detail: { reason: result.reason, submitLatencyMs } });
  const settled = await reconcileIntent(deps, { ...intent, status: "reconciliation_required", reconcilingSince: now });
  return settled.ok && settled.status !== "reconciliation_required"
    ? settled
    : refuse("reconciliation_required", "We couldn't confirm the order with the provider yet. It won't be sent again; we'll keep checking.", "reconciliation_required");
}

/** How long an order the provider has never heard of stays in reconciliation before we call it failed. */
export const RECONCILE_GIVE_UP_MS = 10 * 60_000;

/** Brings one intent in line with the provider. Safe to call repeatedly (scheduler, manual refresh). */
export async function reconcileIntent(deps: ReconciliationDeps, intent: IntentRecord): Promise<ExecutionOutcome> {
  if (!AT_PROVIDER.includes(intent.status)) return { ok: true, status: intent.status };
  const ctx: AdapterContext = { ...deps.adapterContext, allowLive: false };
  let order: BrokerOrder | undefined;
  try {
    order = intent.providerOrderID
      ? await deps.adapter.getOrder(ctx, intent.providerOrderID)
      : await deps.adapter.findOrderByClientID(ctx, intent.clientOrderID);
  } catch (error) {
    if (error instanceof BrokerError && error.code === "not_found") order = undefined;
    else return refuse("provider_error", "The provider couldn't be reached. We'll try again.", intent.status, brokerDetails(error));
  }
  if (order) {
    if ((intent.providerOrderID && intent.providerOrderID !== order.providerOrderID) ||
      (order.clientOrderID && order.clientOrderID !== intent.clientOrderID)) {
      return refuse("provider_error", "The provider returned a different order. We’ll check again.", intent.status);
    }
    const status = await deps.store.recordBrokerOrder(intent.id, intent.status, order);
    return { ok: true, status, brokerOrder: order };
  }
  // An in-flight send may not be visible yet. A stranded send enters reconciliation
  // before its not-found grace period starts.
  if (intent.status === "submitting" && deps.now() - (intent.submittingAt ?? intent.createdAt) < 120_000) {
    return { ok: true, status: intent.status };
  }
  if (intent.status === "reconciliation_required") {
    // Alpaca has an exact client-ID lookup. An absent result from a bounded order list,
    // or a missing order that already has a provider ID, does not establish non-submission.
    if (intent.provider === "alpaca" && !intent.providerOrderID && intent.reconcilingSince !== undefined &&
      deps.now() - intent.reconcilingSince >= RECONCILE_GIVE_UP_MS) {
      const moved = await deps.store.transition(intent.id, intent.status, "failed", "provider has no record of this order");
      if (moved) await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.reconciled_not_found", detail: {} });
      return { ok: true, status: moved ? "failed" : intent.status };
    }
    return { ok: true, status: intent.status };
  }
  // A known order disappeared, or the provider never confirmed a stranded send.
  if (await deps.store.transition(intent.id, intent.status, "reconciliation_required", "provider order not found")) {
    return { ok: true, status: "reconciliation_required" };
  }
  return { ok: true, status: intent.status };
}

/**
 * Cancels an intent. Before submission it's local. After submission we ASK the provider and
 * only mark it cancelled once the provider reports it cancelled — a cancel request is not a
 * cancellation, and a partially filled order keeps its fills.
 */
export async function cancelIntent(deps: ExecutionDeps, intent: IntentRecord, caller: Caller): Promise<ExecutionOutcome> {
  if (caller.userID !== intent.userID) return refuse("forbidden", "Only the account owner can cancel this order.", intent.status);
  if (["draft", "risk_checked", "awaiting_approval", "approved"].includes(intent.status)) {
    const moved = await deps.store.transition(intent.id, intent.status, "cancelled", "cancelled before submission");
    return moved ? { ok: true, status: "cancelled" } : refuse("conflict", "The order changed while cancelling. Refresh and try again.", intent.status);
  }
  if (!AT_PROVIDER.includes(intent.status)) return refuse("conflict", "This order is already finished.", intent.status);
  if (!intent.providerOrderID) {
    return refuse("reconciliation_required", "We're still confirming this order with the provider; it can be cancelled once we know its id.", intent.status);
  }
  const ctx: AdapterContext = { ...deps.adapterContext, allowLive: intent.environment === "live" && deps.gates.live_execution.enabled };
  try {
    await deps.adapter.cancel(ctx, intent.providerOrderID);
  } catch (error) {
    return refuse("provider_error", "The provider didn't accept the cancel request. The order may still be open.", intent.status, brokerDetails(error));
  }
  await deps.store.audit({ userID: intent.userID, intentID: intent.id, kind: "oms.cancel_requested", detail: { providerOrderID: intent.providerOrderID } });
  return reconcileIntent(deps, intent);
}

function brokerDetails(error: unknown): Record<string, unknown> | undefined {
  if (error instanceof BrokerError) return { providerCode: error.details.providerCode ?? error.code, status: error.details.status };
  return undefined;
}
