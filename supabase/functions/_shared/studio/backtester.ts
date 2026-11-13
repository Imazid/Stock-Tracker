// Port of TradingCore/Backtester.swift (incl. the transaction taxes from core b0d2f19). Local additions: config initialiser helpers,
// BacktestError, and deterministic UUID-shaped trade IDs in place of Swift's UUID().
// No clock, randomness, I/O, or runtime-specific APIs are used here.

import { defaultPaperConfig, PaperBroker, type PaperBrokerConfig } from "../trading/broker.ts";
import { MarketCalendar } from "../trading/calendar.ts";
import { PreparedSeries, StrategyEvaluator } from "../trading/evaluator.ts";
import type { EquityPoint } from "../trading/ledger.ts";
import { type Bar, type BarSeries, barName, type Instrument, instrumentID, isRealMarketData } from "../trading/market.ts";
import type { OrderSide } from "../trading/orders.ts";
import * as Rounding from "../trading/rounding.ts";
import { sha256Hex } from "../trading/sha256.ts";
import { type AgentDraft, resolvedPolicy } from "../trading/state.ts";
import { type StrategySpec, StrategyValidator, warmupBars } from "../trading/strategy.ts";
import { cFixed, compareStrings, NumberText } from "../trading/text.ts";

export interface BacktestConfig {
  startingCash: number;
  slippageBps: number;
  equityFeePerOrder: number;
  equityFeeBps: number;
  cryptoFeeBps: number;
  maxOrderNotional: number;
  maxPositionPct: number;
  maxOpenPositions: number;
  outOfSampleFraction: number;
  riskFreeRatePct: number;
  allowFixtureData: boolean;
}

export function makeBacktestConfig(fields: Partial<BacktestConfig> = {}): BacktestConfig {
  const startingCash = fields.startingCash ?? 10_000;
  return {
    startingCash, slippageBps: 5, equityFeePerOrder: 0, equityFeeBps: 0, cryptoFeeBps: 25,
    maxPositionPct: 10, maxOpenPositions: 10, outOfSampleFraction: 0.3, riskFreeRatePct: 0,
    allowFixtureData: false, ...fields, maxOrderNotional: fields.maxOrderNotional ?? startingCash,
  };
}

/** Swift's BacktestConfig(agent:paper:). */
export function backtestConfigForAgent(draft: AgentDraft, paper: PaperBrokerConfig = defaultPaperConfig()): BacktestConfig {
  const policy = resolvedPolicy(draft);
  return makeBacktestConfig({
    startingCash: draft.budget, slippageBps: 5, equityFeePerOrder: paper.equityFeePerOrder,
    equityFeeBps: paper.equityFeeBps, cryptoFeeBps: paper.cryptoFeeBps,
    maxOrderNotional: policy.maxOrderNotional, maxPositionPct: policy.maxPositionPct,
    maxOpenPositions: policy.maxOpenPositions,
  });
}

export interface BacktestTrade {
  id: string;
  instrument: Instrument;
  entryTime: number;
  entryPrice: number;
  quantity: number;
  exitTime?: number;
  exitPrice?: number;
  exitReason?: string;
  pnl: number;
  pnlPct: number;
  barsHeld: number;
  isOpen: boolean;
}

export interface BacktestMetrics {
  start: number;
  end: number;
  bars: number;
  startEquity: number;
  endEquity: number;
  totalReturnPct: number;
  cagrPct?: number;
  maxDrawdownPct: number;
  volatilityPct: number;
  sharpe?: number;
  sortino?: number;
  closedTrades: number;
  winRatePct?: number;
  profitFactor?: number;
  averageWinPct?: number;
  averageLossPct?: number;
  exposurePct: number;
  feesPaid: number;
}

export interface BacktestWindow {
  index: number;
  metrics: BacktestMetrics;
  readonly id: number;
}

export interface BacktestResult {
  strategyTitle: string;
  config: BacktestConfig;
  dataSources: string[];
  usedRealMarketData: boolean;
  equityCurve: EquityPoint[];
  benchmarkCurve: EquityPoint[];
  benchmarkName?: string;
  benchmarkReturnPct?: number;
  trades: BacktestTrade[];
  overall: BacktestMetrics;
  inSample?: BacktestMetrics;
  outOfSample?: BacktestMetrics;
  splitTime?: number;
  windows: BacktestWindow[];
  assumptions: string[];
  warnings: string[];
}

export type BacktestErrorKind = "notRealData" | "noData" | "insufficientHistory" | "unsupported";

export class BacktestError extends Error {
  readonly kind: BacktestErrorKind;
  readonly symbol?: string;
  readonly needed?: number;
  readonly available?: number;

  constructor(
    kind: BacktestErrorKind,
    message: string,
    symbol?: string,
    needed?: number,
    available?: number,
  ) {
    super(message);
    this.name = "BacktestError";
    this.kind = kind;
    this.symbol = symbol;
    this.needed = needed;
    this.available = available;
  }

  get errorDescription(): string { return this.message; }

  static notRealData = (symbol: string): BacktestError => new BacktestError(
    "notRealData", `The price history for ${symbol} isn't real market data, so it can't be backtested.`, symbol,
  );
  static noData = (): BacktestError => new BacktestError("noData", "There is no price history to test on.");
  static insufficientHistory = (needed: number, available: number): BacktestError => new BacktestError(
    "insufficientHistory", `This strategy needs at least ${needed} bars of history and only ${available} are available.`,
    undefined, needed, available,
  );
  static unsupported = (why: string): BacktestError => new BacktestError("unsupported", why);
}

interface Holding {
  quantity: number;
  costBasis: number;
  entryTime: number;
  entryPrice: number;
  entryIndex: number;
}

interface Pending {
  side: OrderSide;
  notional?: number;
  reason: string;
}

function tradeID(trade: Omit<BacktestTrade, "id">, sequence: number): string {
  const hex = sha256Hex(JSON.stringify(["backtest", instrumentID(trade.instrument), trade.entryTime,
    trade.exitTime, trade.quantity, sequence]));
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-8${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

/** A close can only submit an order for the next available bar's open. */
function run(spec: StrategySpec, series: Record<string, BarSeries>, config: BacktestConfig, asOf: number,
  benchmark?: BarSeries, calendar: Pick<typeof MarketCalendar, "completedBars"> = MarketCalendar): BacktestResult {
  if (spec.kind === "research") throw BacktestError.unsupported("A research strategy never trades, so there is nothing to backtest.");
  if (spec.followsLedgerPositions) {
    throw BacktestError.unsupported("A risk manager guards positions someone else opens, so it can't be backtested by itself.");
  }
  const problem = StrategyValidator.validate(spec).find((issue) => issue.severity === "error");
  if (problem) throw BacktestError.unsupported(problem.message);

  function accept(s: BarSeries): void {
    if (s.provenance.kind === "market" || (s.provenance.kind === "fixture" && config.allowFixtureData)) return;
    throw BacktestError.notRealData(s.instrument.symbol);
  }

  const bars = new Map<string, Bar[]>();
  const sources = new Set<string>();
  let allReal = true;
  for (const instrument of spec.universe) {
    const id = instrumentID(instrument);
    const s = series[id];
    if (!s) continue;
    accept(s);
    if (s.timeframe !== spec.timeframe) continue;
    const completed = calendar.completedBars(s, asOf);
    if (completed.length > 0) bars.set(id, completed);
    sources.add(s.provenance.source);
    if (!isRealMarketData(s.provenance)) allReal = false;
  }
  if (bars.size === 0) throw BacktestError.noData();
  const longest = Math.max(...Array.from(bars.values(), (list) => list.length));
  const needed = spec.kind === "rules" ? warmupBars(spec) + 20 : 20;
  if (longest < needed) throw BacktestError.insufficientHistory(needed, longest);

  const warnings: string[] = [];
  const missing = spec.universe.filter((i) => !bars.has(instrumentID(i))).map((i) => i.symbol);
  if (missing.length > 0) warnings.push(`No history for ${missing.join(", ")}; tested without ${missing.length === 1 ? "it" : "them"}.`);
  if (spec.kind === "rebalance" && missing.length > 0) {
    throw BacktestError.unsupported(`Rebalancing needs history for every fund. Missing: ${missing.join(", ")}.`);
  }

  const instruments = new Map(spec.universe.map((i) => [instrumentID(i), i]));
  const prepared = new Map(Array.from(bars, ([id, list]) => [id, new PreparedSeries(list)]));
  const cursor = new Map(Array.from(bars.keys(), (id) => [id, 0]));
  const timeline = Array.from(new Set(Array.from(bars.values()).flatMap((list) => list.map((bar) => bar.time)))).sort((a, b) => a - b);
  let cash = Rounding.money(config.startingCash);
  const holdings = new Map<string, Holding>();
  const pending = new Map<string, Pending>();
  const lastClose = new Map<string, number>();
  const lastExit = new Map<string, number>();
  const lastBuyIndex = new Map<string, number>();
  const trades: BacktestTrade[] = [];
  const curve: EquityPoint[] = [];
  const invested: boolean[] = [];
  let fees = 0;
  const slip = config.slippageBps / 10_000;

  const fee = (instrument: Instrument, side: OrderSide, notional: number): number => {
    const commission = instrument.assetClass === "crypto"
      ? Rounding.money(notional * config.cryptoFeeBps / 10_000)
      : Rounding.money(config.equityFeePerOrder + notional * config.equityFeeBps / 10_000);
    return Rounding.money(commission + PaperBroker.tax(instrument, side, notional));
  };
  const equity = (): number => cash + Array.from(holdings).reduce(
    (sum, [id, held]) => sum + held.quantity * (lastClose.get(id) ?? held.entryPrice), 0,
  );
  const appendTrade = (trade: Omit<BacktestTrade, "id">): void => {
    trades.push({ id: tradeID(trade, trades.length), ...trade });
  };

  for (const time of timeline) {
    const active: { id: string; index: number }[] = [];
    for (const [id, list] of bars) {
      const index = cursor.get(id) ?? 0;
      if (index < list.length && list[index].time === time) active.push({ id, index });
    }
    active.sort((a, b) => compareStrings(a.id, b.id));
    const executions = active.filter(({ id }) => pending.has(id)).sort((a, b) =>
      (pending.get(a.id)?.side === "sell" ? 0 : 1) - (pending.get(b.id)?.side === "sell" ? 0 : 1) || compareStrings(a.id, b.id));

    for (const { id, index } of executions) {
      const order = pending.get(id)!;
      pending.delete(id);
      const instrument = instruments.get(id)!;
      const list = bars.get(id)!;
      const rules = PaperBroker.rules(instrument);
      const open = list[index].open;
      if (order.side === "buy") {
        const price = open * (1 + slip);
        let notional = Math.min(order.notional ?? 0, config.maxOrderNotional);
        const feeRate = (instrument.assetClass === "crypto" ? config.cryptoFeeBps : config.equityFeeBps) / 10_000
          + PaperBroker.taxBps(instrument, "buy") / 10_000;
        const flat = instrument.assetClass === "crypto" ? 0 : config.equityFeePerOrder;
        notional = Math.min(notional, Math.max((cash - flat) / (1 + feeRate), 0));
        const quantity = Rounding.floor(notional / price, rules.quantityIncrement);
        const gross = Rounding.money(quantity * price);
        if (!(quantity >= rules.minQuantity && gross >= rules.minNotional)) continue;
        const cost = fee(instrument, "buy", gross);
        cash = Rounding.money(cash - gross - cost);
        fees += cost;
        const held = holdings.get(id);
        if (held) {
          held.quantity = Rounding.round(held.quantity + quantity, 9);
          held.costBasis = Rounding.money(held.costBasis + gross + cost);
        } else {
          holdings.set(id, { quantity, costBasis: Rounding.money(gross + cost), entryTime: list[index].time, entryPrice: price, entryIndex: index });
        }
        lastBuyIndex.set(id, index);
      } else {
        const held = holdings.get(id);
        if (!held) continue;
        const price = open * (1 - slip);
        let quantity = held.quantity;
        if (order.notional !== undefined) quantity = Math.min(held.quantity, Rounding.floor(order.notional / price, rules.quantityIncrement));
        if (!(quantity > 0)) continue;
        const closing = held.quantity - quantity <= 1e-9;
        const gross = Rounding.money(quantity * price);
        const cost = fee(instrument, "sell", gross);
        const costRemoved = closing ? held.costBasis : Rounding.money(held.costBasis / held.quantity * quantity);
        cash = Rounding.money(cash + gross - cost);
        fees += cost;
        const pnl = Rounding.money(gross - cost - costRemoved);
        appendTrade({ instrument, entryTime: held.entryTime, entryPrice: held.entryPrice, quantity,
          exitTime: list[index].time, exitPrice: price, exitReason: order.reason, pnl,
          pnlPct: costRemoved > 0 ? pnl / costRemoved * 100 : 0, barsHeld: index - held.entryIndex, isOpen: false });
        if (closing) {
          holdings.delete(id);
          lastExit.set(id, list[index].time);
        } else {
          held.quantity = Rounding.round(held.quantity - quantity, 9);
          held.costBasis = Rounding.money(held.costBasis - costRemoved);
        }
      }
    }

    for (const { id, index } of active) lastClose.set(id, bars.get(id)![index].close);
    const equityNow = equity();
    switch (spec.kind) {
      case "rules": {
        let openOrQueued = holdings.size + Array.from(pending.values()).filter((p) => p.side === "buy").length;
        for (const { id, index } of active) {
          if (pending.has(id)) continue;
          const held = holdings.get(id);
          const position = held ? { quantity: held.quantity, averageCost: held.costBasis / held.quantity, openedAt: held.entryTime } : undefined;
          const decision = StrategyEvaluator.decideAt(spec, prepared.get(id)!, index, position, lastExit.get(id));
          if (decision.action === "buy" && !position) {
            if (!(openOrQueued < config.maxOpenPositions)) continue;
            let notional = spec.sizing.mode === "fixedNotional" ? spec.sizing.value : equityNow * spec.sizing.value / 100;
            notional = Math.min(notional, config.maxOrderNotional, equityNow * config.maxPositionPct / 100);
            if (!(notional > 0)) continue;
            pending.set(id, { side: "buy", notional, reason: "entry" });
            openOrQueued += 1;
          } else if (decision.action === "sell" && position) {
            pending.set(id, { side: "sell", reason: decision.exitReason ?? "rule" });
          }
        }
        break;
      }
      case "dca": {
        if (!spec.dca) break;
        for (const { id, index } of active) {
          if (pending.has(id)) continue;
          const last = lastBuyIndex.get(id);
          const due = last === undefined || index + 1 - last >= spec.dca.intervalBars;
          if (due) pending.set(id, { side: "buy", notional: spec.dca.amountPerBuy, reason: "scheduled" });
        }
        break;
      }
      case "rebalance": {
        if (!spec.rebalance || pending.size > 0 || !Object.keys(spec.rebalance.targets).every((id) => lastClose.has(id))) break;
        const values: Record<string, number> = {};
        for (const id of Object.keys(spec.rebalance.targets)) values[id] = (holdings.get(id)?.quantity ?? 0) * (lastClose.get(id) ?? 0);
        for (const trade of StrategyEvaluator.rebalanceTrades(spec.rebalance, values, equityNow)) {
          pending.set(trade.instrumentID, { side: trade.side, notional: trade.notional, reason: "rebalance" });
        }
        break;
      }
    }
    for (const { id, index } of active) cursor.set(id, index + 1);
    curve.push({ time, equity: Rounding.money(equityNow), cash });
    invested.push(holdings.size > 0);
  }

  for (const [id, held] of Array.from(holdings).sort((a, b) => compareStrings(a[0], b[0]))) {
    const price = lastClose.get(id)!;
    const value = Rounding.money(held.quantity * price);
    appendTrade({ instrument: instruments.get(id)!, entryTime: held.entryTime, entryPrice: held.entryPrice,
      quantity: held.quantity, pnl: Rounding.money(value - held.costBasis),
      pnlPct: held.costBasis > 0 ? (value - held.costBasis) / held.costBasis * 100 : 0,
      barsHeld: bars.get(id)!.length - 1 - held.entryIndex, isOpen: true });
  }
  trades.sort((a, b) => a.entryTime - b.entryTime);
  if (curve.length < 2) throw BacktestError.noData();
  const overall = metrics(curve, invested, trades, fees, config);
  let inSample: BacktestMetrics | undefined;
  let outOfSample: BacktestMetrics | undefined;
  let splitTime: number | undefined;
  if (config.outOfSampleFraction > 0 && config.outOfSampleFraction < 1 && curve.length >= 40) {
    const split = Math.floor(curve.length * (1 - config.outOfSampleFraction));
    if (split >= 10 && curve.length - split >= 10) {
      splitTime = curve[split].time;
      inSample = metrics(curve.slice(0, split + 1), invested.slice(0, split + 1), trades, 0, config);
      outOfSample = metrics(curve.slice(split), invested.slice(split), trades, 0, config);
    }
  }
  const windows: BacktestWindow[] = [];
  if (curve.length >= 4 * 20) {
    const size = Math.trunc(curve.length / 4);
    for (let w = 0; w < 4; w++) {
      const lower = w * size;
      const upper = w === 3 ? curve.length - 1 : (w + 1) * size;
      // Swift's computed Identifiable.id is accessible but isn't a Codable field.
      const window = { index: w + 1,
        metrics: metrics(curve.slice(lower, upper + 1), invested.slice(lower, upper + 1), trades, 0, config) } as BacktestWindow;
      Object.defineProperty(window, "id", { get() { return this.index; } });
      windows.push(window);
    }
  }

  const benchmarkCurve: EquityPoint[] = [];
  let benchmarkReturnPct: number | undefined;
  if (benchmark) {
    accept(benchmark);
    const benchBars = calendar.completedBars(benchmark, asOf);
    const base = benchBars.filter((bar) => bar.time <= curve[0].time).at(-1)?.close ?? benchBars[0]?.close;
    if (base !== undefined && base > 0) {
      let j = 0;
      let last = base;
      for (const point of curve) {
        while (j < benchBars.length && benchBars[j].time <= point.time) { last = benchBars[j].close; j += 1; }
        benchmarkCurve.push({ time: point.time, equity: Rounding.money(config.startingCash * last / base), cash: 0 });
      }
      benchmarkReturnPct = (benchmarkCurve[benchmarkCurve.length - 1].equity / config.startingCash - 1) * 100;
    }
    if (!isRealMarketData(benchmark.provenance)) allReal = false;
  }
  if (overall.closedTrades < 20) warnings.push(`Only ${overall.closedTrades} completed trade${overall.closedTrades === 1 ? "" : "s"}: too few to judge the strategy by.`);
  const years = yearsBetween(curve[0].time, curve[curve.length - 1].time);
  if (years !== undefined && years < 1) warnings.push("Less than a year of history was tested, so one market mood dominates the result.");
  const assumptions = [
    `Signals use completed ${barName(spec.timeframe)} bars only. An order decided on one bar's close trades at the next bar's open.`,
    `Every fill gives up ${cFixed(config.slippageBps, 0)} bps of price as slippage.`,
    `Fees: equities ${NumberText.money(config.equityFeePerOrder)} per order plus ${cFixed(config.equityFeeBps, 0)} bps; crypto ${cFixed(config.cryptoFeeBps, 0)} bps. Transaction taxes (UK, France, Hong Kong, Korea, India) are included.`,
    "Orders are assumed to fill in full at the open. Real orders can fill at worse prices, in parts, or not at all.",
    "Stops are checked on bar closes, not inside the bar, so a real stop could trigger earlier or later.",
    spec.universe.some((i) => i.assetClass !== "crypto")
      ? "Share prices are adjusted for splits; dividends are not paid out as cash. Stocks that were delisted are not in the test, which flatters results."
      : "Crypto trades every day, including weekends.",
    "Cash earns no interest. Tax is not included.",
    "The rules were not tuned on this data. Past results do not predict future returns.",
  ];
  const result: BacktestResult = { strategyTitle: spec.title, config: { ...config }, dataSources: Array.from(sources).sort(compareStrings),
    usedRealMarketData: allReal, equityCurve: curve, benchmarkCurve, trades, overall, windows, assumptions, warnings };
  if (benchmark) result.benchmarkName = `${benchmark.instrument.symbol} buy and hold`;
  if (benchmarkReturnPct !== undefined) result.benchmarkReturnPct = benchmarkReturnPct;
  if (inSample) result.inSample = inSample;
  if (outOfSample) result.outOfSample = outOfSample;
  if (splitTime !== undefined) result.splitTime = splitTime;
  return result;
}

function yearsBetween(start?: number, end?: number): number | undefined {
  return start !== undefined && end !== undefined && end > start ? (end - start) / (365.25 * 86_400_000) : undefined;
}

function metrics(curve: readonly EquityPoint[], invested: readonly boolean[], trades: readonly BacktestTrade[],
  fees: number, config: BacktestConfig): BacktestMetrics {
  const first = curve[0] ?? { time: 0, equity: config.startingCash, cash: config.startingCash };
  const last = curve[curve.length - 1] ?? first;
  const years = yearsBetween(first.time, last.time) ?? 0;
  const returns: number[] = [];
  let peak = first.equity;
  let maxDrawdown = 0;
  for (let i = 0; i < curve.length; i++) {
    if (i > 0 && curve[i - 1].equity > 0) returns.push(curve[i].equity / curve[i - 1].equity - 1);
    peak = Math.max(peak, curve[i].equity);
    if (peak > 0) maxDrawdown = Math.max(maxDrawdown, (peak - curve[i].equity) / peak * 100);
  }
  const periodsPerYear = years > 0 ? returns.length / years : 252;
  const mean = returns.length === 0 ? 0 : returns.reduce((a, b) => a + b, 0) / returns.length;
  const variance = returns.length > 1 ? returns.map((r) => (r - mean) * (r - mean)).reduce((a, b) => a + b, 0) / (returns.length - 1) : 0;
  const stdev = Math.sqrt(variance);
  const riskFreePerPeriod = config.riskFreeRatePct / 100 / periodsPerYear;
  const downside = returns.map((r) => Rounding.swiftMin(r - riskFreePerPeriod, 0));
  const downsideDeviation = returns.length === 0 ? 0 : Math.sqrt(downside.map((r) => r * r).reduce((a, b) => a + b, 0) / returns.length);
  const enough = returns.length >= 20;
  const totalReturn = first.equity > 0 ? (last.equity / first.equity - 1) * 100 : 0;
  const closed = trades.filter((t) => !t.isOpen && t.exitTime !== undefined && t.exitTime > first.time && t.exitTime <= last.time);
  const wins = closed.filter((t) => t.pnl > 0);
  const losses = closed.filter((t) => t.pnl < 0);
  const grossProfit = wins.reduce((sum, t) => sum + t.pnl, 0);
  const grossLoss = -losses.reduce((sum, t) => sum + t.pnl, 0);
  const result: BacktestMetrics = {
    start: first.time, end: last.time, bars: curve.length, startEquity: first.equity, endEquity: last.equity,
    totalReturnPct: totalReturn, maxDrawdownPct: maxDrawdown, volatilityPct: stdev * Math.sqrt(periodsPerYear) * 100,
    closedTrades: closed.length, exposurePct: invested.length === 0 ? 0 : invested.filter(Boolean).length / invested.length * 100,
    feesPaid: Rounding.money(fees),
  };
  if (years >= 0.25 && first.equity > 0 && last.equity > 0) result.cagrPct = (Math.pow(last.equity / first.equity, 1 / years) - 1) * 100;
  if (enough && stdev > 1e-12) result.sharpe = (mean - riskFreePerPeriod) / stdev * Math.sqrt(periodsPerYear);
  if (enough && downsideDeviation > 1e-12) result.sortino = (mean - riskFreePerPeriod) / downsideDeviation * Math.sqrt(periodsPerYear);
  if (closed.length > 0) result.winRatePct = wins.length / closed.length * 100;
  if (grossLoss > 0) result.profitFactor = grossProfit / grossLoss;
  if (wins.length > 0) result.averageWinPct = wins.reduce((sum, t) => sum + t.pnlPct, 0) / wins.length;
  if (losses.length > 0) result.averageLossPct = losses.reduce((sum, t) => sum + t.pnlPct, 0) / losses.length;
  return result;
}

export const Backtester = { run, yearsBetween, metrics };
