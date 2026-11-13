// Risk for provider orders: the SAME deterministic risk engine the practice path uses
// (../trading/risk.ts, ported from TradingCore and proven against Swift vectors), fed with a
// ledger built from what the provider reports, plus the account-level limits the brief adds
// (restricted symbols, crypto allocation cap, cash reserve, price-deviation guard).
//
// No model is consulted. Same inputs → same verdict. Conservative where the provider's data is
// partial: other orders that are still reserving exposure (risk checked … submitting) are
// subtracted from cash and from sellable quantity and added to today's traded value, so two
// orders that each pass alone can't jointly break a limit.

import type { BrokerPosition, ProviderCapabilities } from "../brokers/types.ts";
import { type BrokerCapabilities } from "../trading/broker.ts";
import { PaperBroker } from "../trading/broker.ts";
import { isOpen } from "../trading/calendar.ts";
import { lookupInstrument } from "../trading/catalog.ts";
import { type Ledger, ledgerDayKey, type Position } from "../trading/ledger.ts";
import { type Bar, type Instrument, instrumentID, makeInstrument, measureStats, type Quote } from "../trading/market.ts";
import type { OrderType, TimeInForce } from "../trading/orders.ts";
import { type AccountPolicy, evaluate, type OrderIntent, type RiskCheck, type RiskPolicy } from "../trading/risk.ts";
import type { RiskEvaluationView } from "./api.ts";
import * as D from "./decimal.ts";
import type { ConnectionState, IntentRecord } from "./execute.ts";

/** Limits the brief asks for that the engine's per-ledger policy doesn't carry. */
export interface AccountLimits {
  /** Symbols (provider form, upper case) that may never be bought or sold here. */
  restrictedSymbols: string[];
  /** Largest share of equity in crypto after a crypto buy, in percent. */
  maxCryptoPct: number;
  /** Cash that must remain after a buy (account currency, decimal string). */
  minCashReserve: string;
  /** A limit/stop price further than this from the last price is refused as a likely typo, percent. */
  maxPriceDeviationPct: number;
}

export const DEFAULT_ACCOUNT_LIMITS: AccountLimits = { restrictedSymbols: [], maxCryptoPct: 30, minCashReserve: "0", maxPriceDeviationPct: 10 };

export interface ProviderPolicy {
  version: number;
  limits: RiskPolicy;
  account: AccountLimits;
}

export interface ProviderQuote {
  last: string;
  bid?: string;
  ask?: string;
  /** When the venue produced the price (ms). */
  observedAt: number;
  source: string;
  delaySeconds: number;
  status: "real_time" | "delayed" | "indicative";
  currency: string;
}

export interface ProviderSnapshot {
  currency: string;
  cash: string;
  equity: string;
  /** Equity at the previous close, when the provider reports it (Alpaca `last_equity`). */
  lastEquity?: string;
  peakEquity?: string;
  positions: BrokerPosition[];
  /** Fills since the start of today's trading day (for today's traded value and cooldowns). */
  fillsToday: { symbol: string; side: "buy" | "sell"; quantity: string; price: string; executedAt: number }[];
  /** Realised P/L today in account currency, if the provider reports it; otherwise "0" (and the check says so). */
  realizedToday?: string;
}

export interface ReservingOrder {
  intentID: string;
  symbol: string;
  assetClass: "us_equity" | "crypto";
  side: "buy" | "sell";
  quantity?: string;
  notional?: string;
  /** The worst price it could trade at (limit, or the quote it was checked against). */
  price: string;
}

export interface ProviderRiskInput {
  intent: IntentRecord;
  connection: ConnectionState;
  capabilities: ProviderCapabilities;
  policy: ProviderPolicy;
  accountPolicy: AccountPolicy;
  snapshot: ProviderSnapshot;
  reserving: ReservingOrder[];
  knownClientOrderIDs: ReadonlySet<string>;
  quote: ProviderQuote | undefined;
  dailyBars?: Bar[];
  now: number;
}

/** "BTC/USD" (Alpaca) or "BTC-USD" (Coinbase) → the engine's crypto instrument; "AAPL" → US equity/ETF. */
export function engineInstrument(symbol: string, assetClass: "us_equity" | "crypto"): Instrument {
  if (assetClass === "crypto") {
    const base = symbol.split(/[/-]/)[0];
    return lookupInstrument(base, "crypto") ?? makeInstrument(base, "crypto", "crypto", base, "USD");
  }
  return lookupInstrument(symbol, "us") ?? makeInstrument(symbol, "equity", "us", symbol, "USD");
}

const ENGINE_ORDER_TYPE: Record<IntentRecord["input"]["type"], OrderType> = { market: "market", limit: "limit", stop: "stop", stop_limit: "stopLimit" };

function engineCapabilities(provider: ProviderCapabilities): BrokerCapabilities {
  const orderTypes = new Set<OrderType>();
  const tifs = new Set<TimeInForce>();
  for (const cap of provider.orders) {
    for (const t of cap.orderTypes) orderTypes.add(ENGINE_ORDER_TYPE[t]);
    for (const list of Object.values(cap.timeInForce)) for (const tif of list ?? []) tifs.add(tif);
  }
  return {
    adapterID: provider.provider,
    displayName: provider.provider === "alpaca" ? `Alpaca ${provider.environment}` : `Coinbase ${provider.environment}`,
    environment: provider.environment,
    countries: ["*"],
    venues: provider.orders.some((o) => o.assetClass === "us_equity") ? ["us", "crypto"] : ["crypto"],
    assetClasses: provider.orders.flatMap((o) => (o.assetClass === "crypto" ? ["crypto" as const] : ["equity" as const, "etf" as const])),
    orderTypes: [...orderTypes],
    timeInForce: [...tifs],
    supportsFractional: provider.orders.some((o) => o.fractional),
    supportsNotionalOrders: provider.orders.some((o) => o.notional),
    permissions: ["read", "trade"],
    isExecutionEnabled: provider.executionAvailable,
    disabledReason: provider.executionAvailable ? undefined : provider.notes[0],
    notes: provider.notes,
  } as BrokerCapabilities;
}

const n = (text: string | undefined): number => (text === undefined ? 0 : D.toNumber(text));
const sameSymbol = (a: string, b: string) => a.replace(/[/-]/g, "").toUpperCase() === b.replace(/[/-]/g, "").toUpperCase();

/** The price the value checks use: the worst this order could trade at right now. */
export function worstPrice(intent: IntentRecord, quote: ProviderQuote): string {
  const i = intent.input;
  const market = i.side === "buy" ? (quote.ask ?? quote.last) : (quote.bid ?? quote.last);
  if (i.type === "limit" || i.type === "stop_limit") {
    // A buy limit can't trade above its limit; a sell limit not below.
    return i.side === "buy" ? (D.compare(i.limitPrice!, market) < 0 ? i.limitPrice! : market) : (D.compare(i.limitPrice!, market) > 0 ? i.limitPrice! : market);
  }
  if (i.type === "stop") return i.side === "buy" ? (D.compare(i.stopPrice!, market) > 0 ? i.stopPrice! : market) : (D.compare(i.stopPrice!, market) < 0 ? i.stopPrice! : market);
  return market;
}

/** Order quantity, from its size or its notional at the worst price (truncated to 8 places). */
export function orderQuantity(intent: IntentRecord, price: string): string {
  if (intent.input.quantity) return intent.input.quantity;
  return D.div(intent.input.notional!, price, 8);
}

export function evaluateProviderRisk(input: ProviderRiskInput): RiskEvaluationView {
  const { intent, snapshot, quote, policy, now } = input;
  const instrument = engineInstrument(intent.input.symbol, intent.input.assetClass);
  const id = instrumentID(instrument);
  const extra: RiskCheck[] = [];
  const add = (cid: string, status: RiskCheck["status"], detail: string) => extra.push({ id: cid as RiskCheck["id"], status, detail });

  // Reserving orders: take their cash and sellable quantity out first.
  let reservedCash = "0";
  let reservedNotional = "0";
  const reservedSell = new Map<string, string>();
  for (const r of input.reserving) {
    if (r.intentID === intent.id) continue;
    const value = r.notional ?? D.mul(r.quantity!, r.price);
    reservedNotional = D.add(reservedNotional, value);
    if (r.side === "buy") reservedCash = D.add(reservedCash, value);
    else reservedSell.set(r.symbol, D.add(reservedSell.get(r.symbol) ?? "0", r.quantity ?? D.div(r.notional!, r.price, 8)));
  }

  const cash = Math.max(n(snapshot.cash) - n(reservedCash), 0);
  const positions: Position[] = snapshot.positions
    .filter((p) => D.compare(p.quantity, "0") > 0)
    .map((p) => {
      const inst = engineInstrument(p.symbol, p.assetClass);
      const held = n(p.quantity) - n(reservedSell.get(p.symbol));
      const last = sameSymbol(p.symbol, intent.input.symbol) && quote ? n(quote.last) : (p.marketValue && n(p.quantity) > 0 ? n(p.marketValue) / n(p.quantity) : n(p.averageEntryPrice));
      return { instrument: inst, quantity: Math.max(held, 0), costBasis: n(p.costBasis ?? D.mul(p.quantity, p.averageEntryPrice ?? "0")), openedAt: 0, lastPrice: last, lastPriceTime: quote?.observedAt };
    })
    .filter((p) => p.quantity > 0);

  const equity = n(snapshot.equity);
  const tradedToday = snapshot.fillsToday.reduce((sum, f) => sum + n(f.quantity) * n(f.price), 0) + n(reservedNotional);
  const lastFillAt: Record<string, number> = {};
  const lastBuyAt: Record<string, number> = {};
  for (const f of snapshot.fillsToday) {
    const fid = instrumentID(engineInstrument(f.symbol, f.symbol.includes("/") || f.symbol.includes("-") ? "crypto" : "us_equity"));
    lastFillAt[fid] = Math.max(lastFillAt[fid] ?? 0, f.executedAt);
    if (f.side === "buy") lastBuyAt[fid] = Math.max(lastBuyAt[fid] ?? 0, f.executedAt);
  }
  const ledger: Ledger = {
    id: input.connection.id,
    name: input.capabilities.provider,
    kind: "manualPaper",
    mode: intent.environment === "live" ? "live" : "paper",
    currency: snapshot.currency,
    startingCash: equity,
    cash,
    positions,
    realizedPnL: 0,
    feesPaid: 0,
    createdAt: 0,
    equityHistory: [],
    peakEquity: Math.max(equity, n(snapshot.peakEquity)),
    dayKey: ledgerDayKey(now, snapshot.currency),
    dayStartEquity: snapshot.lastEquity ? n(snapshot.lastEquity) : equity,
    realizedToday: n(snapshot.realizedToday),
    notionalToday: tradedToday,
    lastFillAt,
    lastBuyAt,
    lastExitAt: {},
  };

  const price = quote ? worstPrice(intent, quote) : "0";
  const quantity = quote ? orderQuantity(intent, price) : intent.input.quantity ?? "0";
  const engineIntent: OrderIntent = {
    clientOrderID: intent.clientOrderID,
    instrument,
    side: intent.input.side,
    type: ENGINE_ORDER_TYPE[intent.input.type],
    timeInForce: intent.input.timeInForce,
    quantity: n(quantity),
    price: n(price),
    limitPrice: intent.input.limitPrice ? n(intent.input.limitPrice) : undefined,
    stopPrice: intent.input.stopPrice ? n(intent.input.stopPrice) : undefined,
    estimatedFee: 0,
    source: intent.input.origin.kind === "agent" ? { kind: "agent", agentID: intent.input.origin.agentID } : { kind: "manual" },
    mode: ledger.mode,
  };
  const engineQuote: Quote | undefined = quote
    ? { instrumentID: id, last: n(quote.last), bid: quote.bid ? n(quote.bid) : undefined, ask: quote.ask ? n(quote.ask) : undefined, time: quote.observedAt, provenance: { kind: "market", source: quote.source, delaySeconds: quote.delaySeconds } }
    : undefined;
  const exposure = positions.filter((p) => instrumentID(p.instrument) === id).reduce((s, p) => s + p.quantity * p.lastPrice, 0) +
    input.reserving.filter((r) => r.intentID !== intent.id && r.side === "buy" && sameSymbol(r.symbol, intent.input.symbol)).reduce((s, r) => s + n(r.notional ?? D.mul(r.quantity!, r.price)), 0);

  const report = evaluate(engineIntent, {
    now,
    policy: policy.limits,
    accountPolicy: input.accountPolicy,
    ledger,
    openOrders: [],
    otherOpenOrders: [],
    knownClientOrderIDs: input.knownClientOrderIDs,
    accountExposure: exposure,
    accountEquity: equity,
    accountNotionalToday: tradedToday,
    quote: engineQuote,
    rules: PaperBroker.rules(instrument),
    capabilities: engineCapabilities(input.capabilities),
    grantedPermissions: input.connection.permissions,
    marketOpen: isOpen(instrument.venue, now),
    stats: input.dailyBars ? measureStats(input.dailyBars) : undefined,
  });

  // The brief's account-level limits.
  const a = policy.account;
  const symbolUpper = intent.input.symbol.toUpperCase();
  if (a.restrictedSymbols.some((s) => sameSymbol(s, symbolUpper))) add("restrictedAsset", "failed", `${symbolUpper} is on your restricted list.`);
  else add("restrictedAsset", "passed", `${symbolUpper} isn't restricted.`);

  const notional = quote ? D.mul(quantity, price) : "0";
  if (intent.input.side === "buy") {
    if (intent.input.assetClass === "crypto" && equity > 0) {
      const cryptoNow = positions.filter((p) => p.instrument.assetClass === "crypto").reduce((s, p) => s + p.quantity * p.lastPrice, 0);
      const after = (cryptoNow + n(notional)) / equity * 100;
      if (after > a.maxCryptoPct) add("cryptoAllocation", "failed", `Crypto would be ${after.toFixed(1)}% of the account; your limit is ${a.maxCryptoPct}%.`);
      else add("cryptoAllocation", "passed", `Crypto would be ${after.toFixed(1)}% of the account (limit ${a.maxCryptoPct}%).`);
    } else add("cryptoAllocation", "notApplicable", "Not a crypto purchase.");
    const left = cash - n(notional);
    if (left < n(a.minCashReserve)) add("cashReserve", "failed", `This would leave ${left.toFixed(2)} ${snapshot.currency} cash; you keep at least ${a.minCashReserve}.`);
    else add("cashReserve", "passed", `Leaves ${left.toFixed(2)} ${snapshot.currency} cash.`);
  } else {
    add("cryptoAllocation", "notApplicable", "Sells only reduce exposure.");
    add("cashReserve", "notApplicable", "Sells add cash.");
  }
  const typed = intent.input.limitPrice ?? intent.input.stopPrice;
  if (typed && quote && n(quote.last) > 0) {
    const deviation = Math.abs(n(typed) - n(quote.last)) / n(quote.last) * 100;
    if (deviation > a.maxPriceDeviationPct) add("priceDeviation", "failed", `The price you set is ${deviation.toFixed(1)}% from the last price (limit ${a.maxPriceDeviationPct}%). Check for a typo.`);
    else add("priceDeviation", "passed", `The price you set is ${deviation.toFixed(1)}% from the last price.`);
  } else add("priceDeviation", "notApplicable", "Market order.");
  if (input.snapshot.realizedToday === undefined) add("dataCompleteness", "warning", "The provider doesn't report today's realised profit or loss, so the daily-loss check uses unrealised changes only.");

  // Stricter than the practice path: on the provider path the kill switch stops manual
  // orders too (the brief: "immediately prevents new order submissions").
  const engineChecks = report.checks.map((c) =>
    c.id === "killSwitch" && input.accountPolicy.killSwitchEngaged
      ? { ...c, status: "failed" as const, detail: "The kill switch is on. No order is sent to a provider until you turn it off." }
      : c
  );
  const checks = [...engineChecks, ...extra];
  const failed = checks.filter((c) => c.status === "failed").map((c) => c.id as string);
  return {
    policyVersion: policy.version,
    result: failed.length === 0 ? "pass" : "fail",
    reasonCodes: failed,
    checks: checks.map((c) => ({ id: c.id as string, status: c.status, detail: c.detail })),
    price: quote
      ? { value: price, currency: quote.currency, source: quote.source, observedAt: new Date(quote.observedAt).toISOString(), status: quote.status }
      : { value: "0", currency: snapshot.currency, source: "none", observedAt: new Date(0).toISOString(), status: "indicative" },
    evaluatedAt: new Date(now).toISOString(),
  };
}
