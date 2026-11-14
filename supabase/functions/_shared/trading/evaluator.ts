// Strategy rules → a decision on one completed bar. A port of
// TradingCore/Sources/TradingCore/StrategyEvaluator.swift.

import { Indicators, type Series } from "./indicators.ts";
import { type Bar, barName, measureStats, type Timeframe } from "./market.ts";
import type { OrderSide } from "./orders.ts";
import { floor, money } from "./rounding.ts";
import {
  type Condition, conditionLabel, isGroup, type Operand, Op, type RebalanceConfig, type StrategySpec, warmupBars,
} from "./strategy.ts";
import { capitalized, cFixed, compareStrings, NumberText, sortedStrings, trimNumber } from "./text.ts";

export type SignalAction = "buy" | "sell" | "hold";
export type ExitReason = "rule" | "stopLoss" | "takeProfit" | "trailingStop" | "timeLimit" | "rebalance";

/** One observed fact behind a decision, e.g. "Close is above 50-day average — 212.40 vs 204.11". */
export interface Evidence {
  label: string;
  value: string;
  /** Whether the rule this fact belongs to was met; undefined for plain observations. */
  passed?: boolean;
}

function evidence(label: string, value: string, passed?: boolean): Evidence {
  return passed === undefined ? { label, value } : { label, value, passed };
}

/** The open position a strategy is managing, as far as its rules need to know. */
export interface PositionContext {
  quantity: number;
  averageCost: number;
  openedAt: number;
}

export interface SignalDecision {
  action: SignalAction;
  headline: string;
  evidence: Evidence[];
  /** The completed bar this decision was made on. */
  barTime: number;
  close: number;
  exitReason?: ExitReason;
  /** How far past their thresholds the met rules are, 0...1. It measures margin, not the chance of a profit. */
  ruleMargin?: number;
}

/** Indicator values for one bar series, computed once and reused across rules and bars. */
export class PreparedSeries {
  readonly bars: Bar[];
  private readonly closes: number[];
  private readonly cache = new Map<string, Series>();

  constructor(bars: Bar[]) {
    this.bars = bars;
    this.closes = bars.map((bar) => bar.close);
  }

  get count(): number {
    return this.bars.length;
  }

  /** The operand's value at bar `index`, using only bars up to and including it. */
  value(operand: Operand, index: number): number | undefined {
    if (!Number.isInteger(index) || index < 0 || index >= this.bars.length) return undefined;
    const o = operand;
    const key = `${o.kind}|${o.field ?? ""}|${o.period ?? ""}|${o.fast ?? ""}|${o.slow ?? ""}|${o.signal ?? ""}|${o.deviations ?? ""}|${o.value ?? ""}`;
    let series = this.cache.get(key);
    if (!series) {
      series = this.compute(o);
      this.cache.set(key, series);
    }
    const raw = series[index];
    if (raw === undefined || !Number.isFinite(raw)) return undefined;
    return raw * (operand.factor ?? 1);
  }

  private compute(o: Operand): Series {
    const bars = this.bars;
    switch (o.kind) {
      case "price":
        switch (o.field ?? "close") {
          case "open": return bars.map((bar) => bar.open);
          case "high": return bars.map((bar) => bar.high);
          case "low": return bars.map((bar) => bar.low);
          case "close": return this.closes.slice();
        }
        break;
      case "volume": return bars.map((bar) => bar.volume);
      case "volumeAverage": return Indicators.sma(bars.map((bar) => bar.volume), o.period ?? 20);
      case "constant": return new Array<number | undefined>(bars.length).fill(o.value);
      case "sma": return Indicators.sma(this.closes, o.period ?? 0);
      case "ema": return Indicators.ema(this.closes, o.period ?? 0);
      case "rsi": return Indicators.rsi(this.closes, o.period ?? 14);
      case "atr": return Indicators.atr(bars, o.period ?? 14);
      case "highest": return Indicators.priorHighest(bars.map((bar) => bar.high), o.period ?? 0);
      case "lowest": return Indicators.priorLowest(bars.map((bar) => bar.low), o.period ?? 0);
      case "rateOfChange": return Indicators.rateOfChange(this.closes, o.period ?? 0);
      case "macdLine": case "macdSignal": case "macdHistogram": {
        const result = Indicators.macd(this.closes, o.fast ?? 12, o.slow ?? 26, o.signal ?? 9);
        return o.kind === "macdLine" ? result.line : o.kind === "macdSignal" ? result.signal : result.histogram;
      }
      case "bollingerUpper": case "bollingerMiddle": case "bollingerLower": {
        const bands = Indicators.bollinger(this.closes, o.period ?? 20, o.deviations ?? 2);
        return o.kind === "bollingerUpper" ? bands.upper : o.kind === "bollingerLower" ? bands.lower : bands.middle;
      }
    }
    return new Array<number | undefined>(bars.length).fill(undefined);
  }

  /** Index of the bar containing `time` (the last bar that starts at or before it). */
  indexContaining(time: number): number | undefined {
    const bars = this.bars;
    if (bars.length === 0 || !(bars[0].time <= time)) return undefined;
    let lo = 0, hi = bars.length - 1;
    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      if (bars[mid].time <= time) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }
}

interface ConditionResult {
  met: boolean | undefined;
  evidence: Evidence[];
  margins: number[];
}

export function evaluateCondition(condition: Condition, prepared: PreparedSeries, index: number, timeframe: Timeframe): ConditionResult {
  if (isGroup(condition)) {
    const results = (condition.conditions ?? []).map((child) => evaluateCondition(child, prepared, index, timeframe));
    const allEvidence = results.flatMap((r) => r.evidence);
    const margins = results.filter((r) => r.met === true).flatMap((r) => r.margins);
    let met: boolean | undefined;
    if (condition.op === "all") {
      if (results.some((r) => r.met === false)) met = false;
      else if (results.some((r) => r.met === undefined)) met = undefined;
      else met = results.length > 0;
    } else {
      if (results.some((r) => r.met === true)) met = true;
      else if (results.some((r) => r.met === undefined)) met = undefined;
      else met = false;
    }
    return { met, evidence: allEvidence, margins };
  }

  const label = conditionLabel(condition, timeframe);
  const l = condition.left ? prepared.value(condition.left, index) : undefined;
  const r = condition.right ? prepared.value(condition.right, index) : undefined;
  if (!condition.left || !condition.right || l === undefined || r === undefined) {
    return { met: undefined, evidence: [evidence(label, "Not enough history")], margins: [] };
  }
  let met: boolean | undefined;
  switch (condition.op) {
    case "above": met = l > r; break;
    case "below": met = l < r; break;
    case "crossesAbove": case "crossesBelow": {
      const pl = index >= 1 ? prepared.value(condition.left, index - 1) : undefined;
      const pr = index >= 1 ? prepared.value(condition.right, index - 1) : undefined;
      if (pl !== undefined && pr !== undefined) {
        met = condition.op === "crossesAbove" ? (pl <= pr && l > r) : (pl >= pr && l < r);
      } else {
        met = undefined;
      }
      break;
    }
    default: met = undefined;
  }
  const value = `${NumberText.number(l)} vs ${NumberText.number(r)}`;
  const margin = Math.abs(r) > 1e-9 ? Math.abs(l - r) / Math.abs(r) : 0;
  return { met, evidence: [evidence(label, value, met)], margins: met === true ? [margin] : [] };
}

/** Average distance past the thresholds, where 5% or more counts as full margin. */
export function marginScore(margins: number[]): number | undefined {
  if (margins.length === 0) return undefined;
  let sum = 0;
  for (const m of margins) sum += m;
  const mean = sum / margins.length;
  return Math.min(Math.max(mean / 0.05, 0), 1);
}

/** The decision on bar `index`, reading nothing after it. */
export function decideAt(spec: StrategySpec, prepared: PreparedSeries, index: number, position: PositionContext | undefined,
  lastExitTime?: number): SignalDecision {
  const bar = prepared.bars[index];
  const tf = spec.timeframe;
  const hold = (headline: string, items: Evidence[] = []): SignalDecision =>
    ({ action: "hold", headline, evidence: items, barTime: bar.time, close: bar.close });
  const sell = (headline: string, items: Evidence[], exitReason: ExitReason, ruleMargin?: number): SignalDecision => {
    const decision: SignalDecision = { action: "sell", headline, evidence: items, barTime: bar.time, close: bar.close, exitReason };
    if (ruleMargin !== undefined) decision.ruleMargin = ruleMargin;
    return decision;
  };

  const needed = warmupBars(spec);
  if (index + 1 < needed) {
    return hold(`Not enough history yet: the rules need ${needed} ${barName(tf)} bars and ${index + 1} are available.`);
  }

  if (position && position.quantity > 0) {
    const entryIndex = prepared.indexContaining(position.openedAt) ?? 0;
    const items: Evidence[] = [];
    const cost = position.averageCost;
    if (cost > 0) {
      const changePct = (bar.close / cost - 1) * 100;
      items.push(evidence("Position", `Close ${NumberText.price(bar.close)}, cost ${NumberText.price(cost)} (${NumberText.signedPercent(changePct)})`));
    }
    const p = spec.protections;
    if (p.stopLossPct !== undefined && cost > 0) {
      const stop = p.stopLossPct;
      const level = cost * (1 - stop / 100);
      const hit = bar.close <= level;
      items.push(evidence(`Stop loss ${trimNumber(stop)}%`, `Close ${NumberText.price(bar.close)} vs stop ${NumberText.price(level)}`, hit));
      if (hit) return sell(`Stop loss: the close is ${trimNumber(stop)}% or more below cost.`, items, "stopLoss");
    }
    if (p.takeProfitPct !== undefined && cost > 0) {
      const target = p.takeProfitPct;
      const level = cost * (1 + target / 100);
      const hit = bar.close >= level;
      items.push(evidence(`Take profit ${trimNumber(target)}%`, `Close ${NumberText.price(bar.close)} vs target ${NumberText.price(level)}`, hit));
      if (hit) return sell(`Take profit: the close is ${trimNumber(target)}% or more above cost.`, items, "takeProfit");
    }
    if (p.trailingStopPct !== undefined) {
      const trail = p.trailingStopPct;
      let highest = prepared.bars[Math.min(entryIndex, index)].close;
      for (let i = Math.min(entryIndex, index) + 1; i <= index; i++) {
        if (prepared.bars[i].close > highest) highest = prepared.bars[i].close;
      }
      const level = highest * (1 - trail / 100);
      const hit = bar.close <= level;
      items.push(evidence(`Trailing stop ${trimNumber(trail)}%`,
        `Close ${NumberText.price(bar.close)} vs ${NumberText.price(level)} (high ${NumberText.price(highest)})`, hit));
      if (hit) return sell(`Trailing stop: the close is ${trimNumber(trail)}% below its highest close since entry.`, items, "trailingStop");
    }
    if (p.maxHoldingBars !== undefined) {
      const limit = p.maxHoldingBars;
      const held = index - entryIndex;
      const hit = held >= limit;
      items.push(evidence("Time limit", `Held ${held} of ${limit} bars`, hit));
      if (hit) return sell(`Time limit: held for ${held} bars.`, items, "timeLimit");
    }
    if (spec.exit) {
      const result = evaluateCondition(spec.exit, prepared, index, tf);
      items.push(...result.evidence);
      if (result.met === true) {
        return sell(`Sell rule met: ${conditionLabel(spec.exit, tf)}.`, items, "rule", marginScore(result.margins));
      }
    }
    return hold("Holding: no sell rule or protective exit was met.", items);
  }

  if (lastExitTime !== undefined && spec.reentryCooldownBars > 0) {
    const exitIndex = prepared.indexContaining(lastExitTime);
    if (exitIndex !== undefined) {
      const since = index - exitIndex;
      if (since < spec.reentryCooldownBars) {
        return hold(`Waiting ${spec.reentryCooldownBars - since} more bar(s) after the last exit before buying again.`);
      }
    }
  }

  if (!spec.entry) return hold("Nothing to do: this strategy only manages positions that are already open.");
  const result = evaluateCondition(spec.entry, prepared, index, tf);
  if (result.met === true) {
    const decision: SignalDecision = {
      action: "buy", headline: `Buy rule met: ${conditionLabel(spec.entry, tf)}.`, evidence: result.evidence,
      barTime: bar.time, close: bar.close,
    };
    const margin = marginScore(result.margins);
    if (margin !== undefined) decision.ruleMargin = margin;
    return decision;
  }
  if (result.met === false) return hold("No buy: the buy rule isn't met.", result.evidence);
  return hold("Not enough history to evaluate the buy rule.", result.evidence);
}

/**
 * The decision a rules strategy makes on the last bar of `bars`.
 * `bars` must hold completed bars only (see `MarketCalendar.completedBars`).
 */
export function decide(spec: StrategySpec, bars: Bar[], position: PositionContext | undefined, lastExitTime?: number): SignalDecision | undefined {
  if (bars.length === 0) return undefined;
  return decideAt(spec, new PreparedSeries(bars), bars.length - 1, position, lastExitTime);
}

/** Whether a scheduled-buy strategy is due on the last bar. */
export function decideDCA(spec: StrategySpec, bars: Bar[], lastBuyTime?: number): SignalDecision | undefined {
  const dca = spec.dca;
  if (!dca || bars.length === 0) return undefined;
  const bar = bars[bars.length - 1];
  const prepared = new PreparedSeries(bars);
  const lastIndex = lastBuyTime === undefined ? undefined : prepared.indexContaining(lastBuyTime);
  if (lastIndex === undefined) {
    return {
      action: "buy", headline: "Scheduled buy: first purchase.",
      evidence: [evidence("Schedule", `Every ${dca.intervalBars} bar(s)`, true)], barTime: bar.time, close: bar.close,
    };
  }
  const since = bars.length - 1 - lastIndex;
  const due = since >= dca.intervalBars;
  const items = [evidence("Schedule", `${since} of ${dca.intervalBars} bar(s) since the last buy`, due)];
  if (due) {
    return { action: "buy", headline: `Scheduled buy: ${since} bars since the last purchase.`, evidence: items, barTime: bar.time, close: bar.close };
  }
  return { action: "hold", headline: `Next scheduled buy in ${dca.intervalBars - since} bar(s).`, evidence: items, barTime: bar.time, close: bar.close };
}

export interface RebalanceTrade {
  instrumentID: string;
  side: OrderSide;
  notional: number;
  currentPct: number;
  targetPct: number;
}

/**
 * Trades that bring holdings back to target. Sells come first so their proceeds fund the
 * buys. `values` is the market value of each holding by instrument id.
 */
export function rebalanceTrades(config: RebalanceConfig, values: Record<string, number>, equity: number): RebalanceTrade[] {
  if (!(equity > 0)) return [];
  const trades: RebalanceTrade[] = [];
  for (const id of sortedStrings(Object.keys(config.targets))) {
    const targetPct = config.targets[id];
    const current = values[id] ?? 0;
    const currentPct = current / equity * 100;
    const drift = currentPct - targetPct;
    if (!(Math.abs(drift) >= config.driftThresholdPct)) continue;
    const delta = equity * targetPct / 100 - current;
    trades.push({ instrumentID: id, side: delta >= 0 ? "buy" : "sell", notional: money(Math.abs(delta)), currentPct, targetPct });
  }
  return trades.sort((a, b) => {
    if (a.side !== b.side) return a.side === "sell" ? -1 : 1;
    return compareStrings(a.instrumentID, b.instrumentID);
  });
}

/** Split monthly practice cash across target weights and restore all weights if one breaches the threshold. */
export function monthlyRebalanceTrades(config: RebalanceConfig, values: Record<string, number>, contribution: number): RebalanceTrade[] {
  const ids = sortedStrings(Object.keys(config.targets));
  const invested = ids.reduce((total, id) => total + (values[id] ?? 0), 0);
  const total = invested + contribution;
  if (!(total > 0)) return [];
  const triggered = invested > 0 && ids.some((id) =>
    Math.abs((values[id] ?? 0) / invested * 100 - config.targets[id]) >= config.driftThresholdPct
  );
  const deltas = ids.map((id): RebalanceTrade => {
    const current = values[id] ?? 0;
    const targetPct = config.targets[id];
    const delta = triggered ? total * targetPct / 100 - current : contribution * targetPct / 100;
    return { instrumentID: id, side: delta < 0 ? "sell" : "buy", notional: floor(Math.abs(delta), 0.01),
      currentPct: invested > 0 ? current / invested * 100 : 0, targetPct };
  });
  const sells = deltas.filter((trade) => trade.side === "sell" && trade.notional > 0);
  let available = floor(contribution, 0.01) + sells.reduce((amount, trade) => amount + trade.notional, 0);
  const buys = deltas.filter((trade) => trade.side === "buy").flatMap((trade) => {
    const notional = Math.min(trade.notional, money(available));
    if (notional <= 0) return [];
    available -= notional;
    return [{ ...trade, notional }];
  });
  return [...sells, ...buys];
}

/** Plain facts about a series, for research-only agents and the copilot. No opinion, no order. */
export function researchFacts(bars: Bar[], timeframe: Timeframe = "day"): Evidence[] {
  if (bars.length === 0) return [];
  const last = bars[bars.length - 1];
  const prepared = new PreparedSeries(bars);
  const i = bars.length - 1;
  const unit = timeframe === "day" ? "day" : "hour";
  const facts: Evidence[] = [evidence("Last close", NumberText.price(last.close))];
  for (const period of [1, 5, 20]) {
    const change = prepared.value(Op.rateOfChange(period), i);
    if (change !== undefined) facts.push(evidence(`${period}-${unit} change`, NumberText.signedPercent(change)));
  }
  for (const period of [50, 200]) {
    const average = prepared.value(Op.sma(period), i);
    if (average !== undefined && average > 0) {
      const gap = (last.close / average - 1) * 100;
      facts.push(evidence(`vs ${period}-${unit} average`, `${NumberText.signedPercent(gap)} (${NumberText.price(average)})`));
    }
  }
  const rsi = prepared.value(Op.rsi(14), i);
  if (rsi !== undefined) facts.push(evidence("RSI (14)", cFixed(rsi, 0)));
  const stats = measureStats(bars);
  if (stats && timeframe === "day") facts.push(evidence("Daily volatility (20-day)", `${cFixed(stats.dailyVolatilityPct, 1)}%`));
  const window = bars.slice(Math.max(bars.length - 252, 0));
  if (window.length >= 20) {
    let high = window[0].high;
    for (const bar of window) if (bar.high > high) high = bar.high;
    if (high > 0) facts.push(evidence(`Below ${window.length}-bar high`, NumberText.signedPercent((last.close / high - 1) * 100)));
  }
  return facts;
}

export const StrategyEvaluator = { decide, decideAt, decideDCA, rebalanceTrades, monthlyRebalanceTrades, researchFacts, evaluateCondition, marginScore };

export { capitalized };
