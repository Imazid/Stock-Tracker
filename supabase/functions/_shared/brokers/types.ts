// The provider adapter contract: one shape for every brokerage or exchange we read from or
// (later) trade through. Nothing above this layer may assume two providers behave alike —
// the UI and the order system ask `capabilities()` what a specific account, instrument and
// environment can actually do, and offer only that.
//
// Rules every adapter keeps:
//  * Pure transport + normalisation. No risk decisions, no approvals, no persistence: those
//    belong to ../oms (order management) and the database. An adapter is handed decrypted
//    credentials for one call and must not keep, log or return them.
//  * Money and quantities cross this boundary as DECIMAL STRINGS exactly as the provider sent
//    them ("0.00012345"), never as JS numbers, so nothing is rounded on the way in or out.
//  * Every order carries our `clientOrderID`. It is the idempotency key at the provider
//    (Alpaca `client_order_id`, Coinbase `client_order_id`), so a resubmission of the same
//    intent can't create a second order.
//  * A submission whose outcome we don't know (timeout, connection reset, 5xx after the body
//    was sent) is reported as `{ outcome: "unknown" }` — NEVER retried. The caller must
//    reconcile with `findOrderByClientID` before doing anything else.
//  * Withdrawal and transfer endpoints are out of scope for this contract on purpose.

export type ProviderID = "alpaca" | "coinbase";

/** Where an account's orders go. `paper`/`sandbox` never touch real money; `live` does. */
export type TradingEnvironment = "paper" | "sandbox" | "live";

export type AssetClass = "us_equity" | "crypto";

/** What a connection was granted by the person (and the provider's key scopes). */
export type ConnectionPermission = "read" | "trade";

export type BrokerOrderSide = "buy" | "sell";
export type BrokerOrderType = "market" | "limit" | "stop" | "stop_limit";
export type BrokerTimeInForce = "day" | "gtc" | "ioc" | "fok";

/** Normalised provider order status. `unknown` is ours: the provider gave a status we don't map. */
export type BrokerOrderStatus =
  | "pending_new"
  | "accepted"
  | "partially_filled"
  | "filled"
  | "canceled"
  | "expired"
  | "rejected"
  | "pending_cancel"
  | "pending_replace"
  | "replaced"
  | "unknown";

export const TERMINAL_BROKER_STATUSES: readonly BrokerOrderStatus[] = ["filled", "canceled", "expired", "rejected", "replaced"];

/** Decrypted credentials, handed to an adapter for the duration of one call. */
export type ProviderCredentials =
  | { provider: "alpaca"; keyID: string; secretKey: string }
  | {
    provider: "coinbase";
    /** CDP API key name: "organizations/{org_id}/apiKeys/{key_id}". */
    keyName: string;
    /** EC P-256 private key, PEM ("-----BEGIN EC PRIVATE KEY-----" or PKCS#8). */
    privateKeyPEM: string;
    /** Coinbase portfolio the key is scoped to, when the key is portfolio-specific. */
    portfolioID?: string;
  };

export interface AdapterContext {
  environment: TradingEnvironment;
  credentials: ProviderCredentials;
  /** Injected for tests; defaults to global fetch. */
  fetch?: typeof fetch;
  /** Injected clock (ms since epoch) for signing and timestamps. */
  now?: () => number;
  /** Request timeout in ms (default 10s). */
  timeoutMs?: number;
}

// MARK: - Capabilities

export interface OrderCapability {
  assetClass: AssetClass;
  orderTypes: BrokerOrderType[];
  /** Time-in-force values accepted for each order type. */
  timeInForce: Partial<Record<BrokerOrderType, BrokerTimeInForce[]>>;
  fractional: boolean;
  /** Notional (cash amount) orders, e.g. "buy $100 of BTC". */
  notional: boolean;
  /** Order replace / edit supported. */
  replace: boolean;
  /** Provider-side order preview (fees / estimated fill) before submitting. */
  preview: boolean;
  shortSelling: false;
  margin: false;
}

export interface ProviderCapabilities {
  provider: ProviderID;
  environment: TradingEnvironment;
  /** True only if this environment can execute at all (Coinbase has no paper venue). */
  executionAvailable: boolean;
  readAccounts: boolean;
  readPositions: boolean;
  readFills: boolean;
  orders: OrderCapability[];
  streaming: { orders: boolean; marketData: boolean };
  /** Plain-language limits the UI shows next to the order ticket. */
  notes: string[];
}

// MARK: - Normalised records

export interface BrokerAccount {
  providerAccountID: string;
  /** e.g. "Alpaca paper", "Coinbase – Default portfolio". */
  label: string;
  environment: TradingEnvironment;
  status: "active" | "restricted" | "closed" | "unknown";
  currency: string;
  /** Provider-reported values (decimal strings). */
  cash?: string;
  buyingPower?: string;
  equity?: string;
  /** True if the provider says this account may trade right now. */
  tradingEnabled: boolean;
  /** Reasons trading is blocked at the provider (pattern-day-trader, account blocked, ...). */
  tradingBlockers: string[];
}

export interface BrokerBalance {
  providerAccountID: string;
  currency: string;
  total: string;
  available: string;
  reserved: string;
}

export interface BrokerPosition {
  providerAccountID: string;
  /** Provider's symbol ("AAPL", "BTC/USD", "BTC-USD"). */
  symbol: string;
  assetClass: AssetClass;
  quantity: string;
  /** Average entry price in `currency`, when the provider reports one. */
  averageEntryPrice?: string;
  costBasis?: string;
  marketValue?: string;
  currency: string;
}

export interface BrokerOrderRequest {
  /** Our idempotency key. 1–48 chars, [A-Za-z0-9-]. Required. */
  clientOrderID: string;
  symbol: string;
  assetClass: AssetClass;
  side: BrokerOrderSide;
  type: BrokerOrderType;
  timeInForce: BrokerTimeInForce;
  /** Exactly one of quantity / notional. */
  quantity?: string;
  notional?: string;
  limitPrice?: string;
  stopPrice?: string;
}

export interface BrokerOrder {
  providerOrderID: string;
  clientOrderID?: string;
  symbol: string;
  side: BrokerOrderSide;
  type: BrokerOrderType | "other";
  timeInForce?: BrokerTimeInForce | "other";
  status: BrokerOrderStatus;
  /** The provider's own status text, kept for audit. */
  providerStatus: string;
  quantity?: string;
  notional?: string;
  filledQuantity: string;
  averageFillPrice?: string;
  limitPrice?: string;
  stopPrice?: string;
  submittedAt?: string; // ISO-8601 UTC
  updatedAt?: string; // ISO-8601 UTC
}

export interface BrokerFill {
  providerFillID: string;
  providerOrderID: string;
  symbol: string;
  side: BrokerOrderSide;
  quantity: string;
  price: string;
  fee?: string;
  feeCurrency?: string;
  executedAt: string; // ISO-8601 UTC
}

export interface OrderPreview {
  estimatedQuantity?: string;
  estimatedNotional?: string;
  estimatedFee?: string;
  feeCurrency?: string;
  warnings: string[];
  errors: string[];
}

/** One page of a paginated history read. `cursor` is opaque; undefined means no more pages. */
export interface Page<T> {
  items: T[];
  cursor?: string;
}

export type SubmitResult =
  | { outcome: "accepted"; order: BrokerOrder }
  | { outcome: "rejected"; code: string; message: string }
  /** We don't know if the provider created the order. Reconcile; do not resubmit. */
  | { outcome: "unknown"; reason: string };

// MARK: - Errors

export type BrokerErrorCode =
  | "unauthorized" // bad or revoked key
  | "forbidden" // key lacks the scope (e.g. read-only key asked to trade)
  | "not_found"
  | "rate_limited"
  | "invalid_request"
  | "insufficient_funds"
  | "market_closed"
  | "unsupported" // capability not offered by this provider/environment
  | "environment_refused" // e.g. live requested while the platform gate is off
  | "provider_unavailable" // 5xx / network after retries (reads only)
  | "unexpected_response";

export class BrokerError extends Error {
  constructor(
    readonly code: BrokerErrorCode,
    message: string,
    readonly details: { status?: number; providerCode?: string; retryAfterMs?: number } = {},
  ) {
    super(message);
    this.name = "BrokerError";
  }
}

// MARK: - The adapter

export interface BrokerAdapter {
  readonly provider: ProviderID;
  capabilities(environment: TradingEnvironment): ProviderCapabilities;

  /** Cheap authenticated call proving the key works; returns the scopes we could detect. */
  validate(ctx: AdapterContext): Promise<{ accounts: BrokerAccount[]; permissions: ConnectionPermission[] }>;
  accounts(ctx: AdapterContext): Promise<BrokerAccount[]>;
  balances(ctx: AdapterContext): Promise<BrokerBalance[]>;
  positions(ctx: AdapterContext): Promise<BrokerPosition[]>;
  /** Fills newest-first or oldest-first per provider; callers dedupe on providerFillID. */
  fills(ctx: AdapterContext, options: { since?: string; cursor?: string; limit?: number }): Promise<Page<BrokerFill>>;
  orders(ctx: AdapterContext, options: { status?: "open" | "closed" | "all"; since?: string; cursor?: string; limit?: number }): Promise<Page<BrokerOrder>>;

  preview?(ctx: AdapterContext, request: BrokerOrderRequest): Promise<OrderPreview>;
  /** Never retried internally. See SubmitResult. */
  submit(ctx: AdapterContext, request: BrokerOrderRequest): Promise<SubmitResult>;
  cancel(ctx: AdapterContext, providerOrderID: string): Promise<{ accepted: boolean; message?: string }>;
  replace?(ctx: AdapterContext, providerOrderID: string, changes: { quantity?: string; limitPrice?: string; stopPrice?: string }): Promise<SubmitResult>;
  getOrder(ctx: AdapterContext, providerOrderID: string): Promise<BrokerOrder>;
  /** The reconciliation lookup after an `unknown` submit. Undefined = provider has no such order. */
  findOrderByClientID(ctx: AdapterContext, clientOrderID: string): Promise<BrokerOrder | undefined>;
}
