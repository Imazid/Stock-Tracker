// Execution venues and the built-in simulator. A port of
// TradingCore/Sources/TradingCore/Broker.swift.
//
// The paper broker is the only venue that executes anything in this build. The live
// venues below are descriptions: none of them can place an order, and nothing in this
// module (or anywhere else on the server) calls a broker's order endpoint.

import { nextClose } from "./calendar.ts";
import {
  type AssetClass, hasTwoSidedMarket, type Instrument, type InstrumentRules, type Quote, quoteAge, type Venue,
} from "./market.ts";
import {
  isOpenStatus, needsLimitPrice, needsStopPrice, type Order, type OrderSide, type OrderStatus, type OrderType,
  remainingQuantity, type TimeInForce,
} from "./orders.ts";
import * as Rounding from "./rounding.ts";

export type BrokerPermission = "read" | "trade";
export type BrokerEnvironment = "paper" | "sandbox" | "live";

/**
 * What an execution venue can do. Every adapter publishes one of these, and the risk
 * engine checks orders against it — nothing is assumed from the venue's name.
 */
export interface BrokerCapabilities {
  adapterID: string;
  displayName: string;
  environment: BrokerEnvironment;
  /** ISO country codes whose residents can use it; ["*"] means no restriction. */
  countries: string[];
  venues: Venue[];
  assetClasses: AssetClass[];
  orderTypes: OrderType[];
  timeInForce: TimeInForce[];
  supportsFractional: boolean;
  supportsNotionalOrders: boolean;
  /** The most this adapter could ever be granted. A connection may hold less. */
  permissions: BrokerPermission[];
  /** False for integrations that are described but not switched on. */
  isExecutionEnabled: boolean;
  disabledReason?: string;
  notes: string[];
}

export function supportsInstrument(caps: BrokerCapabilities, instrument: Instrument): boolean {
  return caps.venues.includes(instrument.venue) && caps.assetClasses.includes(instrument.assetClass);
}

/** How the built-in simulator prices and charges for a fill. */
export interface PaperBrokerConfig {
  /** Flat commission per equity order. */
  equityFeePerOrder: number;
  /** Commission on equity orders, in basis points of the trade value. */
  equityFeeBps: number;
  /** Taker fee on crypto orders, in basis points. */
  cryptoFeeBps: number;
  /** Half-spread assumed when the feed has no usable bid and ask, in basis points. */
  modelledHalfSpreadBpsEquity: number;
  modelledHalfSpreadBpsCrypto: number;
  /** The most one match will fill, as a share of the day's reported volume. Ignored when the feed reports no volume. */
  maxParticipation: number;
  /** A quote older than this is not matched against (the order waits for a fresh one). */
  maxMatchQuoteAgeSeconds: number;
}

export function defaultPaperConfig(): PaperBrokerConfig {
  return {
    equityFeePerOrder: 0, equityFeeBps: 0, cryptoFeeBps: 25, modelledHalfSpreadBpsEquity: 2, modelledHalfSpreadBpsCrypto: 5,
    maxParticipation: 0.01, maxMatchQuoteAgeSeconds: 1_200,
  };
}

export interface Match {
  fillQuantity: number;
  fillPrice: number;
  fee: number;
  newStatus: OrderStatus;
  stopTriggered: boolean;
  note?: string;
}

const paperCapabilities: BrokerCapabilities = {
  adapterID: "paper",
  displayName: "Paper trading",
  environment: "paper",
  countries: ["*"],
  venues: ["us", "asx", "crypto"],
  assetClasses: ["equity", "etf", "crypto"],
  orderTypes: ["market", "limit", "stop", "stopLimit"],
  timeInForce: ["day", "gtc", "ioc", "fok"],
  supportsFractional: true,
  supportsNotionalOrders: true,
  permissions: ["read", "trade"],
  isExecutionEnabled: true,
  notes: [
    "Simulated fills against live quotes. No order leaves this app.",
    "No leverage, margin, short selling or withdrawals.",
  ],
};

function rules(instrument: Instrument): InstrumentRules {
  if (instrument.assetClass === "crypto") {
    return { quantityIncrement: 0.000_000_01, minQuantity: 0.000_000_01, minNotional: 1, priceIncrement: 0.01, fractionable: true };
  }
  if (instrument.venue === "asx") {
    // ASX trades whole shares.
    return { quantityIncrement: 1, minQuantity: 1, minNotional: 1, priceIncrement: 0.005, fractionable: false };
  }
  return { quantityIncrement: 0.000_001, minQuantity: 0.000_001, minNotional: 1, priceIncrement: 0.01, fractionable: true };
}

function fee(instrument: Instrument, notional: number, isFirstFillOfOrder: boolean, config: PaperBrokerConfig): number {
  if (instrument.assetClass === "crypto") return Rounding.money(notional * config.cryptoFeeBps / 10_000);
  const flat = isFirstFillOfOrder ? config.equityFeePerOrder : 0;
  return Rounding.money(flat + notional * config.equityFeeBps / 10_000);
}

/**
 * The price a market order would trade at right now: the ask to buy and the bid to sell,
 * or the last price moved by a modelled half-spread when the feed is one-sided.
 */
function executionPrice(side: OrderSide, quote: Quote, instrument: Instrument, config: PaperBrokerConfig): { price: number; modelled: boolean } {
  const r = rules(instrument);
  if (hasTwoSidedMarket(quote)) return { price: side === "buy" ? quote.ask! : quote.bid!, modelled: false };
  const half = (instrument.assetClass === "crypto" ? config.modelledHalfSpreadBpsCrypto : config.modelledHalfSpreadBpsEquity) / 10_000;
  const raw = side === "buy" ? quote.last * (1 + half) : quote.last * (1 - half);
  return { price: Math.max(Rounding.nearest(raw, r.priceIncrement), r.priceIncrement), modelled: true };
}

/**
 * Tries to trade an open order against one quote. Pure: it returns what should happen and
 * changes nothing, so the engine applies the result in one place.
 * Returns undefined when the order should simply keep waiting.
 */
function match(order: Order, quote: Quote, marketOpen: boolean, now: number, config: PaperBrokerConfig): Match | undefined {
  const remaining = remainingQuantity(order);
  if (!isOpenStatus(order.status) || !(remaining > 0)) return undefined;
  const immediate = order.timeInForce === "ioc" || order.timeInForce === "fok";
  const cancel = (note: string): Match => ({ fillQuantity: 0, fillPrice: 0, fee: 0, newStatus: "canceled", stopTriggered: false, note });

  if (!marketOpen) return immediate ? cancel("The market is closed, so an immediate order can't trade.") : undefined;
  if (!(quote.last > 0 && quoteAge(quote, now) <= config.maxMatchQuoteAgeSeconds + quote.provenance.delaySeconds)) {
    return immediate ? cancel("No fresh quote to trade against.") : undefined;
  }

  const { price: marketPrice, modelled } = executionPrice(order.side, quote, order.instrument, config);

  // Stops wait for the last trade to reach the stop price, then behave like a market or limit order.
  let stopTriggered = false;
  if (needsStopPrice(order.type) && order.stopTriggeredAt === undefined) {
    if (order.stopPrice === undefined) return cancel("The stop price is missing.");
    const reached = order.side === "buy" ? quote.last >= order.stopPrice : quote.last <= order.stopPrice;
    if (!reached) return immediate ? cancel("The stop price wasn't reached.") : undefined;
    stopTriggered = true;
  }

  if (needsLimitPrice(order.type)) {
    if (order.limitPrice === undefined) return cancel("The limit price is missing.");
    const marketable = order.side === "buy" ? marketPrice <= order.limitPrice : marketPrice >= order.limitPrice;
    if (!marketable) {
      if (immediate) return cancel("The limit price wasn't available.");
      return stopTriggered
        ? { fillQuantity: 0, fillPrice: 0, fee: 0, newStatus: order.status, stopTriggered: true, note: "Stop reached; waiting for the limit price." }
        : undefined;
    }
  }

  // How much can trade against this quote.
  const r = rules(order.instrument);
  let available = remaining;
  if (quote.dayVolume !== undefined && quote.dayVolume > 0 && config.maxParticipation > 0) {
    const cap = Math.max(Rounding.floor(quote.dayVolume * config.maxParticipation, r.quantityIncrement), r.quantityIncrement);
    available = Math.min(available, cap);
  }
  if (order.timeInForce === "fok" && available + 1e-12 < remaining) return cancel("The full quantity wasn't available.");

  const filledBefore = order.filledQuantity;
  const notional = Rounding.money(available * marketPrice);
  const charged = fee(order.instrument, notional, filledBefore === 0, config);
  const complete = remaining - available <= r.quantityIncrement * 1e-3;
  const status: OrderStatus = complete ? "filled" : order.timeInForce === "ioc" ? "canceled" : "partiallyFilled";
  const notes: string[] = [];
  if (modelled) notes.push("No two-sided quote: filled at the last price plus a modelled spread.");
  if (!complete) notes.push(order.timeInForce === "ioc" ? "Part filled; the rest was cancelled." : "Part filled; the rest is still working.");
  const result: Match = { fillQuantity: available, fillPrice: marketPrice, fee: charged, newStatus: status, stopTriggered };
  if (notes.length > 0) result.note = notes.join(" ");
  return result;
}

/**
 * When a day order placed at `time` stops working: the end of the current session, or of
 * the next one if the market is shut. Crypto day orders last 24 hours.
 */
function expiry(timeInForce: TimeInForce, venue: Venue, placedAt: number): number | undefined {
  switch (timeInForce) {
    case "day": return venue === "crypto" ? placedAt + 86_400_000 : nextClose(venue, placedAt);
    case "gtc": return placedAt + 90 * 86_400_000;
    default: return undefined;
  }
}

/** The built-in simulator. It fills against real quotes with a spread, fees and partial fills. */
export const PaperBroker = { adapterID: "paper", capabilities: paperCapabilities, rules, fee, executionPrice, match, expiry };

// MARK: - Live venues (described, not switched on)

/**
 * Real-money venues the product knows how to describe. None of them can execute in this
 * build: there is no trading-enabled connection, no server-held trading credential and no
 * licence in place. They exist so the product can show an honest "not available yet" with
 * the reason, and so switching one on later is a deliberate, reviewable change.
 */
export const LiveVenues: { alpaca: BrokerCapabilities; snapTrade: BrokerCapabilities; cryptoExchange: BrokerCapabilities; all: BrokerCapabilities[] } = (() => {
  const alpaca: BrokerCapabilities = {
    adapterID: "alpaca",
    displayName: "Alpaca",
    environment: "live",
    countries: [],
    venues: ["us", "crypto"],
    assetClasses: ["equity", "etf", "crypto"],
    orderTypes: ["market", "limit", "stop", "stopLimit"],
    timeInForce: ["day", "gtc", "ioc", "fok"],
    supportsFractional: true,
    supportsNotionalOrders: true,
    permissions: ["read", "trade"],
    isExecutionEnabled: false,
    disabledReason: "Trading through Alpaca isn't set up. The app reads prices with its Alpaca key and never sends an order with it.",
    notes: [
      "Needs a trading account the person authorises (OAuth with the separate trading scope), with credentials held on the server.",
      "US stocks, ETFs and crypto only — Alpaca does not offer ASX securities.",
      "Fractional and notional orders are day orders; crypto takes market, limit and stop-limit with GTC or IOC.",
    ],
  };
  const snapTrade: BrokerCapabilities = {
    adapterID: "snaptrade",
    displayName: "Connected broker (SnapTrade)",
    environment: "live",
    countries: [],
    venues: ["us", "asx", "crypto"],
    assetClasses: ["equity", "etf", "crypto"],
    orderTypes: ["market", "limit"],
    timeInForce: ["day", "gtc"],
    supportsFractional: false,
    supportsNotionalOrders: false,
    permissions: ["read"],
    isExecutionEnabled: false,
    disabledReason: "Your broker connection is read-only. It shows holdings and can't place orders.",
    notes: [
      "A read-only connection is never treated as permission to trade.",
      "Trading needs a connection made with trade access, and only some brokers offer it (CommSec and Interactive Brokers are read-only through SnapTrade).",
    ],
  };
  const cryptoExchange: BrokerCapabilities = {
    adapterID: "crypto-exchange",
    displayName: "Crypto exchange",
    environment: "live",
    countries: [],
    venues: ["crypto"],
    assetClasses: ["crypto"],
    orderTypes: ["market", "limit"],
    timeInForce: ["gtc", "ioc"],
    supportsFractional: true,
    supportsNotionalOrders: false,
    permissions: ["read", "trade"],
    isExecutionEnabled: false,
    disabledReason: "No crypto exchange is connected for trading.",
    notes: ["Spot only. No margin, futures or withdrawals."],
  };
  return { alpaca, snapTrade, cryptoExchange, all: [alpaca, snapTrade, cryptoExchange] };
})();
