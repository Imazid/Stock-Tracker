// Mirrors TradingCore/Tests/TradingCoreTests/BacktesterTests.swift.
// Run: npx -y deno test --allow-read supabase/functions/tests/studio_*.test.ts

import { assert, assertAlmostEquals, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  backtestConfigForAgent, type BacktestConfig, BacktestError, Backtester, type BacktestTrade, makeBacktestConfig,
} from "../_shared/studio/mod.ts";
import { defaultPaperConfig } from "../_shared/trading/broker.ts";
import { type BarSeries, instrumentID, marketProvenance, syntheticProvenance, usETF } from "../_shared/trading/market.ts";
import * as Rounding from "../_shared/trading/rounding.ts";
import { makeDraft } from "../_shared/trading/state.ts";
import type { StrategySpec } from "../_shared/trading/strategy.ts";
import * as Templates from "../_shared/trading/templates.ts";
import { Fx } from "./fixtures.ts";

const config = makeBacktestConfig({ startingCash: 10_000, slippageBps: 5, maxPositionPct: 10, allowFixtureData: true });
const DAY = 86_400_000;

function run(spec: StrategySpec, series: BarSeries[], benchmark?: BarSeries, settings: BacktestConfig = config) {
  return Backtester.run(spec, Object.fromEntries(series.map((s) => [instrumentID(s.instrument), s])), settings, Fx.now, benchmark);
}

function wave(count = 240, phase = 0): number[] {
  return Array.from({ length: count }, (_, i) => 100 + Math.sin(i / 9 + phase) * 14 + i * 0.03);
}

Deno.test("synthetic and unapproved fixture data are refused", () => {
  const spec = Fx.aboveAverageSpec([Fx.aapl]);
  const synthetic = Fx.series(Fx.aapl, wave(), { provenance: syntheticProvenance });
  const error = assertThrows(() => run(spec, [synthetic]), BacktestError);
  assertEquals([error.kind, error.symbol], ["notRealData", "AAPL"]);
  const strict = { ...config, allowFixtureData: false };
  const fixtureError = assertThrows(() => run(spec, [Fx.series(Fx.aapl, wave())], undefined, strict), BacktestError);
  assertEquals([fixtureError.kind, fixtureError.symbol], ["notRealData", "AAPL"]);
  assertThrows(() => run(spec, [Fx.series(Fx.aapl, wave())], Fx.series(Fx.spy, wave(), { provenance: syntheticProvenance })), BacktestError);
});

Deno.test("a result says whether its data was real", () => {
  const spec = Fx.aboveAverageSpec([Fx.aapl]);
  assertEquals(run(spec, [Fx.series(Fx.aapl, wave())]).usedRealMarketData, false);
  const real = run(spec, [Fx.series(Fx.aapl, wave(), { provenance: marketProvenance("Alpaca (IEX)") })]);
  assertEquals(real.usedRealMarketData, true);
  assertEquals(real.dataSources, ["Alpaca (IEX)"]);
});

Deno.test("a signal on one bar trades at the next bar's open", () => {
  const closes = [...Array(30).fill(100), 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, ...Array(20).fill(119)];
  const series = Fx.series(Fx.aapl, closes);
  const result = run(Fx.aboveAverageSpec([Fx.aapl]), [series]);
  const trade = result.trades[0];
  assert(trade);
  assertEquals(trade.entryTime, series.bars[31].time);
  assertAlmostEquals(trade.entryPrice, series.bars[31].open * 1.0005, 1e-9);
  assertEquals(series.bars[31].open, 110);
  assertEquals(trade.quantity, Rounding.floor(1_000 / trade.entryPrice, 0.000_001));
});

Deno.test("trades do not depend on later data", () => {
  const closes = wave(240);
  const days = Fx.usTradingDays(closes.length);
  const spec = Fx.aboveAverageSpec([Fx.aapl]);
  const full = run(spec, [Fx.series(Fx.aapl, closes, { days })]);
  const cut = 150;
  const partial = run(spec, [Fx.series(Fx.aapl, closes.slice(0, cut), { days: days.slice(0, cut) })]);
  const cutoff = days[cut - 1];
  const finishedInFull = full.trades.filter((t) => (t.exitTime ?? Infinity) <= cutoff);
  const finishedInPartial = partial.trades.filter((t) => !t.isOpen);
  assert(finishedInFull.length > 2);
  assertEquals(finishedInFull.length, finishedInPartial.length);
  for (let i = 0; i < finishedInFull.length; i++) {
    const a = finishedInFull[i], b = finishedInPartial[i];
    assertEquals([a.entryTime, a.entryPrice, a.exitTime, a.exitPrice, a.pnl], [b.entryTime, b.entryPrice, b.exitTime, b.exitPrice, b.pnl]);
  }
  assertEquals(full.equityCurve.slice(0, cut), partial.equityCurve);
});

Deno.test("fees and slippage only ever cost", () => {
  const series = Fx.series(Fx.btc, wave(240).map((x) => x * 600));
  const spec = Fx.aboveAverageSpec([Fx.btc]);
  const costless = run(spec, [series], undefined, { ...config, slippageBps: 0, cryptoFeeBps: 0 });
  const costly = run(spec, [series]);
  assertEquals(costless.overall.feesPaid, 0);
  assert(costly.overall.feesPaid > 0);
  assert(costly.overall.endEquity < costless.overall.endEquity);
  assertEquals(costly.trades.length, costless.trades.length);
});

Deno.test("metrics on a known curve", () => {
  const t0 = Fx.date("2025-01-01T00:00:00Z");
  const curve = [100, 110, 99, 120].map((equity, i) => ({ time: t0 + i * DAY, equity, cash: 0 }));
  const metrics = Backtester.metrics(curve, [true, true, false, true], [], 0, config);
  assertAlmostEquals(metrics.totalReturnPct, 20, 1e-9);
  assertAlmostEquals(metrics.maxDrawdownPct, 10, 1e-9);
  assertEquals(metrics.exposurePct, 75);
  assertEquals([metrics.cagrPct, metrics.sharpe, metrics.winRatePct], [undefined, undefined, undefined]);
});

Deno.test("trade statistics reconcile with account profit", () => {
  const result = run(Fx.aboveAverageSpec([Fx.aapl]), [Fx.series(Fx.aapl, wave(240))]);
  const closed = result.trades.filter((t) => !t.isOpen);
  assertEquals(result.overall.closedTrades, closed.length);
  const wins = closed.filter((t) => t.pnl > 0);
  assert(result.overall.winRatePct !== undefined);
  assertAlmostEquals(result.overall.winRatePct, wins.length / closed.length * 100, 1e-9);
  const total = result.trades.reduce((sum, t) => sum + t.pnl, 0);
  assertAlmostEquals(result.overall.endEquity - 10_000, total, 0.05);
  assert(closed.every((t) => (t.exitTime ?? -Infinity) > t.entryTime));
  assert(result.warnings.some((s) => s.includes("too few to judge")));
  assert(result.assumptions.some((s) => s.includes("next bar's open")));
  assert(result.assumptions.some((s) => s.includes("do not predict future returns")));
});

Deno.test("out-of-sample split and windows cover the period", () => {
  const result = run(Fx.aboveAverageSpec([Fx.aapl]), [Fx.series(Fx.aapl, wave(240))]);
  const { inSample, outOfSample } = result;
  assert(inSample && outOfSample);
  assertEquals(inSample.start, result.overall.start);
  assertEquals(outOfSample.end, result.overall.end);
  assertEquals(inSample.end, result.splitTime);
  assertEquals(outOfSample.start, result.splitTime);
  assertEquals(inSample.bars + outOfSample.bars, result.overall.bars + 1);
  assertEquals(inSample.closedTrades + outOfSample.closedTrades, result.overall.closedTrades);
  const compounded = (1 + inSample.totalReturnPct / 100) * (1 + outOfSample.totalReturnPct / 100) - 1;
  assertAlmostEquals(compounded * 100, result.overall.totalReturnPct, 1e-6);
  assertEquals(result.windows.length, 4);
  assertEquals(result.windows.map((w) => w.id), [1, 2, 3, 4]);
  assertEquals(Object.keys(result.windows[0]), ["index", "metrics"]);
  assertEquals(result.windows[0].metrics.start, result.overall.start);
  assertEquals(result.windows.at(-1)?.metrics.end, result.overall.end);
});

Deno.test("benchmark is buy and hold over the same dates", () => {
  const closes = wave(240);
  const result = run(Fx.aboveAverageSpec([Fx.aapl]), [Fx.series(Fx.aapl, closes)], Fx.series(Fx.spy, closes));
  assertEquals(result.benchmarkCurve.length, result.equityCurve.length);
  assertEquals(result.benchmarkCurve[0].equity, 10_000);
  assert(result.benchmarkReturnPct !== undefined);
  assertAlmostEquals(result.benchmarkReturnPct, (closes.at(-1)! / closes[0] - 1) * 100, 0.01);
  assertEquals(result.benchmarkName, "SPY buy and hold");
});

Deno.test("position limits hold in a backtest", () => {
  const universe = [Fx.aapl, Fx.msft, Fx.spy];
  const series = universe.map((instrument, i) => Fx.series(instrument, wave(160, i * 0.1)));
  const limited = { ...config, maxOpenPositions: 2, maxPositionPct: 25 };
  const spec = Fx.aboveAverageSpec(universe);
  spec.sizing = { mode: "percentOfEquity", value: 25 };
  const result = run(spec, series, undefined, limited);
  const events = result.trades.flatMap((t) => [[t.entryTime, 1], [t.exitTime ?? Infinity, -1]])
    .sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  let open = 0, peak = 0;
  for (const [, change] of events) { open += change; peak = Math.max(peak, open); }
  assertEquals(peak, 2);
  assert(result.equityCurve.every((p) => p.cash >= -0.005));
  assert(result.trades.every((t) => t.quantity * t.entryPrice <= 10_000 * 0.25 * 1.5));
});

Deno.test("scheduled buys run on their interval", () => {
  const series = Fx.series(Fx.spy, Array(30).fill(400));
  const free = { ...config, slippageBps: 0, maxPositionPct: 100 };
  const result = run(Templates.dollarCostAveraging([Fx.spy], 100, 5), [series], undefined, free);
  assertAlmostEquals(result.equityCurve.at(-1)!.cash, 9_400, 0.05);
  assertEquals(result.trades.length, 1);
  assert(result.trades[0].isOpen);
  assertAlmostEquals(result.overall.endEquity, 10_000, 0.05);
});

Deno.test("rebalancing sells what rose and buys what did not", () => {
  const rising = Array.from({ length: 120 }, (_, i) => 100 + i * 1.2);
  const flat = Array(120).fill(100);
  const a = usETF("VTI"), b = usETF("BND");
  const spec = Templates.etfRebalancing([a, b]);
  spec.rebalance = { targets: { [instrumentID(a)]: 50, [instrumentID(b)]: 50 }, driftThresholdPct: 5 };
  const result = run(spec, [Fx.series(a, rising), Fx.series(b, flat)], undefined, { ...config, maxPositionPct: 100 });
  const sells = result.trades.filter((t) => !t.isOpen);
  assert(sells.length > 0);
  assert(sells.every((t) => instrumentID(t.instrument) === instrumentID(a) && t.exitReason === "rebalance" && t.pnl > 0));
  assert(result.overall.totalReturnPct > 0);
  assert(result.overall.totalReturnPct < (rising.at(-1)! / rising[0] - 1) * 100);
});

Deno.test("things that cannot be backtested say so", () => {
  assertThrows(() => run(Templates.portfolioResearch([Fx.aapl]), [Fx.series(Fx.aapl, wave())]), BacktestError);
  assertThrows(() => run(Templates.riskManager(), []), BacktestError);
  const error = assertThrows(() => run(Fx.aboveAverageSpec([Fx.aapl]), [Fx.series(Fx.aapl, wave(30))]), BacktestError);
  assertEquals([error.kind, error.needed, error.available], ["insufficientHistory", 40, 30]);
  assertEquals(assertThrows(() => run(Fx.aboveAverageSpec([Fx.aapl]), []), BacktestError).kind, "noData");
});

Deno.test("backtest limits come from the agent's own policy", () => {
  const draft = makeDraft({ name: "A", spec: Fx.aboveAverageSpec([Fx.btc]), budget: 5_000, maxPositionPct: 20 });
  const settings = backtestConfigForAgent(draft);
  assertEquals(settings.startingCash, 5_000);
  assertEquals(settings.maxPositionPct, 20);
  assertEquals(settings.maxOrderNotional, 1_000);
  assertEquals(settings.cryptoFeeBps, defaultPaperConfig().cryptoFeeBps);
  assertEquals(settings.allowFixtureData, false);
});

// Additional coverage for the formulas, completed-bar boundary, and deterministic IDs.
Deno.test("metrics annualise sample deviation and all-period downside with risk-free returns", () => {
  const t0 = Fx.date("2025-01-01T00:00:00Z");
  // Twenty 10% / -10% periods over exactly a year: mean 0, sample variance .2/19.
  const curve = [{ time: t0, equity: 100, cash: 0 }];
  for (let i = 1; i <= 20; i++) curve.push({ time: t0 + i * 365.25 * DAY / 20,
    equity: curve[i - 1].equity * (i % 2 === 1 ? 1.1 : 0.9), cash: 0 });
  const settings = { ...config, riskFreeRatePct: 4 };
  const metrics = Backtester.metrics(curve, Array(21).fill(true), [], 1.235, settings);
  const sampleDeviation = Math.sqrt(0.2 / 19);
  assertAlmostEquals(metrics.volatilityPct, sampleDeviation * Math.sqrt(20) * 100, 1e-9);
  assertAlmostEquals(metrics.sharpe!, -0.002 / sampleDeviation * Math.sqrt(20), 1e-9);
  assertAlmostEquals(metrics.sortino!, -0.002 / Math.sqrt(10 * 0.102 ** 2 / 20) * Math.sqrt(20), 1e-9);
  assertAlmostEquals(metrics.cagrPct!, (Math.pow(0.99, 10) - 1) * 100, 1e-9);
  assertEquals(metrics.feesPaid, 1.24);
});

Deno.test("trade metrics count exit boundaries, breakevens, wins and losses exactly", () => {
  const curve = [{ time: 1, equity: 100, cash: 0 }, { time: 3, equity: 100, cash: 0 }];
  const trade = (pnl: number, pnlPct: number, exitTime: number, isOpen = false): BacktestTrade => ({
    id: String(pnl), instrument: Fx.aapl, entryTime: 0, entryPrice: 10, quantity: 1, exitTime, pnl, pnlPct, barsHeld: 1, isOpen,
  });
  const trades = [trade(100, 10, 2), trade(-50, -5, 3), trade(0, 0, 3), trade(10_000, 1_000, 1), trade(10_000, 1_000, 4), trade(10_000, 1_000, 2, true)];
  const metrics = Backtester.metrics(curve, [false, true], trades, 0, config);
  assertEquals(metrics.closedTrades, 3);
  assertAlmostEquals(metrics.winRatePct!, 100 / 3, 1e-9);
  assertEquals([metrics.profitFactor, metrics.averageWinPct, metrics.averageLossPct, metrics.exposurePct], [2, 10, -5, 50]);
  assertEquals(Backtester.metrics(curve, [], [trades[0]], 0, config).profitFactor, undefined);
  const empty = Backtester.metrics([], [], [], 0, config);
  assertEquals([empty.start, empty.end, empty.bars, empty.startEquity, empty.endEquity, empty.exposurePct], [0, 0, 0, 10_000, 10_000, 0]);
  assertEquals(Backtester.yearsBetween(1, 1), undefined);
});

Deno.test("unfinished bars cannot produce signals or fills, and repeated runs are identical", () => {
  const closes = [...Array(40).fill(100), ...Array.from({ length: 30 }, (_, i) => 110 + i)];
  const series = Fx.series(Fx.btc, closes);
  const spec = Fx.aboveAverageSpec([Fx.btc]);
  const input = { [instrumentID(Fx.btc)]: series };
  const asOf = series.bars[41].time + DAY / 2;
  const original = JSON.stringify({ spec, series, config });
  const result = Backtester.run(spec, input, config, asOf);
  assertEquals(result.equityCurve.length, 41);
  assertEquals(result.trades, []);
  const later = series.bars[42].time + DAY / 2;
  const filled = Backtester.run(spec, input, config, later);
  assertEquals(filled.trades[0].entryTime, series.bars[41].time);
  assertEquals(filled, Backtester.run(spec, input, config, later));
  assertEquals(new Set(filled.trades.map((t) => t.id)).size, filled.trades.length);
  assertEquals(JSON.stringify({ spec, series, config }), original);
});
