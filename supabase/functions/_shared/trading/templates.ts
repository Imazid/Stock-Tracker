// Ready-made strategies a person can start from and then change. A port of
// `AgentTemplates` in TradingCore/Sources/TradingCore/Templates.swift (the specs only —
// names, icons and default lists are the app's business).

import { type Instrument, instrumentID } from "./market.ts";
import * as Rounding from "./rounding.ts";
import { makeSpec, Op, type Operand, Rule, type StrategySpec } from "./strategy.ts";

export function momentum(universe: Instrument[]): StrategySpec {
  return makeSpec({
    kind: "rules", title: "Momentum",
    summary: "Buys assets that are rising and above their 50-day average, and steps aside when the rise fades.",
    universe,
    entry: Rule.all([Rule.above(Op.close, Op.sma(50)), Rule.above(Op.rateOfChange(20), Op.constant(3)), Rule.below(Op.rsi(14), Op.constant(75))]),
    exit: Rule.any([Rule.below(Op.close, Op.sma(50)), Rule.below(Op.rateOfChange(20), Op.constant(-3))]),
    protections: { stopLossPct: 8, trailingStopPct: 10 },
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 3,
  });
}

export function trendFollowing(universe: Instrument[]): StrategySpec {
  return makeSpec({
    kind: "rules", title: "Trend following",
    summary: "Holds assets while their 20-day average is above their 50-day average.",
    universe,
    entry: Rule.all([Rule.above(Op.sma(20), Op.sma(50)), Rule.above(Op.close, Op.sma(20))]),
    exit: Rule.below(Op.sma(20), Op.sma(50)),
    protections: { stopLossPct: 10 },
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 3,
  });
}

/** Buys on the bar a fast average crosses above a slow one, and sells on the cross back. */
export function movingAverageCrossover(universe: Instrument[], fast = 20, slow = 50, exponential = false): StrategySpec {
  const f: Operand = exponential ? Op.ema(fast) : Op.sma(fast);
  const s: Operand = exponential ? Op.ema(slow) : Op.sma(slow);
  return makeSpec({
    kind: "rules", title: "Moving-average crossover",
    summary: `Buys when the ${fast}-day average crosses above the ${slow}-day average and sells when it crosses back below.`,
    universe,
    entry: Rule.crossesAbove(f, s),
    exit: Rule.crossesBelow(f, s),
    protections: { stopLossPct: 10 },
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 1,
  });
}

export function meanReversion(universe: Instrument[]): StrategySpec {
  return makeSpec({
    kind: "rules", title: "Mean reversion",
    summary: "Buys sharp dips (RSI under 30 and below the lower Bollinger band) and sells when price recovers to its average.",
    universe,
    entry: Rule.all([Rule.below(Op.rsi(14), Op.constant(30)), Rule.below(Op.close, Op.bollingerLower(20, 2))]),
    exit: Rule.any([Rule.above(Op.rsi(14), Op.constant(55)), Rule.above(Op.close, Op.bollingerMiddle(20))]),
    protections: { stopLossPct: 6, maxHoldingBars: 15 },
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 2,
  });
}

export function breakout(universe: Instrument[]): StrategySpec {
  return makeSpec({
    kind: "rules", title: "Breakout",
    summary: "Buys a close above the prior 20-day high on above-average volume, and sells a close below the prior 10-day low.",
    universe,
    entry: Rule.all([Rule.above(Op.close, Op.highest(20)), Rule.above(Op.volume, Op.scaled(Op.volumeAverage(20), 1.2))]),
    exit: Rule.below(Op.close, Op.lowest(10)),
    protections: { stopLossPct: 7 },
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 3,
  });
}

export function dollarCostAveraging(universe: Instrument[], amountPerBuy = 100, intervalBars = 5): StrategySpec {
  return makeSpec({
    kind: "dca", title: "Dollar-cost averaging",
    summary: "Buys a fixed amount of each asset on a regular schedule, whatever the price.",
    universe,
    sizing: { mode: "fixedNotional", value: amountPerBuy },
    dca: { amountPerBuy, intervalBars }, reentryCooldownBars: 0,
  });
}

export function etfRebalancing(universe: Instrument[]): StrategySpec {
  // Default mix for the three balanced ETFs; any other list is split evenly.
  const targets: Record<string, number> = {};
  const symbols = universe.map((instrument) => instrument.symbol);
  if (symbols.length === 3 && symbols[0] === "VTI" && symbols[1] === "VXUS" && symbols[2] === "BND") {
    targets["us:VTI"] = 60;
    targets["us:VXUS"] = 20;
    targets["us:BND"] = 20;
  } else if (universe.length > 0) {
    const each = Rounding.round(100 / universe.length, 2);
    for (const instrument of universe) targets[instrumentID(instrument)] = Math.min(each, 100);
    // Keep the total at or under 100 after rounding. (Swift sums a dictionary here; the
    // order of that sum isn't fixed, so a total within a rounding error of 100 could differ.)
    let total = 0;
    for (const instrument of universe) total += targets[instrumentID(instrument)];
    if (total > 100) targets[instrumentID(universe[0])] = each - (total - 100);
  }
  return makeSpec({
    kind: "rebalance", title: "ETF rebalancing",
    summary: "Keeps a fixed mix of funds, trading back to target when one drifts.",
    universe,
    sizing: { mode: "percentOfEquity", value: 100 },
    rebalance: { targets, driftThresholdPct: 5 }, reentryCooldownBars: 0,
  });
}

export function cryptoMonitor(universe: Instrument[]): StrategySpec {
  return makeSpec({
    kind: "rules", title: "Crypto trend monitor",
    summary: "Watches crypto around the clock and signals when price is above a rising 21-day average.",
    universe,
    entry: Rule.all([Rule.above(Op.close, Op.ema(21)), Rule.above(Op.ema(21), Op.ema(55))]),
    exit: Rule.below(Op.close, Op.ema(55)),
    protections: { stopLossPct: 10, trailingStopPct: 15 },
    sizing: { mode: "percentOfEquity", value: 20 }, reentryCooldownBars: 2,
  });
}

export function riskManager(): StrategySpec {
  return makeSpec({
    kind: "rules", title: "Risk manager",
    summary: "Guards a portfolio's open positions with a stop loss and a trailing stop. It never opens a position.",
    universe: [],
    protections: { stopLossPct: 8, trailingStopPct: 12 },
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 0,
    followsLedgerPositions: true,
  });
}

export function portfolioResearch(universe: Instrument[]): StrategySpec {
  return makeSpec({
    kind: "research", title: "Portfolio research",
    summary: "Reports trend, momentum and volatility facts for the assets you follow. It never trades.",
    universe,
    sizing: { mode: "percentOfEquity", value: 10 }, reentryCooldownBars: 0,
  });
}
