// Coinbase Advanced Trade API v3 adapter (spot crypto; live, plus Coinbase's static sandbox).
//
// Checked against docs.cdp.coinbase.com in November 2026 (pages listed in
// docs/trading/provider-adapters.md). Facts this file relies on:
//   * Base https://api.coinbase.com/api/v3/brokerage; auth = a fresh ES256 JWT per request
//     (coinbase_auth.ts).
//   * Sandbox https://api-sandbox.coinbase.com/api/v3/brokerage: "All responses are static and
//     pre-defined", only Accounts and Orders endpoints, NO authentication — so keys are never
//     sent there. Nothing executes in it.
//   * There is no paper venue.
//   * POST /orders: client_order_id, product_id ("BTC-USD"), side BUY|SELL, order_configuration
//     with exactly one key. market_market_ioc / market_market_fok {quote_size|base_size};
//     limit_limit_gtc {quote_size|base_size, limit_price, post_only}; limit_limit_fok and
//     sor_limit_ioc {quote_size|base_size, limit_price}; stop_limit_stop_limit_gtc {base_size,
//     limit_price, stop_price, stop_direction STOP_DIRECTION_STOP_UP|STOP_DOWN}.
//     The answer is HTTP 200 either way: {success:true, success_response{order_id,...}} or
//     {success:false, error_response{message, new_order_failure_reason,...}}. A duplicate
//     client_order_id doesn't create a second order — Coinbase returns the existing one.
//   * retail_portfolio_id is deprecated on create/list; a CDP key is scoped to its own
//     portfolio, so it isn't sent.
//   * GET /orders/historical/batch has NO client_order_id filter (only order_ids etc.), so
//     findOrderByClientID pages recent orders and matches locally (bounded; see below).
//   * GET /orders/historical/{id} → {order}; statuses PENDING, OPEN, FILLED, CANCELLED,
//     EXPIRED, FAILED, UNKNOWN_ORDER_STATUS, QUEUED, CANCEL_QUEUED, EDIT_QUEUED.
//   * GET /orders/historical/fills → {fills[], cursor}; entry_id is the unique fill id
//     (trade_id isn't unique for adjusted fills); commission is the fee.
//   * POST /orders/batch_cancel {order_ids} → results[{success, failure_reason, order_id}].
//   * POST /orders/edit {order_id, price, size, stop_price?} → {success, errors[]}; the docs
//     only hint (ONLY_LIMIT_ORDER_EDITS_SUPPORTED) that limit orders are the editable kind.
//   * POST /orders/preview → order_total, commission_total, errs[], warning[], quote_size,
//     base_size, best_bid, best_ask, preview_id?, slippage?, est_average_filled_price?.
//   * GET /key_permissions → can_view, can_trade, can_transfer, portfolio_uuid, portfolio_type.
//   * GET /accounts: limit ≤ 250 (default 49), cursor, has_next; available_balance and hold
//     are {value, currency} decimal strings.

import { buildJWT, importSigningKey } from "./coinbase_auth.ts";
import * as Decimal from "./decimal.ts";
import { errorFromResponse, type HttpRequest, type HttpResponse, query, read, sendOnce } from "./http.ts";
import {
  type AdapterContext,
  type BrokerAccount,
  type BrokerAdapter,
  type BrokerBalance,
  BrokerError,
  type BrokerErrorCode,
  type BrokerFill,
  type BrokerOrder,
  type BrokerOrderRequest,
  type BrokerOrderStatus,
  type BrokerOrderType,
  type BrokerPosition,
  type BrokerTimeInForce,
  type OrderPreview,
  type Page,
  type ProviderCapabilities,
  type SubmitResult,
  type TradingEnvironment,
} from "./types.ts";
import { asArray, asRecord, assertMoneyMovementAllowed, decimalField, stringField, validateOrderRequest } from "./validation.ts";

const PROVIDER = "Coinbase";
const PREFIX = "/api/v3/brokerage";

export const COINBASE_HOSTS: Readonly<Record<"live" | "sandbox", string>> = Object.freeze({
  live: "api.coinbase.com",
  sandbox: "api-sandbox.coinbase.com",
});

/** How many recent orders findOrderByClientID searches (5 pages × 100). */
export const CLIENT_ID_SEARCH_PAGES = 5;

export const COINBASE_STATUS: Readonly<Record<string, BrokerOrderStatus>> = Object.freeze({
  PENDING: "pending_new",
  QUEUED: "pending_new",
  OPEN: "accepted", // → partially_filled when filled_size > 0
  FILLED: "filled",
  CANCELLED: "canceled",
  EXPIRED: "expired",
  FAILED: "rejected",
  CANCEL_QUEUED: "pending_cancel",
  EDIT_QUEUED: "pending_replace",
  UNKNOWN_ORDER_STATUS: "unknown",
});

const TIF_FROM_COINBASE: Readonly<Record<string, BrokerTimeInForce | "other">> = Object.freeze({
  GOOD_UNTIL_CANCELLED: "gtc",
  IMMEDIATE_OR_CANCEL: "ioc",
  FILL_OR_KILL: "fok",
  GOOD_UNTIL_DATE_TIME: "other",
});

const TYPE_FROM_COINBASE: Readonly<Record<string, BrokerOrderType>> = Object.freeze({
  MARKET: "market",
  LIMIT: "limit",
  STOP: "stop",
  STOP_LIMIT: "stop_limit",
});

function capabilities(environment: TradingEnvironment): ProviderCapabilities {
  if (environment === "paper") {
    return {
      provider: "coinbase",
      environment,
      executionAvailable: false,
      readAccounts: false,
      readPositions: false,
      readFills: false,
      orders: [],
      streaming: { orders: false, marketData: false },
      notes: ["Coinbase has no paper-trading venue. Use Stock Tracker's practice trading, or the static sandbox for integration tests."],
    };
  }
  const notes = [
    "Spot crypto only. Market orders are IOC or FOK; limit orders GTC, IOC (smart order routing) or FOK; stop-limit orders GTC with a whole base size.",
    "Order changes (edit) apply to open limit orders; Coinbase's docs don't list other editable types.",
    "Coinbase also offers websocket order updates; this adapter reconciles by polling instead.",
  ];
  if (environment === "sandbox") {
    notes.unshift(
      "Sandbox: every answer is a static, pre-defined test response — nothing executes and balances never change. No keys are sent to it.",
    );
  } else {
    notes.unshift("Live: real money. Orders are refused unless the platform's live gate, an approval and the risk checks pass.");
  }
  return {
    provider: "coinbase",
    environment,
    executionAvailable: true,
    readAccounts: true,
    readPositions: true,
    readFills: true,
    orders: [
      {
        assetClass: "crypto",
        orderTypes: ["market", "limit", "stop_limit"],
        timeInForce: { market: ["ioc", "fok"], limit: ["gtc", "ioc", "fok"], stop_limit: ["gtc"] },
        fractional: true,
        notional: true,
        replace: true,
        preview: true,
        shortSelling: false,
        margin: false,
      },
    ],
    streaming: { orders: false, marketData: false },
    notes,
  };
}

// MARK: - Plumbing

const signingKeys = new WeakMap<AdapterContext, Promise<CryptoKey>>();

function liveCredentials(ctx: AdapterContext): { keyName: string; privateKeyPEM: string; portfolioID?: string } {
  const c = ctx.credentials;
  if (c.provider !== "coinbase") throw new BrokerError("invalid_request", "These credentials aren't for Coinbase.");
  if (!c.keyName || !c.privateKeyPEM) throw new BrokerError("unauthorized", "A Coinbase API key name and private key are required.");
  return c;
}

function hostFor(ctx: AdapterContext): string {
  if (ctx.environment === "paper") throw new BrokerError("unsupported", "Coinbase has no paper-trading environment.");
  return COINBASE_HOSTS[ctx.environment];
}

async function buildRequest(
  ctx: AdapterContext,
  method: HttpRequest["method"],
  path: string,
  params: Parameters<typeof query>[0] = {},
  body?: unknown,
): Promise<HttpRequest> {
  const host = hostFor(ctx);
  const headers: Record<string, string> = { Accept: "application/json" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (ctx.environment === "live") {
    const { keyName, privateKeyPEM } = liveCredentials(ctx);
    let key = signingKeys.get(ctx);
    if (!key) {
      key = importSigningKey(privateKeyPEM);
      signingKeys.set(ctx, key);
    }
    headers.Authorization = `Bearer ${await buildJWT({ keyName, key: await key, method, host, path: `${PREFIX}${path}`, nowMs: (ctx.now ?? Date.now)() })}`;
  }
  return { method, url: `https://${host}${PREFIX}${path}${query(params)}`, headers, body };
}

function secrets(ctx: AdapterContext): string[] {
  const c = ctx.credentials;
  return c.provider === "coinbase" ? [c.privateKeyPEM, c.keyName] : [];
}

function ok(response: HttpResponse): boolean {
  return response.status >= 200 && response.status < 300;
}

async function getJSON(ctx: AdapterContext, path: string, params: Parameters<typeof query>[0] = {}): Promise<Record<string, unknown>> {
  const response = await read(ctx, await buildRequest(ctx, "GET", path, params), PROVIDER);
  if (!ok(response)) throw errorFromResponse(PROVIDER, response, secrets(ctx));
  return asRecord(response.body, path);
}

// MARK: - Normalisation

function amount(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  if (!value || typeof value !== "object") return undefined;
  return decimalField(value as Record<string, unknown>, "value");
}

function quoteCurrency(productID: string): string | undefined {
  const parts = productID.split("-");
  return parts.length === 2 ? parts[1] : undefined;
}

/** The one inner object of an order_configuration. */
function configuration(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== "object") return {};
  for (const value of Object.values(raw as Record<string, unknown>)) {
    if (value && typeof value === "object") return value as Record<string, unknown>;
  }
  return {};
}

function positive(value: string | undefined): boolean {
  return value !== undefined && Decimal.compare(value, "0") > 0;
}

export function normaliseOrder(raw: unknown): BrokerOrder {
  const o = asRecord(raw, "order");
  const id = stringField(o, "order_id");
  const productID = stringField(o, "product_id");
  const side = o.side === "BUY" ? "buy" : o.side === "SELL" ? "sell" : undefined;
  if (!id || !productID || !side) throw new BrokerError("unexpected_response", "Coinbase returned an order without an id, product or side.");
  const providerStatus = stringField(o, "status") ?? "";
  const filled = decimalField(o, "filled_size") ?? "0";
  let status = COINBASE_STATUS[providerStatus] ?? "unknown";
  if (status === "accepted" && positive(filled)) status = "partially_filled";
  const config = configuration(o.order_configuration);
  const orderType = stringField(o, "order_type");
  const tif = stringField(o, "time_in_force");
  return {
    providerOrderID: id,
    clientOrderID: stringField(o, "client_order_id"),
    symbol: productID,
    side,
    type: orderType ? TYPE_FROM_COINBASE[orderType] ?? "other" : "other",
    timeInForce: tif ? TIF_FROM_COINBASE[tif] ?? "other" : undefined,
    status,
    providerStatus,
    quantity: decimalField(config, "base_size"),
    notional: decimalField(config, "quote_size"),
    filledQuantity: filled,
    averageFillPrice: positive(filled) ? decimalField(o, "average_filled_price") : undefined,
    limitPrice: decimalField(config, "limit_price"),
    stopPrice: decimalField(config, "stop_price"),
    submittedAt: stringField(o, "created_time"),
    updatedAt: stringField(o, "last_update_time") ?? stringField(o, "last_fill_time"),
  };
}

export function normaliseFill(raw: unknown): BrokerFill {
  const f = asRecord(raw, "fill");
  const id = stringField(f, "entry_id");
  const orderID = stringField(f, "order_id");
  const productID = stringField(f, "product_id");
  const side = f.side === "BUY" ? "buy" : f.side === "SELL" ? "sell" : undefined;
  const size = decimalField(f, "size");
  const price = decimalField(f, "price");
  const executedAt = stringField(f, "trade_time");
  if (!id || !orderID || !productID || !side || !size || !price || !executedAt || !positive(price)) {
    throw new BrokerError("unexpected_response", "Coinbase returned a fill that couldn't be read.");
  }
  // UNVERIFIED (see docs): when the order was sized in the quote currency, `size` is read as a
  // quote amount and converted to base units (truncated at 18 places).
  const quantity = f.size_in_quote === true ? Decimal.divide(size, price, 18) : size;
  return {
    providerFillID: id,
    providerOrderID: orderID,
    symbol: productID,
    side,
    quantity,
    price,
    fee: decimalField(f, "commission"),
    feeCurrency: quoteCurrency(productID),
    executedAt,
  };
}

interface RawAccount {
  portfolioID: string;
  currency: string;
  type: string;
  available: string;
  hold: string;
}

function readAccount(raw: unknown, fallbackPortfolio: string): RawAccount | undefined {
  const a = asRecord(raw, "account");
  if (a.active === false || (a.deleted_at !== undefined && a.deleted_at !== null && a.deleted_at !== "")) return undefined;
  const currency = stringField(a, "currency");
  const available = amount(a, "available_balance");
  if (!currency || available === undefined) throw new BrokerError("unexpected_response", "Coinbase returned an account without a currency or balance.");
  return {
    portfolioID: stringField(a, "retail_portfolio_id") ?? fallbackPortfolio,
    currency,
    type: stringField(a, "type") ?? "ACCOUNT_TYPE_UNSPECIFIED",
    available,
    hold: amount(a, "hold") ?? "0",
  };
}

const MAX_ACCOUNT_PAGES = 20;

async function allAccounts(ctx: AdapterContext): Promise<RawAccount[]> {
  const fallback = ctx.credentials.provider === "coinbase" ? ctx.credentials.portfolioID ?? "default" : "default";
  const out: RawAccount[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < MAX_ACCOUNT_PAGES; page++) {
    const body = await getJSON(ctx, "/accounts", { limit: 250, cursor });
    for (const raw of asArray(body.accounts, "accounts")) {
      const account = readAccount(raw, fallback);
      if (account) out.push(account);
    }
    cursor = body.has_next === true ? stringField(body, "cursor") : undefined;
    if (!cursor) return out;
  }
  throw new BrokerError("unexpected_response", `Coinbase listed more than ${MAX_ACCOUNT_PAGES * 250} accounts; stopped rather than loop.`);
}

interface KeyPermissions {
  canView: boolean;
  canTrade: boolean;
  canTransfer: boolean;
  portfolioID?: string;
  portfolioType?: string;
}

async function keyPermissions(ctx: AdapterContext): Promise<KeyPermissions> {
  const body = await getJSON(ctx, "/key_permissions");
  return {
    canView: body.can_view === true,
    canTrade: body.can_trade === true,
    canTransfer: body.can_transfer === true,
    portfolioID: stringField(body, "portfolio_uuid"),
    portfolioType: stringField(body, "portfolio_type"),
  };
}

const SANDBOX_ACCOUNT: BrokerAccount = Object.freeze({
  providerAccountID: "sandbox",
  label: "Coinbase sandbox (static test responses)",
  environment: "sandbox",
  status: "active",
  currency: "USD",
  tradingEnabled: true,
  tradingBlockers: [],
}) as BrokerAccount;

// MARK: - Orders

function orderConfiguration(request: BrokerOrderRequest): Record<string, Record<string, string | boolean>> {
  const size: Record<string, string> = request.quantity !== undefined ? { base_size: request.quantity } : { quote_size: request.notional! };
  switch (request.type) {
    case "market":
      return { [request.timeInForce === "fok" ? "market_market_fok" : "market_market_ioc"]: size };
    case "limit": {
      const limit = { ...size, limit_price: request.limitPrice! };
      if (request.timeInForce === "gtc") return { limit_limit_gtc: { ...limit, post_only: false } };
      if (request.timeInForce === "fok") return { limit_limit_fok: limit };
      return { sor_limit_ioc: limit };
    }
    case "stop_limit":
      return {
        stop_limit_stop_limit_gtc: {
          base_size: request.quantity!,
          limit_price: request.limitPrice!,
          stop_price: request.stopPrice!,
          // A buy stop triggers as the price rises through the stop; a sell stop as it falls.
          stop_direction: request.side === "buy" ? "STOP_DIRECTION_STOP_UP" : "STOP_DIRECTION_STOP_DOWN",
        },
      };
    default:
      throw new BrokerError("unsupported", `Coinbase doesn't accept ${request.type} orders here.`);
  }
}

const PRODUCT_ID = /^[A-Z0-9]+-[A-Z0-9]+$/;

function validateCoinbase(ctx: AdapterContext, request: BrokerOrderRequest): void {
  validateOrderRequest(capabilities(ctx.environment), request);
  if (!PRODUCT_ID.test(request.symbol)) throw new BrokerError("invalid_request", `Coinbase products look like "BTC-USD"; got "${request.symbol}".`);
  if (request.type === "stop_limit" && request.notional !== undefined) {
    throw new BrokerError("unsupported", "Coinbase stop-limit orders take a base size, not a cash amount.");
  }
}

/** Coinbase new_order_failure_reason → our code. */
export function codeForFailure(reason: string | undefined): BrokerErrorCode | "duplicate_client_order_id" {
  switch (reason) {
    case "INSUFFICIENT_FUND":
    case "INSUFFICIENT_FUNDS":
    case "INVALID_LEDGER_BALANCE":
      return "insufficient_funds";
    case "UNSUPPORTED_ORDER_CONFIGURATION":
    case "INELIGIBLE_PAIR":
    case "UNTRADABLE_PRODUCT":
    case "FOK_DISABLED":
    case "FRACTIONAL_ORDERS_NOT_ALLOWED_FOR_PRODUCT":
    case "QUOTE_ORDERS_NOT_ALLOWED_FOR_PRODUCT":
      return "unsupported";
    case "PRODUCT_TRADING_HALTED":
      return "market_closed";
    case "ORDER_ENTRY_DISABLED":
    case "TRADING_DISABLED":
    case "GEOFENCING_RESTRICTION":
      return "forbidden";
    case "DUPLICATE_CLIENT_ORDER_ID":
      return "duplicate_client_order_id";
    default:
      return "invalid_request";
  }
}

function createOutcome(response: HttpResponse, request: BrokerOrderRequest, ctx: AdapterContext): SubmitResult {
  if (!ok(response)) {
    const error = errorFromResponse(PROVIDER, response, secrets(ctx));
    return { outcome: "rejected", code: error.code, message: error.message };
  }
  const body = response.body;
  if (!body || typeof body !== "object") return { outcome: "unknown", reason: "Coinbase answered 200 but the body couldn't be read" };
  const record = body as Record<string, unknown>;
  if (record.success === true) {
    const success = record.success_response && typeof record.success_response === "object" ? record.success_response as Record<string, unknown> : {};
    const orderID = stringField(success, "order_id") ?? stringField(record, "order_id");
    if (!orderID) return { outcome: "unknown", reason: "Coinbase reported success without an order id" };
    return {
      outcome: "accepted",
      order: {
        providerOrderID: orderID,
        clientOrderID: stringField(success, "client_order_id") ?? request.clientOrderID,
        symbol: request.symbol,
        side: request.side,
        type: request.type,
        timeInForce: request.timeInForce,
        status: "pending_new",
        providerStatus: "SUBMITTED",
        quantity: request.quantity,
        notional: request.notional,
        filledQuantity: "0",
        limitPrice: request.limitPrice,
        stopPrice: request.stopPrice,
      },
    };
  }
  if (record.success === false) {
    const failure = record.error_response && typeof record.error_response === "object" ? record.error_response as Record<string, unknown> : {};
    const reason = stringField(failure, "new_order_failure_reason") ?? stringField(failure, "preview_failure_reason") ?? stringField(failure, "error");
    const message = stringField(failure, "message") ?? stringField(failure, "error_details") ?? "Coinbase refused the order.";
    return { outcome: "rejected", code: codeForFailure(reason), message: `Coinbase: ${message}${reason ? ` [${reason}]` : ""}` };
  }
  return { outcome: "unknown", reason: "Coinbase answered without saying whether the order was created" };
}

// MARK: - The adapter

export const coinbaseAdapter: BrokerAdapter = {
  provider: "coinbase",
  capabilities,

  async validate(ctx) {
    if (ctx.environment === "sandbox") {
      await getJSON(ctx, "/accounts", { limit: 1 });
      return { accounts: [SANDBOX_ACCOUNT], permissions: ["read", "trade"] };
    }
    hostFor(ctx);
    const permissions = await keyPermissions(ctx);
    if (permissions.canTransfer) {
      throw new BrokerError(
        "forbidden",
        "This Coinbase key can move money out (it has transfer permission). Create a key with View — and Trade only if you want to place orders. Stock Tracker never needs transfer access.",
      );
    }
    if (!permissions.canView) throw new BrokerError("forbidden", "This Coinbase key can't view accounts. Give it the View permission.");
    return { accounts: await coinbaseAdapter.accounts(ctx), permissions: permissions.canTrade ? ["read", "trade"] : ["read"] };
  },

  async accounts(ctx) {
    if (ctx.environment === "sandbox") return [SANDBOX_ACCOUNT];
    hostFor(ctx);
    const [permissions, body] = await Promise.all([keyPermissions(ctx), getJSON(ctx, "/portfolios")]);
    const wanted = permissions.portfolioID ?? (ctx.credentials.provider === "coinbase" ? ctx.credentials.portfolioID : undefined);
    const portfolios = asArray(body.portfolios, "portfolios")
      .map((p) => asRecord(p, "portfolio"))
      .filter((p) => p.deleted !== true && (!wanted || p.uuid === wanted));
    return portfolios.map((p): BrokerAccount => {
      const uuid = stringField(p, "uuid");
      if (!uuid) throw new BrokerError("unexpected_response", "Coinbase returned a portfolio without an id.");
      const blockers: string[] = [];
      if (!permissions.canTrade) blockers.push("This API key is view-only, so it can't place orders.");
      if (p.type === "INTX") blockers.push("International Exchange (INTX) portfolios aren't supported.");
      return {
        providerAccountID: uuid,
        label: `Coinbase – ${stringField(p, "name") ?? "Portfolio"}`,
        environment: ctx.environment,
        status: "active",
        // Coinbase portfolios hold many currencies; per-currency balances come from balances().
        currency: "USD",
        tradingEnabled: blockers.length === 0,
        tradingBlockers: blockers,
      };
    });
  },

  async balances(ctx) {
    return (await allAccounts(ctx)).map((a): BrokerBalance => ({
      providerAccountID: a.portfolioID,
      currency: a.currency,
      total: Decimal.add(a.available, a.hold),
      available: Decimal.normalise(a.available),
      reserved: Decimal.normalise(a.hold),
    }));
  },

  async positions(ctx) {
    // Spot holdings are the crypto wallets with a balance. Coinbase's accounts carry no cost
    // or value as decimal strings, so none is invented here: the platform values positions
    // from its own quotes.
    return (await allAccounts(ctx))
      .filter((a) => a.type === "ACCOUNT_TYPE_CRYPTO")
      .map((a): BrokerPosition => ({
        providerAccountID: a.portfolioID,
        symbol: a.currency,
        assetClass: "crypto",
        quantity: Decimal.add(a.available, a.hold),
        currency: "USD",
      }))
      .filter((p) => positive(p.quantity));
  },

  async fills(ctx, options): Promise<Page<BrokerFill>> {
    const body = await getJSON(ctx, "/orders/historical/fills", {
      limit: Math.min(Math.max(options.limit ?? 100, 1), 1000),
      cursor: options.cursor,
      start_sequence_timestamp: options.since,
      end_sequence_timestamp: options.until,
    });
    const items = asArray(body.fills, "fills").map(normaliseFill);
    const cursor = stringField(body, "cursor");
    return { items, cursor: items.length > 0 ? cursor : undefined };
  },

  async orders(ctx, options): Promise<Page<BrokerOrder>> {
    const statuses = options.status === "open"
      ? ["OPEN", "PENDING", "QUEUED"]
      : options.status === "closed"
      ? ["FILLED", "CANCELLED", "EXPIRED", "FAILED"]
      : undefined;
    const body = await getJSON(ctx, "/orders/historical/batch", {
      limit: Math.min(Math.max(options.limit ?? 100, 1), 1000),
      cursor: options.cursor,
      order_status: statuses,
      start_date: options.since,
    });
    const items = asArray(body.orders, "orders").map(normaliseOrder);
    return { items, cursor: body.has_next === true ? stringField(body, "cursor") : undefined };
  },

  async preview(ctx, request): Promise<OrderPreview> {
    validateCoinbase(ctx, request);
    // A preview creates nothing, so it may be retried like a read.
    const response = await read(
      ctx,
      await buildRequest(ctx, "POST", "/orders/preview", {}, {
        product_id: request.symbol,
        side: request.side === "buy" ? "BUY" : "SELL",
        order_configuration: orderConfiguration(request),
      }),
      PROVIDER,
    );
    if (!ok(response)) throw errorFromResponse(PROVIDER, response, secrets(ctx));
    const body = asRecord(response.body, "preview");
    const strings = (value: unknown) => Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
    return {
      estimatedQuantity: decimalField(body, "base_size"),
      estimatedNotional: decimalField(body, "quote_size"),
      estimatedFee: decimalField(body, "commission_total"),
      feeCurrency: quoteCurrency(request.symbol),
      warnings: strings(body.warning),
      errors: strings(body.errs),
    };
  },

  async submit(ctx, request) {
    assertMoneyMovementAllowed(ctx, "place an order");
    validateCoinbase(ctx, request);
    const outcome = await sendOnce(
      ctx,
      await buildRequest(ctx, "POST", "/orders", {}, {
        client_order_id: request.clientOrderID,
        product_id: request.symbol,
        side: request.side === "buy" ? "BUY" : "SELL",
        order_configuration: orderConfiguration(request),
      }),
    );
    if (outcome.kind === "unknown") return { outcome: "unknown", reason: outcome.reason };
    return createOutcome(outcome.response, request, ctx);
  },

  async cancel(ctx, providerOrderID) {
    assertMoneyMovementAllowed(ctx, "cancel an order");
    // Cancelling twice is harmless, so this is retried like a read.
    const response = await read(ctx, await buildRequest(ctx, "POST", "/orders/batch_cancel", {}, { order_ids: [providerOrderID] }), PROVIDER);
    if (!ok(response)) throw errorFromResponse(PROVIDER, response, secrets(ctx));
    const results = asArray(asRecord(response.body, "cancel").results, "cancel results");
    const result = results.map((r) => asRecord(r, "cancel result")).find((r) => r.order_id === providerOrderID) ?? asRecord(results[0], "cancel result");
    if (result.success === true) return { accepted: true };
    const reason = stringField(result, "failure_reason");
    if (reason === "DUPLICATE_CANCEL_REQUEST") return { accepted: true, message: "A cancel was already requested." };
    if (reason === "ORDER_IS_FULLY_FILLED") return { accepted: false, message: "Coinbase says the order has already filled." };
    return { accepted: false, message: `Coinbase didn't cancel the order${reason ? ` [${reason}]` : ""}.` };
  },

  async replace(ctx, providerOrderID, changes) {
    assertMoneyMovementAllowed(ctx, "modify an order");
    for (const [field, value] of Object.entries(changes)) {
      if (value !== undefined && !Decimal.isPositiveDecimal(value)) throw new BrokerError("invalid_request", `${field} must be a positive decimal string.`);
    }
    if (changes.quantity === undefined && changes.limitPrice === undefined && changes.stopPrice === undefined) {
      throw new BrokerError("invalid_request", "Nothing to change.");
    }
    // Coinbase's edit needs both price and size, so the current order fills in what isn't changing.
    const current = await coinbaseAdapter.getOrder(ctx, providerOrderID);
    const price = changes.limitPrice ?? current.limitPrice;
    const size = changes.quantity ?? current.quantity;
    if (!price || !size) throw new BrokerError("unsupported", "Coinbase only edits orders with a limit price and a base size.");
    const body: Record<string, string> = { order_id: providerOrderID, price, size };
    if (changes.stopPrice !== undefined) body.stop_price = changes.stopPrice;
    const outcome = await sendOnce(ctx, await buildRequest(ctx, "POST", "/orders/edit", {}, body));
    if (outcome.kind === "unknown") return { outcome: "unknown", reason: outcome.reason };
    const response = outcome.response;
    if (!ok(response)) {
      const error = errorFromResponse(PROVIDER, response, secrets(ctx));
      return { outcome: "rejected", code: error.code, message: error.message };
    }
    const record = response.body && typeof response.body === "object" ? response.body as Record<string, unknown> : {};
    if (record.success === true) {
      return {
        outcome: "accepted",
        order: { ...current, limitPrice: price, quantity: size, stopPrice: changes.stopPrice ?? current.stopPrice, status: "pending_replace", providerStatus: "EDIT_QUEUED" },
      };
    }
    if (record.success === false) {
      const errors = Array.isArray(record.errors) ? record.errors.map((e) => asRecord(e, "edit error")) : [];
      const reasons = errors.flatMap((e) => [stringField(e, "edit_failure_reason"), stringField(e, "preview_failure_reason")]).filter((r): r is string => !!r);
      const code: BrokerErrorCode = reasons.includes("ORDER_NOT_FOUND") ? "not_found" : reasons.includes("ONLY_LIMIT_ORDER_EDITS_SUPPORTED") ? "unsupported" : "invalid_request";
      return { outcome: "rejected", code, message: `Coinbase didn't change the order${reasons.length ? ` [${reasons.join(", ")}]` : ""}.` };
    }
    return { outcome: "unknown", reason: "Coinbase answered without saying whether the edit was accepted" };
  },

  async getOrder(ctx, providerOrderID) {
    const body = await getJSON(ctx, `/orders/historical/${encodeURIComponent(providerOrderID)}`);
    return normaliseOrder(body.order);
  },

  /**
   * Coinbase can't filter orders by client_order_id, so this pages back through the most recent
   * CLIENT_ID_SEARCH_PAGES × 100 orders and matches locally. Reconciliation runs right after a
   * submit, when the order (if it exists) is among the newest; `undefined` means "not among the
   * recent orders", which the caller treats as not created only after that window.
   */
  async findOrderByClientID(ctx, clientOrderID) {
    let cursor: string | undefined;
    for (let page = 0; page < CLIENT_ID_SEARCH_PAGES; page++) {
      const result = await coinbaseAdapter.orders(ctx, { status: "all", limit: 100, cursor });
      const match = result.items.find((o) => o.clientOrderID === clientOrderID);
      if (match) return match;
      cursor = result.cursor;
      if (!cursor) return undefined;
    }
    return undefined;
  },
};
