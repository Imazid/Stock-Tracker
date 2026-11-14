// A strategy is data, not code: a small set of rules a person can read, an AI can draft
// and a validator can check. The same JSON runs in a backtest, on the phone and on the
// server. A port of TradingCore/Sources/TradingCore/StrategySpec.swift.

import { decodeInstrument, type Instrument, instrumentID, type Timeframe, TIMEFRAMES } from "./market.ts";
import { NumberText, capitalized, compareStrings, sortedStrings, swiftTrim, trimNumber } from "./text.ts";

export type PriceField = "open" | "high" | "low" | "close";
const PRICE_FIELDS: PriceField[] = ["open", "high", "low", "close"];

export type OperandKind =
  | "price" | "volume" | "volumeAverage"
  | "sma" | "ema" | "rsi"
  | "macdLine" | "macdSignal" | "macdHistogram"
  | "bollingerUpper" | "bollingerMiddle" | "bollingerLower"
  | "atr" | "highest" | "lowest" | "rateOfChange"
  | "constant";
export const OPERAND_KINDS: OperandKind[] = ["price", "volume", "volumeAverage", "sma", "ema", "rsi", "macdLine", "macdSignal",
  "macdHistogram", "bollingerUpper", "bollingerMiddle", "bollingerLower", "atr", "highest", "lowest", "rateOfChange", "constant"];

/** One side of a comparison: a price, an indicator or a fixed number. */
export interface Operand {
  kind: OperandKind;
  field?: PriceField;
  period?: number;
  fast?: number;
  slow?: number;
  signal?: number;
  deviations?: number;
  value?: number;
  /** Multiplies the result (0.97 = "3% below"). undefined = 1. */
  factor?: number;
}

export const Op = {
  close: { kind: "price", field: "close" } as Operand,
  volume: { kind: "volume" } as Operand,
  price: (field: PriceField): Operand => ({ kind: "price", field }),
  sma: (period: number): Operand => ({ kind: "sma", period }),
  ema: (period: number): Operand => ({ kind: "ema", period }),
  rsi: (period = 14): Operand => ({ kind: "rsi", period }),
  atr: (period = 14): Operand => ({ kind: "atr", period }),
  highest: (period: number): Operand => ({ kind: "highest", period }),
  lowest: (period: number): Operand => ({ kind: "lowest", period }),
  rateOfChange: (period: number): Operand => ({ kind: "rateOfChange", period }),
  volumeAverage: (period: number): Operand => ({ kind: "volumeAverage", period }),
  constant: (value: number): Operand => ({ kind: "constant", value }),
  macdLine: (fast = 12, slow = 26, signal = 9): Operand => ({ kind: "macdLine", fast, slow, signal }),
  macdSignal: (fast = 12, slow = 26, signal = 9): Operand => ({ kind: "macdSignal", fast, slow, signal }),
  macdHistogram: (fast = 12, slow = 26, signal = 9): Operand => ({ kind: "macdHistogram", fast, slow, signal }),
  bollingerUpper: (period = 20, deviations = 2): Operand => ({ kind: "bollingerUpper", period, deviations }),
  bollingerMiddle: (period = 20): Operand => ({ kind: "bollingerMiddle", period, deviations: 2 }),
  bollingerLower: (period = 20, deviations = 2): Operand => ({ kind: "bollingerLower", period, deviations }),
  scaled: (operand: Operand, factor: number): Operand => ({ ...operand, factor: (operand.factor ?? 1) * factor }),
};

/** Bars of history needed before this operand has a value. */
export function operandWarmup(o: Operand): number {
  switch (o.kind) {
    case "price": case "volume": case "constant": return 1;
    case "sma": case "ema": case "bollingerUpper": case "bollingerMiddle": case "bollingerLower": case "volumeAverage":
      return o.period ?? 1;
    case "rsi": case "atr": case "highest": case "lowest": case "rateOfChange": return (o.period ?? 1) + 1;
    case "macdLine": return o.slow ?? 26;
    case "macdSignal": case "macdHistogram": return (o.slow ?? 26) + (o.signal ?? 9) - 1;
  }
}

/** "50-day average", "RSI (14)", "Close" — how the rule reads to a person. */
export function operandLabel(o: Operand, timeframe: Timeframe = "day"): string {
  const unit = timeframe === "day" ? "day" : "hour";
  let base: string;
  switch (o.kind) {
    case "price": base = capitalized(o.field ?? "close"); break;
    case "volume": base = "Volume"; break;
    case "volumeAverage": base = `${o.period ?? 0}-${unit} average volume`; break;
    case "sma": base = `${o.period ?? 0}-${unit} average`; break;
    case "ema": base = `${o.period ?? 0}-${unit} EMA`; break;
    case "rsi": base = `RSI (${o.period ?? 14})`; break;
    case "macdLine": base = "MACD"; break;
    case "macdSignal": base = "MACD signal"; break;
    case "macdHistogram": base = "MACD histogram"; break;
    case "bollingerUpper": base = `upper Bollinger band (${o.period ?? 20})`; break;
    case "bollingerMiddle": base = `middle Bollinger band (${o.period ?? 20})`; break;
    case "bollingerLower": base = `lower Bollinger band (${o.period ?? 20})`; break;
    case "atr": base = `ATR (${o.period ?? 14})`; break;
    case "highest": base = `prior ${o.period ?? 0}-${unit} high`; break;
    case "lowest": base = `prior ${o.period ?? 0}-${unit} low`; break;
    case "rateOfChange": base = `${o.period ?? 0}-${unit} change %`; break;
    case "constant": base = trimNumber(o.value ?? 0); break;
  }
  if (o.factor === undefined || o.factor === 1) return base;
  return `${trimNumber(o.factor)} × ${base}`;
}

export type ConditionOp = "above" | "below" | "crossesAbove" | "crossesBelow" | "all" | "any";
const CONDITION_OPS: ConditionOp[] = ["above", "below", "crossesAbove", "crossesBelow", "all", "any"];

/** A rule: either a comparison of two operands, or a group of rules. */
export interface Condition {
  op: ConditionOp;
  left?: Operand;
  right?: Operand;
  conditions?: Condition[];
}

export const Rule = {
  above: (left: Operand, right: Operand): Condition => ({ op: "above", left, right }),
  below: (left: Operand, right: Operand): Condition => ({ op: "below", left, right }),
  crossesAbove: (left: Operand, right: Operand): Condition => ({ op: "crossesAbove", left, right }),
  crossesBelow: (left: Operand, right: Operand): Condition => ({ op: "crossesBelow", left, right }),
  all: (conditions: Condition[]): Condition => ({ op: "all", conditions }),
  any: (conditions: Condition[]): Condition => ({ op: "any", conditions }),
};

export function isGroup(c: Condition): boolean {
  return c.op === "all" || c.op === "any";
}

export function conditionWarmup(c: Condition): number {
  if (isGroup(c)) {
    const children = (c.conditions ?? []).map(conditionWarmup);
    return children.length === 0 ? 1 : Math.max(...children);
  }
  const base = Math.max(c.left ? operandWarmup(c.left) : 1, c.right ? operandWarmup(c.right) : 1);
  // A cross compares this bar with the one before it.
  return c.op === "crossesAbove" || c.op === "crossesBelow" ? base + 1 : base;
}

export function conditionLabel(c: Condition, timeframe: Timeframe = "day"): string {
  const left = c.left ? operandLabel(c.left, timeframe) : "?";
  const right = c.right ? operandLabel(c.right, timeframe) : "?";
  switch (c.op) {
    case "all":
    case "any":
      return (c.conditions ?? []).map((child) => {
        const label = conditionLabel(child, timeframe);
        return isGroup(child) && child.op !== c.op ? `(${label})` : label;
      }).join(c.op === "all" ? " and " : " or ");
    case "above": return `${left} is above ${right}`;
    case "below": return `${left} is below ${right}`;
    case "crossesAbove": return `${left} crosses above ${right}`;
    case "crossesBelow": return `${left} crosses below ${right}`;
  }
}

export type StrategyKind = "rules" | "dca" | "rebalance" | "research";
const STRATEGY_KINDS: StrategyKind[] = ["rules", "dca", "rebalance", "research"];

/** Exits that protect an open position regardless of the exit rule. */
export interface Protections {
  stopLossPct?: number;
  takeProfitPct?: number;
  trailingStopPct?: number;
  maxHoldingBars?: number;
}

export function protectionsEmpty(p: Protections): boolean {
  return p.stopLossPct === undefined && p.takeProfitPct === undefined && p.trailingStopPct === undefined && p.maxHoldingBars === undefined;
}

export type SizingMode = "fixedNotional" | "percentOfEquity";

export interface Sizing {
  mode: SizingMode;
  /** Dollars for `fixedNotional`; percent (10 = 10%) for `percentOfEquity`. */
  value: number;
}

export interface DCAConfig {
  /** Bought in each instrument on each scheduled buy, in the ledger's currency. */
  amountPerBuy: number;
  /** Bars between buys (5 daily bars = weekly). */
  intervalBars: number;
}

export interface RebalanceConfig {
  /** Instrument id → target share of the ledger's equity, in percent. Any remainder stays in cash. */
  targets: Record<string, number>;
  /** A holding is traded back to target once it drifts this many percentage points away. */
  driftThresholdPct: number;
}

export interface StrategySpec {
  kind: StrategyKind;
  title: string;
  summary: string;
  timeframe: Timeframe;
  universe: Instrument[];
  entry?: Condition;
  exit?: Condition;
  protections: Protections;
  sizing: Sizing;
  dca?: DCAConfig;
  rebalance?: RebalanceConfig;
  monthlyInvestment?: { amount: number; allocation: RebalanceConfig };
  /** Bars to wait after an exit before the same instrument can be bought again. */
  reentryCooldownBars: number;
  /** Watch whatever the ledger holds instead of a fixed list. */
  followsLedgerPositions: boolean;
}

export function makeSpec(fields: Partial<StrategySpec> & Pick<StrategySpec, "kind" | "title" | "summary" | "universe">): StrategySpec {
  return {
    timeframe: "day",
    protections: {},
    sizing: { mode: "percentOfEquity", value: 10 },
    reentryCooldownBars: 1,
    followsLedgerPositions: false,
    ...fields,
  };
}

/** Completed bars needed before any rule can be evaluated. */
export function warmupBars(spec: StrategySpec): number {
  return Math.max(spec.entry ? conditionWarmup(spec.entry) : 1, spec.exit ? conditionWarmup(spec.exit) : 1, 2);
}

/** Bars to request from the data provider: the warm-up plus room for exits and stats. */
export function barsToFetch(spec: StrategySpec): number {
  return Math.max(warmupBars(spec) + 60, 120);
}

/** Plain-English lines describing what the strategy does, for review screens. */
export function ruleLines(spec: StrategySpec): string[] {
  const lines: string[] = [];
  const tf = spec.timeframe;
  switch (spec.kind) {
    case "rules":
      if (spec.entry) lines.push(`Buy when ${conditionLabel(spec.entry, tf)}.`);
      if (spec.exit) lines.push(`Sell when ${conditionLabel(spec.exit, tf)}.`);
      break;
    case "dca":
      if (spec.dca) {
        const every = spec.dca.intervalBars === 1
          ? `every ${tf === "day" ? "trading day" : "hour"}`
          : `every ${spec.dca.intervalBars} ${tf === "day" ? "trading days" : "hours"}`;
        lines.push(`Buy ${trimNumber(spec.dca.amountPerBuy)} of each asset ${every}.`);
      }
      break;
    case "rebalance":
      if (spec.monthlyInvestment && spec.monthlyInvestment.amount > 0) {
        const currency = spec.universe[0]?.currency ?? "USD";
        lines.push(`Invest ${NumberText.money(spec.monthlyInvestment.amount, currency)} of available practice cash each month, split by target weight.`);
      }
      {
        const allocation = spec.monthlyInvestment?.allocation ?? spec.rebalance;
        if (!allocation) break;
        // Swift orders equal weights arbitrarily; here ties go by id so the text is stable.
        const parts = Object.entries(allocation.targets)
          .sort((a, b) => b[1] - a[1] || compareStrings(a[0], b[0]))
          .map(([id, weight]) => `${id.split(":").pop() ?? id} ${trimNumber(weight)}%`);
        lines.push(`Hold ${parts.join(", ")}.`);
        const scope = spec.monthlyInvestment !== undefined ? " of invested value" : "";
        lines.push(`Trade back to target when a holding drifts ${trimNumber(allocation.driftThresholdPct)} percentage points${scope}.`);
      }
      break;
    case "research":
      lines.push("Watch and report. This strategy never places orders.");
      break;
  }
  const p = spec.protections;
  if (p.stopLossPct !== undefined) lines.push(`Stop loss: sell if a position closes ${trimNumber(p.stopLossPct)}% below its cost.`);
  if (p.takeProfitPct !== undefined) lines.push(`Take profit: sell if a position closes ${trimNumber(p.takeProfitPct)}% above its cost.`);
  if (p.trailingStopPct !== undefined) lines.push(`Trailing stop: sell if a position closes ${trimNumber(p.trailingStopPct)}% below its highest close since entry.`);
  if (p.maxHoldingBars !== undefined) lines.push(`Time limit: sell after ${p.maxHoldingBars} ${tf === "day" ? "trading days" : "hours"}.`);
  return lines;
}

// MARK: - Validation

export interface StrategyIssue {
  severity: "error" | "warning";
  message: string;
}

export const maxUniverse = 25;
export const maxPeriod = 400;

function inRange(value: number, low: number, high: number): boolean {
  return Number.isInteger(value) && value >= low && value <= high;
}

export function isValidSymbol(symbol: string): boolean {
  return /^[A-Z0-9.\-]{1,12}$/.test(symbol);
}

function validateOperand(operand: Operand, name: string, issues: StrategyIssue[]): void {
  const error = (m: string): void => { issues.push({ severity: "error", message: `${name}: ${m}` }); };
  const checkPeriod = (value: number | undefined, label: string) => {
    if (value === undefined) return error(`${operand.kind} needs a ${label}.`);
    if (!inRange(value, 1, maxPeriod)) error(`${label} must be between 1 and ${maxPeriod}.`);
  };
  if (operand.factor !== undefined && !(Number.isFinite(operand.factor) && operand.factor > 0 && operand.factor <= 10)) {
    error("a multiplier must be between 0 and 10.");
  }
  switch (operand.kind) {
    case "price": case "volume": break;
    case "constant":
      if (operand.value !== undefined) {
        if (!Number.isFinite(operand.value)) error("a fixed number must be finite.");
      } else {
        error("a fixed number is missing its value.");
      }
      break;
    case "sma": case "ema": case "rsi": case "atr": case "highest": case "lowest": case "rateOfChange": case "volumeAverage":
    case "bollingerMiddle":
      checkPeriod(operand.period, "period");
      break;
    case "bollingerUpper": case "bollingerLower":
      checkPeriod(operand.period, "period");
      if (operand.deviations !== undefined) {
        const d = operand.deviations;
        if (!(Number.isFinite(d) && d > 0 && d <= 5)) error("band width must be between 0 and 5 deviations.");
      } else {
        error("a Bollinger band needs a width.");
      }
      break;
    case "macdLine": case "macdSignal": case "macdHistogram":
      checkPeriod(operand.fast, "fast period");
      checkPeriod(operand.slow, "slow period");
      checkPeriod(operand.signal, "signal period");
      if (operand.fast !== undefined && operand.slow !== undefined && operand.fast >= operand.slow) {
        error("the MACD fast period must be shorter than the slow one.");
      }
      break;
  }
}

function validateCondition(condition: Condition, name: string, depth: number, issues: StrategyIssue[]): void {
  const error = (m: string): void => { issues.push({ severity: "error", message: `${name}: ${m}` }); };
  if (depth > 4) return error("rules are nested too deeply.");
  if (isGroup(condition)) {
    const children = condition.conditions;
    if (!children || children.length === 0) return error("a group has no rules in it.");
    if (children.length > 8) error("a group can hold at most 8 rules.");
    for (const child of children) validateCondition(child, name, depth + 1, issues);
    return;
  }
  if (!condition.left || !condition.right) return error("a comparison needs two sides.");
  if (condition.left.kind === "constant" && condition.right.kind === "constant") error("comparing two fixed numbers does nothing.");
  for (const operand of [condition.left, condition.right]) validateOperand(operand, name, issues);
}

/**
 * Checks a strategy before it can run — whoever wrote it. An AI-drafted strategy gets no
 * special trust: it passes this or it doesn't run.
 */
export function validate(spec: StrategySpec): StrategyIssue[] {
  const issues: StrategyIssue[] = [];
  const error = (m: string) => issues.push({ severity: "error", message: m });
  const warn = (m: string) => issues.push({ severity: "warning", message: m });

  if (swiftTrim(spec.title) === "") error("The strategy needs a name.");

  if (spec.followsLedgerPositions) {
    if (spec.kind !== "rules") error("Only a rules strategy can follow a portfolio's positions.");
  } else if (spec.universe.length === 0) {
    error("Choose at least one asset to watch.");
  }
  if (spec.universe.length > maxUniverse) error(`A strategy can watch at most ${maxUniverse} assets.`);
  if (new Set(spec.universe.map(instrumentID)).size !== spec.universe.length) error("The same asset is listed twice.");
  const currencies = new Set(spec.universe.map((i) => i.currency));
  if (currencies.size > 1) error(`All assets must trade in one currency (found ${sortedStrings(currencies).join(" and ")}).`);
  for (const instrument of spec.universe) {
    if (!isValidSymbol(instrument.symbol)) error(`"${instrument.symbol}" isn't a valid symbol.`);
  }

  switch (spec.kind) {
    case "rules":
      if (!spec.entry && !spec.followsLedgerPositions) error("A rules strategy needs a buy rule.");
      if (!spec.entry && !spec.exit && protectionsEmpty(spec.protections)) error("Add a sell rule or a protective exit.");
      if (spec.entry && !spec.exit && protectionsEmpty(spec.protections)) error("This strategy can buy but never sell. Add a sell rule or a stop.");
      if (spec.entry) validateCondition(spec.entry, "Buy rule", 0, issues);
      if (spec.exit) validateCondition(spec.exit, "Sell rule", 0, issues);
      break;
    case "dca": {
      const dca = spec.dca;
      if (!dca) { error("A scheduled-buy strategy needs an amount and an interval."); break; }
      if (!(Number.isFinite(dca.amountPerBuy) && dca.amountPerBuy > 0)) error("The amount per buy must be above zero.");
      if (!inRange(dca.intervalBars, 1, 250)) error("The buy interval must be between 1 and 250 bars.");
      break;
    }
    case "rebalance": {
      const rebalance = spec.monthlyInvestment?.allocation ?? spec.rebalance;
      if (!rebalance) { error("A rebalancing strategy needs target weights."); break; }
      const ids = new Set(spec.universe.map(instrumentID));
      // Targets are checked in id order, as Swift's validator does. (Swift still sums the total in
      // dictionary order; for weights that add up exactly, the order makes no difference.)
      const targets = sortedStrings(Object.keys(rebalance.targets));
      if (targets.length === 0) error("Add at least one target weight.");
      let total = 0;
      for (const id of targets) {
        const weight = rebalance.targets[id];
        if (!ids.has(id)) error(`Target ${id} isn't in the asset list.`);
        if (!(Number.isFinite(weight) && weight > 0 && weight <= 100)) error("Each target weight must be between 0 and 100%.");
        total += weight;
      }
      if (total > 100.0001) error(`Target weights add up to ${trimNumber(total)}% — they can't exceed 100%.`);
      if (spec.monthlyInvestment !== undefined) {
        if (spec.rebalance) error("Use one allocation configuration for monthly investing.");
        if (spec.timeframe !== "day") error("Monthly investing needs daily bars.");
        if (new Set(spec.universe.map((asset) => asset.venue)).size > 1) error("Monthly investing needs assets traded on the same market.");
        if (spec.universe.some((asset) => asset.assetClass !== "etf")) error("Choose ETFs for monthly investing and rebalancing.");
        if (targets.length !== ids.size || targets.some((id) => !ids.has(id)) || Math.abs(total - 100) > 0.0001) {
          error("Set a target for every ETF. The weights must add up to 100%.");
        }
        if (!(Number.isFinite(spec.monthlyInvestment.amount) && spec.monthlyInvestment.amount > 0)) error("Enter a monthly investment above zero.");
        if (Object.values(spec.protections).some((value) => value !== undefined)) {
          error("This strategy supports allocation drift exits. Remove the separate price-based exits.");
        }
      }
      const drift = rebalance.driftThresholdPct;
      if (!(Number.isFinite(drift) && drift >= 0.5 && drift <= 50)) error("The drift threshold must be between 0.5 and 50 points.");
      break;
    }
    case "research":
      if (spec.entry || spec.exit) warn("Research strategies ignore buy and sell rules.");
      break;
  }

  if (spec.monthlyInvestment !== undefined && spec.kind !== "rebalance") error("Monthly investing requires a rebalancing strategy.");
  const p = spec.protections;
  if (p.stopLossPct !== undefined && !(Number.isFinite(p.stopLossPct) && p.stopLossPct > 0 && p.stopLossPct < 100)) error("Stop loss must be between 0 and 100%.");
  if (p.takeProfitPct !== undefined && !(Number.isFinite(p.takeProfitPct) && p.takeProfitPct > 0 && p.takeProfitPct <= 1_000)) error("Take profit must be between 0 and 1000%.");
  if (p.trailingStopPct !== undefined && !(Number.isFinite(p.trailingStopPct) && p.trailingStopPct > 0 && p.trailingStopPct < 100)) error("Trailing stop must be between 0 and 100%.");
  if (p.maxHoldingBars !== undefined && !inRange(p.maxHoldingBars, 1, 2_000)) error("The holding time limit must be between 1 and 2000 bars.");

  if (spec.sizing.mode === "fixedNotional") {
    if (!(Number.isFinite(spec.sizing.value) && spec.sizing.value > 0)) error("The order size must be above zero.");
  } else if (!(Number.isFinite(spec.sizing.value) && spec.sizing.value > 0 && spec.sizing.value <= 100)) {
    error("The order size must be between 0 and 100% of the portfolio.");
  }
  if (!inRange(spec.reentryCooldownBars, 0, 500)) error("The re-entry wait must be between 0 and 500 bars.");
  return issues;
}

export function isValid(spec: StrategySpec): boolean {
  return !validate(spec).some((issue) => issue.severity === "error");
}

export const StrategyValidator = { maxUniverse, maxPeriod, validate, isValid, isValidSymbol };

// MARK: - Decoding untrusted JSON

/**
 * Reads a strategy from JSON that came over the network. It is as strict as Swift's
 * decoder about shapes and types (a wrong type or an unknown enum value is refused) and
 * lenient only where the Swift is: an asset may be just a symbol. The result still has to
 * pass `validate`.
 */
export function decodeStrategySpec(raw: unknown): StrategySpec {
  const o = object(raw, "The strategy");
  const spec: StrategySpec = {
    kind: oneOf(o.kind, STRATEGY_KINDS, "kind"),
    title: text(o.title, "title"),
    summary: text(o.summary, "summary"),
    timeframe: oneOf(o.timeframe, TIMEFRAMES, "timeframe"),
    universe: list(o.universe, "universe").map(decodeInstrument),
    protections: decodeProtections(o.protections),
    sizing: decodeSizing(o.sizing),
    reentryCooldownBars: integer(o.reentryCooldownBars, "reentryCooldownBars"),
    followsLedgerPositions: boolean(o.followsLedgerPositions, "followsLedgerPositions"),
  };
  if (present(o.entry)) spec.entry = decodeCondition(o.entry, 0);
  if (present(o.exit)) spec.exit = decodeCondition(o.exit, 0);
  if (present(o.dca)) {
    const d = object(o.dca, "dca");
    spec.dca = { amountPerBuy: number(d.amountPerBuy, "dca.amountPerBuy"), intervalBars: integer(d.intervalBars, "dca.intervalBars") };
  }
  if (present(o.monthlyInvestment)) {
    const monthly = object(o.monthlyInvestment, "monthlyInvestment");
    spec.monthlyInvestment = { amount: number(monthly.amount, "monthlyInvestment.amount"), allocation: decodeAllocation(monthly.allocation) };
  }
  if (present(o.rebalance)) spec.rebalance = decodeAllocation(o.rebalance);
  return spec;
}

function decodeAllocation(raw: unknown): RebalanceConfig {
  const r = object(raw, "allocation");
  const targets: Record<string, number> = {};
  for (const [id, weight] of Object.entries(object(r.targets, "allocation.targets"))) targets[id] = number(weight, `allocation.targets.${id}`);
  return { targets, driftThresholdPct: number(r.driftThresholdPct, "allocation.driftThresholdPct") };
}

function decodeProtections(raw: unknown): Protections {
  const o = object(raw, "protections");
  const p: Protections = {};
  if (present(o.stopLossPct)) p.stopLossPct = number(o.stopLossPct, "protections.stopLossPct");
  if (present(o.takeProfitPct)) p.takeProfitPct = number(o.takeProfitPct, "protections.takeProfitPct");
  if (present(o.trailingStopPct)) p.trailingStopPct = number(o.trailingStopPct, "protections.trailingStopPct");
  if (present(o.maxHoldingBars)) p.maxHoldingBars = integer(o.maxHoldingBars, "protections.maxHoldingBars");
  return p;
}

function decodeSizing(raw: unknown): Sizing {
  const o = object(raw, "sizing");
  return { mode: oneOf(o.mode, ["fixedNotional", "percentOfEquity"] as SizingMode[], "sizing.mode"), value: number(o.value, "sizing.value") };
}

function decodeCondition(raw: unknown, depth: number): Condition {
  if (depth > 16) throw new Error("The rules are nested too deeply to read.");
  const o = object(raw, "A rule");
  const condition: Condition = { op: oneOf(o.op, CONDITION_OPS, "op") };
  if (present(o.left)) condition.left = decodeOperand(o.left);
  if (present(o.right)) condition.right = decodeOperand(o.right);
  if (present(o.conditions)) condition.conditions = list(o.conditions, "conditions").map((child) => decodeCondition(child, depth + 1));
  return condition;
}

function decodeOperand(raw: unknown): Operand {
  const o = object(raw, "An operand");
  const operand: Operand = { kind: oneOf(o.kind, OPERAND_KINDS, "operand kind") };
  if (present(o.field)) operand.field = oneOf(o.field, PRICE_FIELDS, "field");
  if (present(o.period)) operand.period = integer(o.period, "period");
  if (present(o.fast)) operand.fast = integer(o.fast, "fast");
  if (present(o.slow)) operand.slow = integer(o.slow, "slow");
  if (present(o.signal)) operand.signal = integer(o.signal, "signal");
  if (present(o.deviations)) operand.deviations = number(o.deviations, "deviations");
  if (present(o.value)) operand.value = number(o.value, "value");
  if (present(o.factor)) operand.factor = number(o.factor, "factor");
  return operand;
}

function present(value: unknown): boolean {
  return value !== undefined && value !== null;
}

function object(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${what} is missing or isn't an object.`);
  return value as Record<string, unknown>;
}

function list(value: unknown, what: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`"${what}" must be a list.`);
  return value;
}

function text(value: unknown, what: string): string {
  if (typeof value !== "string") throw new Error(`"${what}" must be text.`);
  return value;
}

function number(value: unknown, what: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`"${what}" must be a number.`);
  return value;
}

function integer(value: unknown, what: string): number {
  if (typeof value !== "number" || !Number.isInteger(value)) throw new Error(`"${what}" must be a whole number.`);
  return value;
}

function boolean(value: unknown, what: string): boolean {
  if (typeof value !== "boolean") throw new Error(`"${what}" must be true or false.`);
  return value;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[], what: string): T {
  if (typeof value !== "string" || !allowed.includes(value as T)) throw new Error(`"${what}" isn't a value this version understands.`);
  return value as T;
}
