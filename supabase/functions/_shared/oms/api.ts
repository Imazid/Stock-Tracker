// HTTP contract for the two provider-facing edge functions. The web app and the iPhone app
// code against these types; the functions implement them.
//
//   broker-connections   connect / list / sync / revoke a provider account (Alpaca, Coinbase)
//   broker-orders        an order sent to a PROVIDER (Alpaca paper today; live only behind the
//                        platform gate): draft → risk check → approve → submit → reconcile
//
// Local practice trading (simulated fills in our own database) is NOT here: that is the
// `trading-api` function. Two paths, never mixed: a `broker-orders` intent always names a
// connected provider account; a `trading-api` order never leaves our database.
//
// Every call: POST JSON `{ "action": ..., ...fields }`, `Authorization: Bearer <user JWT>`.
// The user id always comes from the token, never the body. State-changing calls also take an
// `Idempotency-Key` header (8–128 chars); a retry with the same key returns the first answer.
//
// Same envelope as trading-api: success `{ ok: true, data }`; refusal
// `{ ok: false, error: { code, message, details? } }` with a machine-readable `code`
// (plus `unauthenticated` / `unavailable` from the sign-in check):
//   unauthorized | step_up_required | forbidden | not_found | invalid | conflict
//   | feature_disabled      (a platform/compliance gate is off — details.gate names it)
//   | kill_switch_engaged | risk_rejected (details.reasonCodes) | approval_invalid
//   | approval_expired | approval_used | intent_changed | stale_price
//   | provider_error (details.providerCode) | reconciliation_required | rate_limited

import type {
  BrokerOrderSide,
  BrokerOrderStatus,
  BrokerOrderType,
  BrokerTimeInForce,
  ConnectionPermission,
  ProviderCapabilities,
  ProviderID,
  TradingEnvironment,
} from "../brokers/types.ts";

export type ApiErrorCode =
  | "unauthorized"
  | "step_up_required"
  | "forbidden"
  | "not_found"
  | "invalid"
  | "conflict"
  | "feature_disabled"
  | "kill_switch_engaged"
  | "risk_rejected"
  | "approval_invalid"
  | "approval_expired"
  | "approval_used"
  | "intent_changed"
  | "stale_price"
  | "provider_error"
  | "reconciliation_required"
  | "rate_limited"
  | "method_not_allowed"
  | "internal";

export interface ApiError {
  error: { code: ApiErrorCode; message: string; details?: Record<string, unknown> };
}

// MARK: - broker-connections

export type ConnectionStatus = "active" | "needs_attention" | "revoked";
export type SyncState = "never" | "running" | "ok" | "failed";

export interface ConnectionView {
  id: string;
  provider: ProviderID;
  environment: TradingEnvironment;
  label: string;
  /** What the person granted. `trade` on a live connection is refused while the live gate is off. */
  permissions: ConnectionPermission[];
  status: ConnectionStatus;
  /** Last four characters of the key id, for recognition. The key itself is never returned. */
  keyHint: string;
  sync: { state: SyncState; lastSuccessAt?: string; lastError?: string; repair?: string };
  capabilities: ProviderCapabilities;
  createdAt: string;
}

export type ConnectionsRequest =
  | { action: "list" }
  | {
    action: "connect";
    provider: ProviderID;
    environment: TradingEnvironment;
    label?: string;
    /** Requested permissions; `trade` is only granted when the key's scopes allow it. */
    permissions: ConnectionPermission[];
    /** Write-only. Alpaca: { keyID, secretKey }. Coinbase: { keyName, privateKeyPEM, portfolioID? }. */
    credentials: Record<string, string>;
  }
  | { action: "sync"; connectionID: string }
  | { action: "revoke"; connectionID: string };

export type ConnectionsResponse =
  | { connections: ConnectionView[] }
  | { connection: ConnectionView }
  | { connection: ConnectionView; synced: { accounts: number; positions: number; fills: number; orders: number } }
  | { revoked: true };

// MARK: - broker-orders

/** The lifecycle the brief asks for, persisted transition by transition. */
export type IntentStatus =
  | "draft"
  | "risk_checked"
  | "awaiting_approval"
  | "approved"
  | "submitting"
  | "submitted"
  | "partially_filled"
  | "filled"
  | "rejected"
  | "expired"
  | "cancelled"
  | "failed"
  | "reconciliation_required";

export interface OrderIntentInput {
  connectionID: string;
  /** Provider symbol as listed by the provider ("AAPL", "BTC/USD" on Alpaca, "BTC-USD" on Coinbase). */
  symbol: string;
  assetClass: "us_equity" | "crypto";
  side: BrokerOrderSide;
  type: BrokerOrderType;
  timeInForce: BrokerTimeInForce;
  /** Exactly one of quantity / notional, decimal strings. */
  quantity?: string;
  notional?: string;
  limitPrice?: string;
  stopPrice?: string;
  /** Who drafted it. An agent can draft; only a person can approve. */
  origin: { kind: "manual" } | { kind: "agent"; agentID: string; rationale: string };
}

export interface RiskEvaluationView {
  policyVersion: number;
  result: "pass" | "fail";
  reasonCodes: string[];
  checks: { id: string; status: "passed" | "warning" | "failed" | "notApplicable"; detail: string }[];
  /** The price the checks used, and where/when it came from. */
  price: { value: string; currency: string; source: string; observedAt: string; status: "real_time" | "delayed" | "indicative" };
  evaluatedAt: string;
}

export interface OrderIntentView extends OrderIntentInput {
  id: string;
  provider: ProviderID;
  environment: TradingEnvironment;
  status: IntentStatus;
  /** SHA-256 of the canonical intent. An approval covers exactly this hash. */
  intentHash: string;
  /** Our idempotency key at the provider. */
  clientOrderID: string;
  estimate: { notional?: string; fee?: string; feeCurrency?: string; currency: string };
  risk?: RiskEvaluationView;
  approval?: { approvedAt: string; expiresAt: string; consumedAt?: string; aal: "aal1" | "aal2" };
  brokerOrder?: {
    providerOrderID: string;
    status: BrokerOrderStatus;
    filledQuantity: string;
    averageFillPrice?: string;
    submittedAt?: string;
    updatedAt?: string;
  };
  transitions: { from: IntentStatus | null; to: IntentStatus; at: string; note?: string }[];
  createdAt: string;
  /** An unapproved intent expires; so does an approval. */
  expiresAt: string;
}

export type OrdersRequest =
  | { action: "list"; status?: "open" | "closed" | "all" }
  | { action: "get"; intentID: string }
  | { action: "draft"; intent: OrderIntentInput }
  | { action: "riskCheck"; intentID: string }
  /** `intentHash` must equal the stored hash: the person approves what they saw, nothing else. */
  | { action: "approve"; intentID: string; intentHash: string }
  | { action: "reject"; intentID: string; reason?: string }
  | { action: "submit"; intentID: string }
  | { action: "cancel"; intentID: string }
  | { action: "reconcile"; intentID: string };

export type OrdersResponse = { intents: OrderIntentView[] } | { intent: OrderIntentView };

// MARK: - Platform gates (read-only to clients; changed only by an administrator server-side)

export type GateID =
  | "provider_paper_execution" // Alpaca paper orders through broker-orders
  | "live_execution" // any real-money order
  | "automated_live_execution" // agent mandates without per-order approval
  | "personalised_recommendations" // agent output phrased as advice for this person
  | "custodial_features";

export interface GatesView {
  gates: Record<GateID, { enabled: boolean; reason: string; updatedAt?: string }>;
  killSwitch: { engaged: boolean; engagedAt?: string };
}
