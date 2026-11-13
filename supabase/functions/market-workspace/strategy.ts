import { Backtester, BacktestError, makeBacktestConfig } from "../_shared/studio/backtester.ts";
import type { BarSeries, Instrument } from "../_shared/trading/market.ts";
import { instrumentID } from "../_shared/trading/market.ts";
import { makeSpec, Op, Rule, type StrategySpec } from "../_shared/trading/strategy.ts";
import { breakout, meanReversion, momentum, movingAverageCrossover } from "../_shared/trading/templates.ts";
import { HttpError } from "../_shared/server/http.ts";

export function prepareStrategy(rule: string, instrument: Instrument): StrategySpec {
  const text = rule.toLowerCase().trim();
  const average = /^(?:buy when (?:the )?)?price (crosses|closes) above (?:its |the )?(\d{1,3})[- ]day (?:moving average|sma)(?:,? (?:and )?sell when (?:it )?(crosses|closes|falls) below(?: it)?)?\.?$/.exec(text);
  if (average) {
    const period = Number(average[2]);
    if (period < 2 || period > 400) throw new HttpError(422, "invalid_period", "Use a moving average between 2 and 400 days.");
    const crossing = average[1] === "crosses";
    const crossingExit = average[3] ? average[3] === "crosses" : crossing;
    return makeSpec({
      kind: "rules", title: `${period}-day moving average`, summary: rule,
      universe: [instrument],
      entry: crossing ? Rule.crossesAbove(Op.close, Op.sma(period)) : Rule.above(Op.close, Op.sma(period)),
      exit: crossingExit ? Rule.crossesBelow(Op.close, Op.sma(period)) : Rule.below(Op.close, Op.sma(period)),
      sizing: { mode: "percentOfEquity", value: 10 },
    });
  }
  if (text === "momentum") return momentum([instrument]);
  if (text === "mean reversion") return meanReversion([instrument]);
  if (text === "breakout") return breakout([instrument]);
  if (text === "moving average crossover") return movingAverageCrossover([instrument]);
  throw new HttpError(422, "unsupported_rule", "Choose a strategy template or enter a supported moving-average rule.");
}

export function runHistory(spec: StrategySpec, history: BarSeries, startingCash: number, now: number) {
  try {
    const config = makeBacktestConfig({ startingCash });
    const result = Backtester.run(spec, { [instrumentID(history.instrument)]: history }, config, now, history);
    return {
      points: result.equityCurve.map(({ time, equity }) => ({ time, value: equity })),
      endingValue: result.overall.endEquity,
      returnPct: result.overall.totalReturnPct,
      benchmarkPct: result.benchmarkReturnPct ?? null,
      maxDrawdown: result.overall.maxDrawdownPct,
      tradeCount: result.trades.length,
      sessions: result.overall.bars,
      assumptions: result.assumptions,
      warnings: result.warnings,
    };
  } catch (error) {
    if (error instanceof BacktestError) throw new HttpError(422, error.kind, error.message);
    throw error;
  }
}
