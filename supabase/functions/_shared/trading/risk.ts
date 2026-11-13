// The risk engine: the one gate every order passes, whoever or whatever asked for it.
// A port of TradingCore/Sources/TradingCore/Risk.swift — the same 24 checks, in the same
// order, with the same pass / warn / fail / not-applicable results and the same wording.
//
// It is plain, deterministic code: no model output is consulted and nothing can skip it.
// Every check runs and reports, so a person sees the whole picture rather than only the
// first thing that failed. Sells only ever reduce risk here (there is no short selling),
// so limits that exist to stop risk growing don't block them.

import type { AgentMode, AgentStatus } from "./agent.ts";
import { agentModeDisplayName, modeIsLive, modePlacesOrders } from "./agent.ts";
import { type BrokerCapabilities, type BrokerPermission, supportsInstrument } from "./broker.ts";
import { drawdownPct, equity as ledgerEquity, type Ledger, marketValue, position as ledgerPosition } from "./ledger.ts";
import {
  type Instrument, instrumentID, type InstrumentRules, type InstrumentStats, type Quote, quoteAge, quoteSpreadBps, venueDisplayName,
} from "./market.ts";
import {
  type ExecutionMode, needsLimitPrice, needsStopPrice, type Order, type OrderSide, type OrderSource, type OrderType,
  orderTypeDisplayName, remainingQuantity, type TimeInForce, timeInForceDisplayName,
} from "./orders.ts";
import { liquidityFloor } from "./currencies.ts";
import * as Rounding from "./rounding.ts";
import { cFixed, compactText, durationText, NumberText, percentText } from "./text.ts";

// MARK: - Policies

/** Limits for one ledger (one agent's budget, or one paper portfolio). */
export interface RiskPolicy {
  /** Largest single order, in the ledger's currency. */
  maxOrderNotional: number;
  /** Largest share of the ledger's equity one instrument may reach, in percent. */
  maxPositionPct: number;
  /** Most that may be traded in one day. */
  maxDailyNotional: number;
  /** New buys stop once today's realised loss reaches this percent of the day's starting equity. */
  maxDailyLossPct: number;
  /** New buys stop once equity is this percent below its peak. */
  maxDrawdownPct: number;
  maxOpenPositions: number;
  /** Widest bid/ask spread an order may trade through, in basis points. */
  maxSpreadBps: number;
  /** Oldest quote an order may be checked against, in seconds. */
  maxQuoteAgeSeconds: number;
  /** Smallest average daily traded value an instrument must have. */
  minAverageDollarVolume: number;
  /** Highest daily volatility (percent) an instrument may have for new buys. */
  maxDailyVolatilityPct: number;
  /** Seconds to wait after a fill before buying the same instrument again. */
  cooldownSeconds: number;
  /** A waiting order is cancelled if the price has moved this far (percent) from where it was checked. */
  maxPriceGapPct: number;
  /** Orders placed while the market is shut wait for the open. If false they are refused. */
  allowQueueOutsideHours: boolean;
}

export function makePolicy(fields: Partial<RiskPolicy> & Pick<RiskPolicy, "maxOrderNotional" | "maxPositionPct" | "maxDailyNotional">): RiskPolicy {
  return {
    maxDailyLossPct: 3, maxDrawdownPct: 15, maxOpenPositions: 10, maxSpreadBps: 50, maxQuoteAgeSeconds: 900,
    minAverageDollarVolume: 1_000_000, maxDailyVolatilityPct: 8, cooldownSeconds: 300, maxPriceGapPct: 5,
    allowQueueOutsideHours: true,
    ...fields,
  };
}

/**
 * Sensible starting limits for a budget. Crypto gets wider spread, volatility and gap
 * allowances because that market really is wider and jumpier. `currency` sets the
 * liquidity floor to about US$1 million in local money.
 */
export function standardPolicy(budget: number, maxPositionPct = 10, crypto = false, currency = "USD"): RiskPolicy {
  const position = Math.min(Math.max(maxPositionPct, 1), 100);
  return {
    maxOrderNotional: Rounding.money(Math.max(budget * position / 100, 1)),
    maxPositionPct: position,
    maxDailyNotional: Rounding.money(Math.max(budget * 0.5, 1)),
    maxDailyLossPct: 3,
    maxDrawdownPct: 15,
    maxOpenPositions: 10,
    maxSpreadBps: crypto ? 100 : 50,
    maxQuoteAgeSeconds: crypto ? 300 : 900,
    minAverageDollarVolume: liquidityFloor(currency),
    maxDailyVolatilityPct: crypto ? 15 : 8,
    cooldownSeconds: 300,
    maxPriceGapPct: crypto ? 8 : 5,
    allowQueueOutsideHours: true,
  };
}

/** Problems that would make a policy meaningless or unsafe. */
export function policyIssues(p: RiskPolicy): string[] {
  const out: string[] = [];
  const finite = Number.isFinite;
  if (!(finite(p.maxOrderNotional) && p.maxOrderNotional > 0)) out.push("The largest order must be above zero.");
  if (!(finite(p.maxPositionPct) && p.maxPositionPct > 0 && p.maxPositionPct <= 100)) out.push("The position limit must be between 0 and 100%.");
  if (!(finite(p.maxDailyNotional) && p.maxDailyNotional > 0)) out.push("The daily trading limit must be above zero.");
  if (!(finite(p.maxDailyLossPct) && p.maxDailyLossPct > 0 && p.maxDailyLossPct <= 100)) out.push("The daily loss limit must be between 0 and 100%.");
  if (!(finite(p.maxDrawdownPct) && p.maxDrawdownPct > 0 && p.maxDrawdownPct <= 100)) out.push("The drawdown limit must be between 0 and 100%.");
  if (!(Number.isInteger(p.maxOpenPositions) && p.maxOpenPositions >= 1 && p.maxOpenPositions <= 100)) out.push("Open positions must be between 1 and 100.");
  if (!(finite(p.maxSpreadBps) && p.maxSpreadBps > 0)) out.push("The spread limit must be above zero.");
  if (!(finite(p.maxQuoteAgeSeconds) && p.maxQuoteAgeSeconds >= 5)) out.push("Quotes can't be required to be newer than 5 seconds.");
  if (!(finite(p.cooldownSeconds) && p.cooldownSeconds >= 0)) out.push("The cooldown can't be negative.");
  if (!(finite(p.maxPriceGapPct) && p.maxPriceGapPct > 0 && p.maxPriceGapPct <= 50)) out.push("The price-gap limit must be between 0 and 50%.");
  return out;
}

/**
 * What real-money trading is switched on. Everything is off in this build, and nothing in
 * the app or the API can turn it on.
 */
export interface LiveAuthorization {
  manualOrdersEnabled: boolean;
  approvalAgentsEnabled: boolean;
  autonomousAgentsEnabled: boolean;
}

export const liveDisabled = (): LiveAuthorization => ({ manualOrdersEnabled: false, approvalAgentsEnabled: false, autonomousAgentsEnabled: false });

/** Limits across everything a person runs, whichever agent or portfolio an order comes from. */
export interface AccountPolicy {
  killSwitchEngaged: boolean;
  killSwitchAt?: number;
  /** Largest share of all equity (every ledger of the same mode) one instrument may reach, in percent. */
  maxSymbolExposurePct: number;
  /** Most that may be traded in one day across every ledger. */
  maxTotalDailyNotional: number;
  live: LiveAuthorization;
  /** Lets test fixtures stand in for market data. Never set outside tests. */
  allowFixtureData: boolean;
}

export function defaultAccountPolicy(): AccountPolicy {
  return { killSwitchEngaged: false, maxSymbolExposurePct: 35, maxTotalDailyNotional: 250_000, live: liveDisabled(), allowFixtureData: false };
}

// MARK: - Report

export type RiskCheckID =
  | "killSwitch" | "authorization" | "agentStatus" | "brokerPermission" | "universe" | "currency"
  | "marketData" | "quoteFreshness" | "marketHours" | "exchangeRules"
  | "orderValue" | "buyingPower" | "holdings" | "positionLimit" | "concentration" | "openPositions"
  | "dailyNotional" | "dailyLoss" | "drawdown" | "spread" | "liquidity" | "volatility" | "duplicate" | "cooldown";

export const RISK_CHECK_IDS: RiskCheckID[] = ["killSwitch", "authorization", "agentStatus", "brokerPermission", "universe", "currency",
  "marketData", "quoteFreshness", "marketHours", "exchangeRules", "orderValue", "buyingPower", "holdings", "positionLimit",
  "concentration", "openPositions", "dailyNotional", "dailyLoss", "drawdown", "spread", "liquidity", "volatility", "duplicate", "cooldown"];

const TITLES: Record<RiskCheckID, string> = {
  killSwitch: "Kill switch", authorization: "Trading mode", agentStatus: "Agent status", brokerPermission: "Broker permission",
  universe: "Approved assets", currency: "Currency", marketData: "Market data", quoteFreshness: "Quote freshness",
  marketHours: "Market hours", exchangeRules: "Exchange rules", orderValue: "Order size", buyingPower: "Buying power",
  holdings: "Holdings", positionLimit: "Position limit", concentration: "Concentration", openPositions: "Open positions",
  dailyNotional: "Daily trading limit", dailyLoss: "Daily loss limit", drawdown: "Drawdown limit", spread: "Spread",
  liquidity: "Liquidity", volatility: "Volatility", duplicate: "Duplicate orders", cooldown: "Cooldown",
};

export const riskCheckTitle = (id: RiskCheckID): string => TITLES[id];

export type RiskCheckStatus = "passed" | "warning" | "failed" | "notApplicable";

export interface RiskCheck {
  id: RiskCheckID;
  status: RiskCheckStatus;
  detail: string;
}

export interface RiskReport {
  checks: RiskCheck[];
  evaluatedAt: number;
}

export const reportFailures = (report: RiskReport): RiskCheck[] => report.checks.filter((c) => c.status === "failed");
export const reportWarnings = (report: RiskReport): RiskCheck[] => report.checks.filter((c) => c.status === "warning");
/** An order goes ahead only when no check failed. */
export const isApproved = (report: RiskReport): boolean => reportFailures(report).length === 0;

export function reportSummary(report: RiskReport): string {
  const failures = reportFailures(report);
  if (failures.length > 0) {
    return failures.length === 1 ? failures[0].detail : `${failures[0].detail} (+${failures.length - 1} more)`;
  }
  const passed = report.checks.filter((c) => c.status === "passed").length;
  const warnings = reportWarnings(report);
  return warnings.length === 0 ? `All ${passed} checks passed.` : `${passed} checks passed, ${warnings.length} with a warning.`;
}

export const reportCheck = (report: RiskReport, id: RiskCheckID): RiskCheck | undefined => report.checks.find((c) => c.id === id);

// MARK: - Inputs

/** An order after sizing, ready to be judged. */
export interface OrderIntent {
  clientOrderID: string;
  instrument: Instrument;
  side: OrderSide;
  type: OrderType;
  timeInForce: TimeInForce;
  quantity: number;
  /** The price the value checks use: the worst price this order could trade at right now. */
  price: number;
  limitPrice?: number;
  stopPrice?: number;
  estimatedFee: number;
  source: OrderSource;
  mode: ExecutionMode;
}

export const intentNotional = (intent: OrderIntent): number => Rounding.money(intent.quantity * intent.price);

/** The agent behind an order, as far as the risk engine cares. */
export interface AgentRiskView {
  id: string;
  name: string;
  mode: AgentMode;
  status: AgentStatus;
  /** Instrument ids the agent may trade. */
  universe: string[];
  followsLedgerPositions: boolean;
}

/**
 * Everything the risk engine reads. The engine fetches nothing itself, so the same inputs
 * always give the same verdict.
 */
export interface RiskContext {
  now: number;
  policy: RiskPolicy;
  accountPolicy: AccountPolicy;
  agent?: AgentRiskView;
  ledger: Ledger;
  /** Open orders in this ledger. */
  openOrders: Order[];
  /** Open orders from other ledgers in the same instrument (to catch agents trading against each other). */
  otherOpenOrders: Order[];
  /** Every client order id seen so far. */
  knownClientOrderIDs: ReadonlySet<string>;
  /** Market value held in this instrument across every ledger of the same mode, this ledger included. */
  accountExposure: number;
  /** Equity across every ledger of the same mode. */
  accountEquity: number;
  /** Traded today across every ledger of the same mode. */
  accountNotionalToday: number;
  quote?: Quote;
  rules: InstrumentRules;
  capabilities: BrokerCapabilities;
  /** What the connection being used was actually granted. */
  grantedPermissions: BrokerPermission[];
  marketOpen: boolean;
  stats?: InstrumentStats;
}

export function quantityText(x: number, rules: InstrumentRules): string {
  const text = Rounding.string(x, rules.quantityIncrement);
  if (!text.includes(".")) return text;
  let trimmed = text;
  while (trimmed.endsWith("0")) trimmed = trimmed.slice(0, -1);
  if (trimmed.endsWith(".")) trimmed = trimmed.slice(0, -1);
  return trimmed;
}

// MARK: - Engine

export function evaluate(intent: OrderIntent, c: RiskContext): RiskReport {
  const checks: RiskCheck[] = [];
  const add = (id: RiskCheckID, status: RiskCheckStatus, detail: string) => checks.push({ id, status, detail });

  const isBuy = intent.side === "buy";
  // Sizing limits bound what an agent may do. A person trading their own paper portfolio
  // by hand is bound by the hard rules only: funds, holdings, exchange rules, real and
  // fresh prices, and permission.
  const byAgent = intent.source.kind === "agent";
  const manualNote = "An agent's limits don't apply to orders you place yourself.";
  const id = instrumentID(intent.instrument);
  const symbol = intent.instrument.symbol;
  const currency = c.ledger.currency;
  const money = (x: number) => NumberText.money(x, currency);
  const venueName = venueDisplayName(intent.instrument.venue);

  // 1. Kill switch — stops everything an agent does. A person can still trade by hand.
  if (c.accountPolicy.killSwitchEngaged && byAgent) {
    add("killSwitch", "failed", "The kill switch is on. No agent can place orders until you turn it off.");
  } else if (c.accountPolicy.killSwitchEngaged) {
    add("killSwitch", "warning", "The kill switch is on. Agents are stopped; this manual order is still allowed.");
  } else {
    add("killSwitch", "passed", "The kill switch is off.");
  }

  // 2. Trading mode and authorisation.
  if (intent.mode === "paper") {
    if (c.agent && !modePlacesOrders(c.agent.mode)) {
      add("authorization", "failed", `${agentModeDisplayName(c.agent.mode)} mode never places orders.`);
    } else if (c.agent && modeIsLive(c.agent.mode)) {
      add("authorization", "failed", "A live-mode agent can't send paper orders.");
    } else if (c.ledger.mode !== "paper") {
      add("authorization", "failed", "A paper order can't be booked to a live account.");
    } else {
      add("authorization", "passed", "Paper order. No real money is involved.");
    }
  } else {
    const live = c.accountPolicy.live;
    if (c.ledger.mode !== "live") {
      add("authorization", "failed", "A live order can't be booked to a paper portfolio.");
    } else if (c.agent) {
      if (c.agent.mode === "approvalRequired" && live.approvalAgentsEnabled) {
        add("authorization", "passed", "Live order approved by you.");
      } else if (c.agent.mode === "autonomousLive" && live.autonomousAgentsEnabled) {
        add("authorization", "passed", "Autonomous live trading is authorised for this agent.");
      } else {
        add("authorization", "failed", `Live trading isn't enabled for agents in ${agentModeDisplayName(c.agent.mode)} mode.`);
      }
    } else if (live.manualOrdersEnabled) {
      add("authorization", "passed", "Live order placed by you.");
    } else {
      add("authorization", "failed", "Live trading isn't enabled.");
    }
  }

  // 3. Agent status.
  if (c.agent) {
    if (c.agent.status === "active") add("agentStatus", "passed", `${c.agent.name} is running.`);
    else add("agentStatus", "failed", `${c.agent.name} is ${c.agent.status} and can't place orders.`);
  } else {
    add("agentStatus", "notApplicable", "Placed by you, not an agent.");
  }

  // 4. Broker permission and capability.
  const caps = c.capabilities;
  if (!caps.isExecutionEnabled) {
    add("brokerPermission", "failed", caps.disabledReason ?? `${caps.displayName} can't place orders.`);
  } else if (!caps.permissions.includes("trade") || !c.grantedPermissions.includes("trade")) {
    add("brokerPermission", "failed", "This connection is read-only. It was never given permission to trade.");
  } else if (!supportsInstrument(caps, intent.instrument)) {
    add("brokerPermission", "failed", `${caps.displayName} doesn't trade ${symbol}.`);
  } else if (!caps.orderTypes.includes(intent.type)) {
    add("brokerPermission", "failed", `${caps.displayName} doesn't accept ${orderTypeDisplayName(intent.type).toLowerCase()} orders.`);
  } else if (!caps.timeInForce.includes(intent.timeInForce)) {
    add("brokerPermission", "failed", `${caps.displayName} doesn't accept "${timeInForceDisplayName(intent.timeInForce)}" orders.`);
  } else {
    add("brokerPermission", "passed", `${caps.displayName} can trade this order.`);
  }

  // 5. Approved universe.
  if (c.agent) {
    if (c.agent.followsLedgerPositions) {
      if (isBuy) add("universe", "failed", "This agent only manages existing positions and can't open new ones.");
      else add("universe", "passed", `${symbol} is a position this agent manages.`);
    } else if (c.agent.universe.includes(id)) {
      add("universe", "passed", `${symbol} is on this agent's approved list.`);
    } else {
      add("universe", "failed", `${symbol} isn't on this agent's approved list.`);
    }
  } else {
    add("universe", "notApplicable", "Manual orders aren't limited to a list.");
  }

  // 6. Currency.
  if (intent.instrument.currency === currency) {
    add("currency", "passed", `${symbol} trades in ${currency}, the same as this portfolio.`);
  } else {
    add("currency", "failed", `${symbol} trades in ${intent.instrument.currency} but this portfolio holds ${currency}.`);
  }

  // 7. Market data must be real.
  let usableQuote: Quote | undefined;
  if (c.quote && c.quote.last > 0 && Number.isFinite(c.quote.last)) {
    const quote = c.quote;
    switch (quote.provenance.kind) {
      case "market":
        usableQuote = quote;
        add("marketData", "passed", `Live quote from ${quote.provenance.source}.`);
        break;
      case "fixture":
        if (c.accountPolicy.allowFixtureData) {
          usableQuote = quote;
          add("marketData", "passed", "Test fixture quote.");
        } else {
          add("marketData", "failed", "Test data can't be traded on.");
        }
        break;
      default:
        add("marketData", "failed", "This price is not real market data and can't be traded on.");
    }
  } else {
    add("marketData", "failed", `There is no live quote for ${symbol}.`);
  }

  // 8. Market hours.
  let queued = false;
  if (intent.instrument.venue === "crypto") {
    add("marketHours", "passed", "Crypto trades around the clock.");
  } else if (c.marketOpen) {
    add("marketHours", "passed", `The ${venueName} is open.`);
  } else if (intent.timeInForce === "ioc" || intent.timeInForce === "fok") {
    add("marketHours", "failed", `The ${venueName} is closed, so an immediate order can't trade.`);
  } else if (c.policy.allowQueueOutsideHours) {
    queued = true;
    add("marketHours", "warning", `The ${venueName} is closed. The order will wait for the open.`);
  } else {
    add("marketHours", "failed", `The ${venueName} is closed.`);
  }

  // 9. Quote freshness.
  if (usableQuote) {
    const age = quoteAge(usableQuote, c.now);
    const allowed = c.policy.maxQuoteAgeSeconds + usableQuote.provenance.delaySeconds;
    if (queued) {
      add("quoteFreshness", "notApplicable", "Market closed: the price is checked again when the order can trade.");
    } else if (age < -120) {
      add("quoteFreshness", "failed", "The quote is dated in the future, so it can't be trusted.");
    } else if (age <= allowed) {
      add("quoteFreshness", "passed", `Quote is ${durationText(Math.max(age, 0))} old (limit ${durationText(allowed)}).`);
    } else {
      add("quoteFreshness", "failed", `The quote is ${durationText(age)} old; the limit is ${durationText(allowed)}.`);
    }
  } else {
    add("quoteFreshness", "failed", "No quote to check.");
  }

  // 10. Exchange rules: precision, minimums, price ticks.
  const r = c.rules;
  const notional = intentNotional(intent);
  const ruleProblems: string[] = [];
  if (!(Number.isFinite(intent.quantity) && intent.quantity > 0)) ruleProblems.push("The quantity must be above zero.");
  if (!(Number.isFinite(intent.price) && intent.price > 0)) ruleProblems.push("The price must be above zero.");
  if (ruleProblems.length === 0) {
    if (!r.fractionable && intent.quantity !== Rounding.roundAway(intent.quantity)) {
      ruleProblems.push(`${symbol} trades in whole units only.`);
    } else if (!r.fractionable && r.quantityIncrement > 1 && !Rounding.isMultiple(intent.quantity, r.quantityIncrement)) {
      ruleProblems.push(`${symbol} trades in lots of ${Math.trunc(r.quantityIncrement)} shares.`);
    } else if (!Rounding.isMultiple(intent.quantity, r.quantityIncrement)) {
      ruleProblems.push(`The quantity has more decimal places than ${symbol} allows (step ${Rounding.string(r.quantityIncrement, r.quantityIncrement)}).`);
    }
    if (intent.quantity + 1e-12 < r.minQuantity) {
      ruleProblems.push(`The quantity is below the minimum of ${Rounding.string(r.minQuantity, r.quantityIncrement)}.`);
    }
    if (notional + 1e-9 < r.minNotional) ruleProblems.push(`The order is worth ${money(notional)}; the minimum is ${money(r.minNotional)}.`);
    if (needsLimitPrice(intent.type)) {
      if (intent.limitPrice !== undefined && intent.limitPrice > 0) {
        if (!Rounding.isMultiple(intent.limitPrice, r.priceIncrement)) {
          ruleProblems.push(`The limit price must be a multiple of ${Rounding.string(r.priceIncrement, r.priceIncrement)}.`);
        }
      } else {
        ruleProblems.push("A limit price is required.");
      }
    }
    if (needsStopPrice(intent.type)) {
      if (intent.stopPrice !== undefined && intent.stopPrice > 0) {
        if (!Rounding.isMultiple(intent.stopPrice, r.priceIncrement)) {
          ruleProblems.push(`The stop price must be a multiple of ${Rounding.string(r.priceIncrement, r.priceIncrement)}.`);
        }
      } else {
        ruleProblems.push("A stop price is required.");
      }
    }
  }
  if (ruleProblems.length === 0) add("exchangeRules", "passed", "Quantity and price fit the exchange's rules.");
  else add("exchangeRules", "failed", ruleProblems.join(" "));

  const equity = ledgerEquity(c.ledger);
  const held = ledgerPosition(c.ledger, id);
  let reservedCash = 0;
  for (const order of c.openOrders) {
    if (order.side === "buy") reservedCash += remainingQuantity(order) * (order.limitPrice ?? order.referencePrice);
  }
  let reservedUnits = 0;
  for (const order of c.openOrders) {
    if (order.side === "sell" && instrumentID(order.instrument) === id) reservedUnits += remainingQuantity(order);
  }

  // 11. Order size.
  if (!isBuy) {
    add("orderValue", "notApplicable", "Sells reduce risk and aren't capped by order size.");
  } else if (!byAgent) {
    add("orderValue", "notApplicable", manualNote);
  } else if (notional <= c.policy.maxOrderNotional + 0.005) {
    add("orderValue", "passed", `${money(notional)} is within the ${money(c.policy.maxOrderNotional)} order limit.`);
  } else {
    add("orderValue", "failed", `${money(notional)} is over the ${money(c.policy.maxOrderNotional)} order limit.`);
  }

  // 12. Buying power / 13. holdings. No borrowing and no short selling.
  if (isBuy) {
    const available = c.ledger.cash - reservedCash;
    const needed = notional + intent.estimatedFee;
    if (needed <= available + 0.005) {
      add("buyingPower", "passed", `Needs ${money(needed)}; ${money(Math.max(available, 0))} is available.`);
    } else {
      add("buyingPower", "failed", `Needs ${money(needed)} but only ${money(Math.max(available, 0))} is available.`);
    }
    add("holdings", "notApplicable", "Not a sell.");
  } else {
    add("buyingPower", "notApplicable", "Not a buy.");
    const available = (held?.quantity ?? 0) - reservedUnits;
    if (intent.quantity <= available + r.quantityIncrement * 1e-3) {
      add("holdings", "passed", `Selling ${quantityText(intent.quantity, r)} of ${quantityText(Math.max(available, 0), r)} held.`);
    } else if (available <= 0) {
      add("holdings", "failed", `There is no ${symbol} available to sell. Short selling is not allowed.`);
    } else {
      add("holdings", "failed", `Only ${quantityText(available, r)} ${symbol} is available to sell. Short selling is not allowed.`);
    }
  }

  // 14. Position limit.
  if (isBuy && !byAgent) {
    add("positionLimit", "notApplicable", manualNote);
  } else if (isBuy) {
    const after = (held ? marketValue(held) : 0) + notional;
    const pct = equity > 0 ? after / equity * 100 : 100;
    if (pct <= c.policy.maxPositionPct + 0.01) {
      add("positionLimit", "passed", `${symbol} would be ${percentText(pct)} of this portfolio (limit ${percentText(c.policy.maxPositionPct)}).`);
    } else {
      add("positionLimit", "failed", `${symbol} would be ${percentText(pct)} of this portfolio; the limit is ${percentText(c.policy.maxPositionPct)}.`);
    }
  } else {
    add("positionLimit", "notApplicable", "Sells reduce the position.");
  }

  // 15. Concentration across every portfolio and agent.
  if (isBuy) {
    const after = c.accountExposure + notional;
    const pct = c.accountEquity > 0 ? after / c.accountEquity * 100 : 100;
    if (pct <= c.accountPolicy.maxSymbolExposurePct + 0.01) {
      add("concentration", "passed", `Across all portfolios ${symbol} would be ${percentText(pct)} (limit ${percentText(c.accountPolicy.maxSymbolExposurePct)}).`);
    } else {
      add("concentration", byAgent ? "failed" : "warning",
        `Across all portfolios ${symbol} would be ${percentText(pct)}; the limit is ${percentText(c.accountPolicy.maxSymbolExposurePct)}.`);
    }
  } else {
    add("concentration", "notApplicable", "Sells reduce concentration.");
  }

  // 16. Open positions.
  if (isBuy && !byAgent) {
    add("openPositions", "notApplicable", manualNote);
  } else if (isBuy && !held) {
    const count = c.ledger.positions.length;
    if (count < c.policy.maxOpenPositions) {
      add("openPositions", "passed", `${count} of ${c.policy.maxOpenPositions} positions are open.`);
    } else {
      add("openPositions", "failed", `${count} positions are already open; the limit is ${c.policy.maxOpenPositions}.`);
    }
  } else {
    add("openPositions", "notApplicable", isBuy ? "Adds to an existing position." : "Sells don't open positions.");
  }

  // 17. Daily trading limits.
  if (isBuy && !byAgent) {
    add("dailyNotional", "notApplicable", manualNote);
  } else if (isBuy) {
    const ledgerAfter = c.ledger.notionalToday + notional;
    const accountAfter = c.accountNotionalToday + notional;
    if (ledgerAfter > c.policy.maxDailyNotional + 0.005) {
      add("dailyNotional", "failed", `This would bring today's trading to ${money(ledgerAfter)}; the daily limit is ${money(c.policy.maxDailyNotional)}.`);
    } else if (accountAfter > c.accountPolicy.maxTotalDailyNotional + 0.005) {
      add("dailyNotional", "failed",
        `This would bring today's trading across all portfolios to ${money(accountAfter)}; the limit is ${money(c.accountPolicy.maxTotalDailyNotional)}.`);
    } else {
      add("dailyNotional", "passed", `Today's trading would be ${money(ledgerAfter)} of ${money(c.policy.maxDailyNotional)}.`);
    }
  } else {
    add("dailyNotional", "notApplicable", "Sells aren't held back by the daily limit.");
  }

  // 18. Daily loss.
  if (isBuy && !byAgent) {
    add("dailyLoss", "notApplicable", manualNote);
  } else if (isBuy) {
    const lossPct = c.ledger.dayStartEquity > 0 ? Rounding.swiftMax(0, -c.ledger.realizedToday) / c.ledger.dayStartEquity * 100 : 0;
    if (lossPct < c.policy.maxDailyLossPct) {
      add("dailyLoss", "passed", `Today's realised loss is ${percentText(lossPct)} (limit ${percentText(c.policy.maxDailyLossPct)}).`);
    } else {
      add("dailyLoss", "failed", `Today's realised loss is ${percentText(lossPct)}, at the ${percentText(c.policy.maxDailyLossPct)} daily limit. No new buys today.`);
    }
  } else {
    add("dailyLoss", "notApplicable", "Sells are always allowed.");
  }

  // 19. Drawdown.
  if (isBuy && !byAgent) {
    add("drawdown", "notApplicable", manualNote);
  } else if (isBuy) {
    const drawdown = drawdownPct(c.ledger);
    if (drawdown < c.policy.maxDrawdownPct) {
      add("drawdown", "passed", `The portfolio is ${percentText(drawdown)} below its peak (limit ${percentText(c.policy.maxDrawdownPct)}).`);
    } else {
      add("drawdown", "failed", `The portfolio is ${percentText(drawdown)} below its peak, at the ${percentText(c.policy.maxDrawdownPct)} limit. No new buys.`);
    }
  } else {
    add("drawdown", "notApplicable", "Sells are always allowed.");
  }

  // 20. Spread.
  if (usableQuote) {
    const spread = quoteSpreadBps(usableQuote);
    if (queued) {
      add("spread", "notApplicable", "Market closed: there is no live spread to check.");
    } else if (spread !== undefined) {
      if (spread <= c.policy.maxSpreadBps) {
        add("spread", "passed", `The spread is ${cFixed(spread, 0)} bps (limit ${cFixed(c.policy.maxSpreadBps, 0)}).`);
      } else {
        add("spread", isBuy ? "failed" : "warning", `The spread is ${cFixed(spread, 0)} bps, wider than the ${cFixed(c.policy.maxSpreadBps, 0)} bps limit.`);
      }
    } else {
      add("spread", "warning", "The feed has no bid and ask, so the spread can't be measured. A modelled spread is used.");
    }
  } else {
    add("spread", "notApplicable", "No quote.");
  }

  // 21. Liquidity / 22. volatility, from real daily bars.
  if (c.stats) {
    const stats = c.stats;
    if (stats.averageDollarVolume >= c.policy.minAverageDollarVolume) {
      add("liquidity", "passed", `About ${NumberText.compactMoney(stats.averageDollarVolume, intent.instrument.currency)} trades a day.`);
    } else {
      add("liquidity", isBuy && byAgent ? "failed" : "warning",
        `Only about ${NumberText.compactMoney(stats.averageDollarVolume, intent.instrument.currency)} trades a day; the minimum is ${NumberText.compactMoney(c.policy.minAverageDollarVolume, intent.instrument.currency)}.`);
    }
    if (!isBuy) {
      add("volatility", "notApplicable", "Sells are always allowed.");
    } else if (stats.dailyVolatilityPct <= c.policy.maxDailyVolatilityPct) {
      add("volatility", "passed", `Daily volatility is ${cFixed(stats.dailyVolatilityPct, 1)}% (limit ${cFixed(c.policy.maxDailyVolatilityPct, 1)}%).`);
    } else {
      add("volatility", byAgent ? "failed" : "warning",
        `Daily volatility is ${cFixed(stats.dailyVolatilityPct, 1)}%, above the ${cFixed(c.policy.maxDailyVolatilityPct, 1)}% limit.`);
    }
  } else {
    const status: RiskCheckStatus = byAgent && isBuy ? "failed" : "warning";
    add("liquidity", status, `Liquidity couldn't be measured for ${symbol}.`);
    add("volatility", status, `Volatility couldn't be measured for ${symbol}.`);
  }

  // 23. Duplicates and agents trading against each other.
  const other = byAgent
    ? c.otherOpenOrders.find((o) => instrumentID(o.instrument) === id && o.side !== intent.side && o.source.kind === "agent")
    : undefined;
  if (c.knownClientOrderIDs.has(intent.clientOrderID)) {
    add("duplicate", "failed", "This order was already submitted.");
  } else if (byAgent && c.openOrders.some((o) => instrumentID(o.instrument) === id && o.side === intent.side && o.source.agentID === intent.source.agentID)) {
    add("duplicate", "failed", `This agent already has an open ${intent.side} order for ${symbol}.`);
  } else if (other) {
    add("duplicate", "failed", `Another agent has an open ${other.side} order for ${symbol}. Two agents can't trade against each other.`);
  } else {
    add("duplicate", "passed", "No duplicate or conflicting order.");
  }

  // 24. Cooldown.
  const lastFill = c.ledger.lastFillAt[id];
  if (isBuy && byAgent && c.policy.cooldownSeconds > 0 && lastFill !== undefined) {
    const since = (c.now - lastFill) / 1_000;
    if (since >= c.policy.cooldownSeconds) {
      add("cooldown", "passed", `Last traded ${durationText(since)} ago.`);
    } else {
      add("cooldown", "failed", `${symbol} traded ${durationText(Math.max(since, 0))} ago. Wait ${durationText(c.policy.cooldownSeconds - since)} more.`);
    }
  } else {
    add("cooldown", "notApplicable", isBuy ? "No recent trade in this asset." : "Sells are always allowed.");
  }

  return { checks, evaluatedAt: c.now };
}

export const RiskEngine = { evaluate, quantityText, percentText, durationText, compactText };
