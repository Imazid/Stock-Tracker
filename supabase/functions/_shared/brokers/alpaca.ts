// Alpaca Trading API v2 adapter (US stocks/ETFs and crypto; paper and live).
//
// Checked against docs.alpaca.markets in November 2026 (see docs/trading/provider-adapters.md
// for each page). Facts this file relies on:
//   * Hosts: paper https://paper-api.alpaca.markets, live https://api.alpaca.markets. Paper and
//     live use DIFFERENT keys; headers APCA-API-KEY-ID / APCA-API-SECRET-KEY.
//   * POST /v2/orders: `qty` XOR `notional`; `notional` only for market + day; fractional qty
//     only with day; client_order_id ≤ 128 chars; 403 = buying power/shares insufficient,
//     422 = input not recognised. Crypto: market/limit/stop_limit, gtc/ioc, "BTC/USD".
//   * Stop / stop-limit stock orders: day or gtc. IOC/FOK/OPG/CLS for stocks need Alpaca to
//     enable them on the account, so they aren't offered.
//   * GET /v2/orders: status open|closed|all, limit ≤ 500 (default 50), after/until are
//     exclusive timestamps, direction asc|desc (default desc).
//   * GET /v2/orders:by_client_order_id?client_order_id=… — the reconciliation lookup. The
//     docs only define 200; a missing order is treated as 404 (unverified, see doc).
//   * DELETE /v2/orders/{id}: 204 accepted; 422 = no longer cancelable.
//   * PATCH /v2/orders/{id}: returns a NEW order (new id, `replaces` links them). Not for
//     notional orders; not while accepted/pending_new/pending_cancel/pending_replace. A 200
//     doesn't guarantee the replace happened (the original may fill first).
//   * GET /v2/account/activities/FILL: page_size ≤ 100, page_token = id of the last item,
//     direction desc by default. The date filters use created_at, which the schema says is
//     null for trading activities — so `since` is ALSO applied here on transaction_time.
//   * API keys are not scoped: any valid Alpaca key can trade its account. There is no
//     read-only key to ask for, so "read-only" is enforced on our side by never granting the
//     connection `trade` permission.

import * as Decimal from "./decimal.ts";
import { errorFromResponse, type HttpRequest, type HttpResponse, query, read, sendOnce } from "./http.ts";
import {
  type AdapterContext,
  type BrokerAccount,
  type BrokerAdapter,
  type BrokerBalance,
  BrokerError,
  type BrokerFill,
  type BrokerOrder,
  type BrokerOrderRequest,
  type BrokerOrderStatus,
  type BrokerOrderType,
  type BrokerPosition,
  type BrokerTimeInForce,
  type ConnectionPermission,
  type Page,
  type ProviderCapabilities,
  type SubmitResult,
  type TradingEnvironment,
} from "./types.ts";
import { asArray, asRecord, assertMoneyMovementAllowed, decimalField, stringField, validateOrderRequest } from "./validation.ts";

const PROVIDER = "Alpaca";

export const ALPACA_HOSTS: Readonly<Record<"paper" | "live", string>> = Object.freeze({
  paper: "https://paper-api.alpaca.markets",
  live: "https://api.alpaca.markets",
});

/** Alpaca status → ours. Anything not listed (including future statuses) maps to `unknown`. */
export const ALPACA_STATUS: Readonly<Record<string, BrokerOrderStatus>> = Object.freeze({
  new: "accepted", // received and routed for execution
  accepted: "accepted", // received by Alpaca, not yet routed (e.g. outside hours)
  pending_new: "pending_new",
  accepted_for_bidding: "accepted",
  partially_filled: "partially_filled",
  filled: "filled",
  done_for_day: "accepted", // no more fills today; a GTC order resumes next session
  stopped: "accepted", // a fill is guaranteed but hasn't happened yet
  canceled: "canceled",
  expired: "expired",
  replaced: "replaced",
  pending_cancel: "pending_cancel",
  pending_replace: "pending_replace",
  rejected: "rejected",
  // Rare/ambiguous: left as `unknown` so reconciliation looks at them rather than guessing.
  //   suspended  — "not eligible for trading"
  //   calculated — "filled or done for day", settlement pending
  //   held       — bracket legs waiting on the parent (not on the statuses page)
});

const ORDER_TYPES: readonly BrokerOrderType[] = ["market", "limit", "stop", "stop_limit"];
const TIFS: readonly BrokerTimeInForce[] = ["day", "gtc", "ioc", "fok"];

function capabilities(environment: TradingEnvironment): ProviderCapabilities {
  if (environment === "sandbox") {
    return {
      provider: "alpaca",
      environment,
      executionAvailable: false,
      readAccounts: false,
      readPositions: false,
      readFills: false,
      orders: [],
      streaming: { orders: false, marketData: false },
      notes: ["Alpaca's Trading API has no separate sandbox; use a paper account (its own keys, simulated fills)."],
    };
  }
  const notes = [
    "Fractional stock quantities are day orders only; notional (cash amount) stock orders are market + day only.",
    "Stop and stop-limit stock orders are day or GTC. IOC/FOK/opening/closing-auction orders need Alpaca to enable them, so they aren't offered.",
    "Notional orders can't be modified — cancel and place a new one.",
    "Real-time stock prices on Alpaca's free market-data plan come from IEX only, a small share of US volume; consolidated (SIP) data needs the paid plan.",
    "Alpaca also offers websocket order updates; this adapter reconciles by polling instead.",
  ];
  if (environment === "paper") {
    notes.unshift(
      "Paper account: Alpaca simulates fills against live NBBO quotes (about 10% of eligible orders get a random partial fill). No regulatory fees or dividends are simulated, and order size isn't checked against displayed liquidity.",
    );
  } else {
    notes.unshift("Live account: real money. Orders are refused unless the platform's live gate, an approval and the risk checks pass.");
  }
  return {
    provider: "alpaca",
    environment,
    executionAvailable: true,
    readAccounts: true,
    readPositions: true,
    readFills: true,
    orders: [
      {
        assetClass: "us_equity",
        orderTypes: ["market", "limit", "stop", "stop_limit"],
        timeInForce: { market: ["day", "gtc"], limit: ["day", "gtc"], stop: ["day", "gtc"], stop_limit: ["day", "gtc"] },
        fractional: true,
        notional: true,
        replace: true,
        preview: false,
        shortSelling: false,
        margin: false,
      },
      {
        assetClass: "crypto",
        orderTypes: ["market", "limit", "stop_limit"],
        timeInForce: { market: ["gtc", "ioc"], limit: ["gtc", "ioc"], stop_limit: ["gtc", "ioc"] },
        fractional: true,
        notional: true,
        // Not confirmed in Alpaca's docs for crypto, so not offered.
        replace: false,
        preview: false,
        shortSelling: false,
        margin: false,
      },
    ],
    streaming: { orders: false, marketData: false },
    notes,
  };
}

// MARK: - Plumbing

function credentials(ctx: AdapterContext): { keyID: string; secretKey: string } {
  const c = ctx.credentials;
  if (c.provider !== "alpaca") throw new BrokerError("invalid_request", "These credentials aren't for Alpaca.");
  if (!c.keyID || !c.secretKey) throw new BrokerError("unauthorized", "An Alpaca key id and secret are required.");
  return c;
}

function host(ctx: AdapterContext): string {
  if (ctx.environment === "sandbox") throw new BrokerError("unsupported", "Alpaca has no sandbox environment; use paper.");
  return ALPACA_HOSTS[ctx.environment];
}

function request(ctx: AdapterContext, method: HttpRequest["method"], path: string, body?: unknown): HttpRequest {
  const { keyID, secretKey } = credentials(ctx);
  const headers: Record<string, string> = {
    "APCA-API-KEY-ID": keyID,
    "APCA-API-SECRET-KEY": secretKey,
    Accept: "application/json",
  };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  return { method, url: `${host(ctx)}${path}`, headers, body };
}

function secrets(ctx: AdapterContext): string[] {
  const c = ctx.credentials;
  return c.provider === "alpaca" ? [c.keyID, c.secretKey] : [];
}

async function getJSON(ctx: AdapterContext, path: string): Promise<unknown> {
  const response = await read(ctx, request(ctx, "GET", path), PROVIDER);
  if (response.status < 200 || response.status >= 300) throw errorFromResponse(PROVIDER, response, secrets(ctx));
  return response.body;
}

// MARK: - Normalisation

function mapType(raw: unknown): BrokerOrderType | "other" {
  return typeof raw === "string" && (ORDER_TYPES as readonly string[]).includes(raw) ? raw as BrokerOrderType : "other";
}

function mapTIF(raw: unknown): BrokerTimeInForce | "other" | undefined {
  if (typeof raw !== "string") return undefined;
  return (TIFS as readonly string[]).includes(raw) ? raw as BrokerTimeInForce : "other";
}

export function normaliseOrder(raw: unknown): BrokerOrder {
  const o = asRecord(raw, "order");
  const id = stringField(o, "id");
  const symbol = stringField(o, "symbol");
  const side = o.side;
  if (!id || !symbol || (side !== "buy" && side !== "sell")) throw new BrokerError("unexpected_response", "Alpaca returned an order without an id, symbol or side.");
  const providerStatus = stringField(o, "status") ?? "";
  return {
    providerOrderID: id,
    clientOrderID: stringField(o, "client_order_id"),
    symbol,
    side,
    type: mapType(o.type ?? o.order_type),
    timeInForce: mapTIF(o.time_in_force),
    status: ALPACA_STATUS[providerStatus] ?? "unknown",
    providerStatus,
    quantity: decimalField(o, "qty"),
    notional: decimalField(o, "notional"),
    filledQuantity: decimalField(o, "filled_qty") ?? "0",
    averageFillPrice: decimalField(o, "filled_avg_price"),
    limitPrice: decimalField(o, "limit_price"),
    stopPrice: decimalField(o, "stop_price"),
    submittedAt: stringField(o, "submitted_at"),
    updatedAt: stringField(o, "updated_at"),
  };
}

const STATUS_ACTIVE = "ACTIVE";

export function normaliseAccount(raw: unknown, environment: TradingEnvironment): BrokerAccount {
  const a = asRecord(raw, "account");
  const id = stringField(a, "id");
  if (!id) throw new BrokerError("unexpected_response", "Alpaca returned an account without an id.");
  const status = stringField(a, "status") ?? "";
  const blockers: string[] = [];
  if (a.trading_blocked === true) blockers.push("Trading is blocked on this account at Alpaca.");
  if (a.account_blocked === true) blockers.push("This account is blocked at Alpaca.");
  if (a.trade_suspended_by_user === true) blockers.push("Trading was suspended by the account holder at Alpaca.");
  const active = status === STATUS_ACTIVE || (status === "PAPER_ONLY" && environment === "paper");
  if (!active && status) blockers.push(`Alpaca reports the account status as ${status}.`);
  const tradingEnabled = active && blockers.length === 0;
  // Not a block by itself: a pattern day trader under US$25,000 equity is limited in day
  // trades, which Alpaca enforces on its side. Shown so nobody is surprised by a refusal.
  if (a.pattern_day_trader === true) blockers.push("Flagged as a pattern day trader: Alpaca may refuse day trades while equity is under US$25,000.");
  const number = stringField(a, "account_number");
  return {
    providerAccountID: id,
    label: `Alpaca ${environment === "live" ? "live" : "paper"}${number ? ` ${number}` : ""}`,
    environment,
    status: active ? "active" : status === "ACCOUNT_CLOSED" ? "closed" : status ? "restricted" : "unknown",
    currency: stringField(a, "currency") ?? "USD",
    cash: decimalField(a, "cash"),
    buyingPower: decimalField(a, "buying_power"),
    equity: decimalField(a, "equity"),
    tradingEnabled,
    tradingBlockers: blockers,
  };
}

/**
 * One balance per account. `available` is the non-marginable buying power (cash we may spend
 * without borrowing — this platform never uses margin), `reserved` what cash has committed
 * beyond that (open buy orders), never negative.
 */
export function normaliseBalance(raw: unknown): BrokerBalance {
  const a = asRecord(raw, "account");
  const id = stringField(a, "id");
  const cash = decimalField(a, "cash");
  if (!id || cash === undefined) throw new BrokerError("unexpected_response", "Alpaca returned an account without cash.");
  const nonMarginable = decimalField(a, "non_marginable_buying_power");
  const available = nonMarginable === undefined ? cash : Decimal.compare(nonMarginable, cash) > 0 ? cash : nonMarginable;
  const reserved = Decimal.max(Decimal.subtract(cash, available), "0");
  return { providerAccountID: id, currency: stringField(a, "currency") ?? "USD", total: Decimal.normalise(cash), available: Decimal.normalise(available), reserved };
}

export function normalisePosition(raw: unknown, accountID: string): BrokerPosition | undefined {
  const p = asRecord(raw, "position");
  const assetClass = p.asset_class;
  if (assetClass !== "us_equity" && assetClass !== "crypto") return undefined; // options etc. aren't modelled
  const symbol = stringField(p, "symbol");
  const quantity = decimalField(p, "qty");
  if (!symbol || quantity === undefined) throw new BrokerError("unexpected_response", "Alpaca returned a position without a symbol or quantity.");
  return {
    providerAccountID: accountID,
    symbol,
    assetClass,
    quantity,
    averageEntryPrice: decimalField(p, "avg_entry_price"),
    costBasis: decimalField(p, "cost_basis"),
    marketValue: decimalField(p, "market_value"),
    currency: "USD",
  };
}

export function normaliseFill(raw: unknown): BrokerFill {
  const f = asRecord(raw, "fill");
  const id = stringField(f, "id");
  const orderID = stringField(f, "order_id");
  const symbol = stringField(f, "symbol");
  const side = f.side;
  const quantity = decimalField(f, "qty");
  const price = decimalField(f, "price");
  const executedAt = stringField(f, "transaction_time");
  if (!id || !orderID || !symbol || (side !== "buy" && side !== "sell") || !quantity || !price || !executedAt) {
    throw new BrokerError("unexpected_response", "Alpaca returned a fill that couldn't be read.");
  }
  // Fees aren't on FILL activities; Alpaca reports them as separate activities.
  return { providerFillID: id, providerOrderID: orderID, symbol, side, quantity, price, executedAt };
}

// MARK: - Order outcomes

function rejectionFromResponse(response: HttpResponse, ctx: AdapterContext): SubmitResult {
  const error = errorFromResponse(PROVIDER, response, secrets(ctx));
  let code: string = error.code;
  if (response.status === 403) code = "insufficient_funds"; // the order endpoint's documented 403
  if (/client_order_id/i.test(error.message) && /unique|exist|duplicate/i.test(error.message)) code = "duplicate_client_order_id";
  return { outcome: "rejected", code, message: error.message };
}

function submitOutcome(response: HttpResponse, ctx: AdapterContext): SubmitResult {
  if (response.status >= 200 && response.status < 300) {
    try {
      return { outcome: "accepted", order: normaliseOrder(response.body) };
    } catch {
      // The provider said yes but we can't read what it created: we must not assume either way.
      return { outcome: "unknown", reason: "Alpaca accepted the request but its answer couldn't be read" };
    }
  }
  return rejectionFromResponse(response, ctx);
}

function orderBody(request: BrokerOrderRequest): Record<string, string> {
  const body: Record<string, string> = {
    symbol: request.symbol,
    side: request.side,
    type: request.type,
    time_in_force: request.timeInForce,
    client_order_id: request.clientOrderID,
  };
  if (request.quantity !== undefined) body.qty = request.quantity;
  if (request.notional !== undefined) body.notional = request.notional;
  if (request.limitPrice !== undefined) body.limit_price = request.limitPrice;
  if (request.stopPrice !== undefined) body.stop_price = request.stopPrice;
  return body;
}

function validateAlpaca(ctx: AdapterContext, request: BrokerOrderRequest): void {
  validateOrderRequest(capabilities(ctx.environment), request);
  if (request.assetClass === "us_equity") {
    if (request.notional !== undefined && (request.type !== "market" || request.timeInForce !== "day")) {
      throw new BrokerError("unsupported", "Alpaca accepts notional stock orders only as market orders for the day.");
    }
    if (request.quantity !== undefined && Decimal.isFractional(request.quantity) && request.timeInForce !== "day") {
      throw new BrokerError("unsupported", "Alpaca accepts fractional stock quantities only as day orders.");
    }
  } else if (request.notional !== undefined && request.type !== "market") {
    throw new BrokerError("unsupported", "Notional crypto orders are offered as market orders only.");
  }
}

// MARK: - The adapter

export const alpacaAdapter: BrokerAdapter = {
  provider: "alpaca",
  capabilities,

  async validate(ctx) {
    const accounts = await alpacaAdapter.accounts(ctx);
    // Alpaca keys aren't scoped: a valid key can always trade. Read-only is our setting.
    const permissions: ConnectionPermission[] = ["read", "trade"];
    return { accounts, permissions };
  },

  async accounts(ctx) {
    return [normaliseAccount(await getJSON(ctx, "/v2/account"), ctx.environment)];
  },

  async balances(ctx) {
    return [normaliseBalance(await getJSON(ctx, "/v2/account"))];
  },

  async positions(ctx) {
    const [account, positions] = await Promise.all([getJSON(ctx, "/v2/account"), getJSON(ctx, "/v2/positions")]);
    const accountID = stringField(asRecord(account, "account"), "id") ?? "";
    return asArray(positions, "positions").map((p) => normalisePosition(p, accountID)).filter((p): p is BrokerPosition => p !== undefined);
  },

  async fills(ctx, options): Promise<Page<BrokerFill>> {
    const pageSize = Math.min(Math.max(options.limit ?? 100, 1), 100);
    const raw = asArray(
      await getJSON(ctx, `/v2/account/activities/FILL${query({ direction: "desc", page_size: pageSize, page_token: options.cursor, after: options.since })}`),
      "fills",
    );
    const sinceMs = options.since ? Date.parse(options.since) : undefined;
    const fills = raw.map(normaliseFill);
    // Newest first: once one is older than `since`, every later one is too.
    const kept = sinceMs === undefined ? fills : fills.filter((f) => Date.parse(f.executedAt) > sinceMs);
    const exhausted = raw.length < pageSize || kept.length < fills.length;
    return { items: kept, cursor: exhausted ? undefined : fills[fills.length - 1].providerFillID };
  },

  async orders(ctx, options): Promise<Page<BrokerOrder>> {
    const limit = Math.min(Math.max(options.limit ?? 100, 1), 500);
    const raw = asArray(
      await getJSON(
        ctx,
        `/v2/orders${query({ status: options.status ?? "all", limit, direction: "desc", after: options.since, until: options.cursor, nested: "false" })}`,
      ),
      "orders",
    );
    const orders = raw.map(normaliseOrder);
    // Pages walk back in time with `until` = the oldest submitted_at seen. `until` is
    // exclusive, so two orders submitted at the same instant across a page edge could be
    // skipped; callers that need completeness reconcile by id.
    const last = orders[orders.length - 1];
    return { items: orders, cursor: orders.length < limit || !last?.submittedAt ? undefined : last.submittedAt };
  },

  async submit(ctx, req) {
    assertMoneyMovementAllowed(ctx, "place an order");
    validateAlpaca(ctx, req);
    const outcome = await sendOnce(ctx, request(ctx, "POST", "/v2/orders", orderBody(req)));
    if (outcome.kind === "unknown") return { outcome: "unknown", reason: outcome.reason };
    return submitOutcome(outcome.response, ctx);
  },

  async cancel(ctx, providerOrderID) {
    assertMoneyMovementAllowed(ctx, "cancel an order");
    const response = await read(ctx, request(ctx, "DELETE", `/v2/orders/${encodeURIComponent(providerOrderID)}`), PROVIDER);
    if (response.status === 204 || response.status === 200) return { accepted: true };
    if (response.status === 422) return { accepted: false, message: "Alpaca says the order can no longer be cancelled (it may have filled)." };
    throw errorFromResponse(PROVIDER, response, secrets(ctx));
  },

  async replace(ctx, providerOrderID, changes) {
    assertMoneyMovementAllowed(ctx, "modify an order");
    const body: Record<string, string> = {};
    if (changes.quantity !== undefined) {
      if (!Decimal.isPositiveDecimal(changes.quantity) || Decimal.isFractional(changes.quantity)) {
        throw new BrokerError("invalid_request", "Alpaca only changes quantities to a whole number of shares.");
      }
      body.qty = changes.quantity;
    }
    if (changes.limitPrice !== undefined) {
      if (!Decimal.isPositiveDecimal(changes.limitPrice)) throw new BrokerError("invalid_request", "limitPrice must be a positive decimal string.");
      body.limit_price = changes.limitPrice;
    }
    if (changes.stopPrice !== undefined) {
      if (!Decimal.isPositiveDecimal(changes.stopPrice)) throw new BrokerError("invalid_request", "stopPrice must be a positive decimal string.");
      body.stop_price = changes.stopPrice;
    }
    if (Object.keys(body).length === 0) throw new BrokerError("invalid_request", "Nothing to change.");
    const outcome = await sendOnce(ctx, request(ctx, "PATCH", `/v2/orders/${encodeURIComponent(providerOrderID)}`, body));
    if (outcome.kind === "unknown") return { outcome: "unknown", reason: outcome.reason };
    return submitOutcome(outcome.response, ctx);
  },

  async getOrder(ctx, providerOrderID) {
    return normaliseOrder(await getJSON(ctx, `/v2/orders/${encodeURIComponent(providerOrderID)}`));
  },

  async findOrderByClientID(ctx, clientOrderID) {
    const response = await read(ctx, request(ctx, "GET", `/v2/orders:by_client_order_id${query({ client_order_id: clientOrderID })}`), PROVIDER);
    if (response.status === 404) return undefined;
    if (response.status < 200 || response.status >= 300) throw errorFromResponse(PROVIDER, response, secrets(ctx));
    return normaliseOrder(response.body);
  },
};
