// Runs the shared, deterministic backtester (supabase/functions/_shared/studio, a parity port
// of TradingCore/Backtester.swift) on real history. Nothing here reads the clock except the
// caller's choice of `asOf`; the same spec, config, window, data and asOf give the same
// result, and the response carries everything needed to say exactly what was run.

import { type BarSeries, decodeInstrument, instrumentID, type Instrument } from "@engine/market.ts";
import { decodeStrategySpec, type StrategySpec } from "@engine/strategy.ts";
import { completedBars } from "@engine/calendar.ts";
import { BacktestError, type BacktestConfig, type BacktestResult, Backtester, makeBacktestConfig } from "@studio/backtester.ts";
import { datasetReference, type DatasetReference, history, HISTORY_WINDOWS, HistoryError, type HistoryWindow } from "@/server/market/history";

export const ENGINE_VERSION = "studio/backtester.ts — TradingCore Backtester.swift parity port (2026-11-13)";

export interface BacktestInputs {
  spec: StrategySpec;
  config: BacktestConfig;
  window: HistoryWindow;
  benchmark?: string;
  asOf: number;
}

export interface BacktestResponse {
  result: BacktestResult;
  inputs: BacktestInputs;
  datasets: DatasetReference[];
  benchmarkDataset?: DatasetReference;
  failures: { instrumentId: string; reasons: string[] }[];
  engine: string;
  ranAt: string;
  /** Candles of the first tested instrument, for the entry/exit chart (ms times). */
  chart?: { instrumentId: string; bars: { time: number; open: number; high: number; low: number; close: number; volume: number }[] };
}

export class BacktestRequestError extends Error {
  constructor(readonly code: string, message: string, readonly status = 422, readonly details?: Record<string, unknown>) {
    super(message);
  }
}

function num(raw: unknown, name: string, min: number, max: number, fallback: number): number {
  if (raw === undefined || raw === null || raw === "") return fallback;
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n) || n < min || n > max) throw new BacktestRequestError("invalid", `${name} must be between ${min} and ${max}.`);
  return n;
}

export function decodeInputs(body: Record<string, unknown>, now: number): BacktestInputs {
  let spec: StrategySpec;
  try {
    spec = decodeStrategySpec(body.spec);
  } catch (error) {
    throw new BacktestRequestError("invalid", error instanceof Error ? error.message : "The strategy couldn't be read.");
  }
  const c = (typeof body.config === "object" && body.config !== null ? body.config : {}) as Record<string, unknown>;
  const startingCash = num(c.startingCash, "Starting cash", 100, 100_000_000, 10_000);
  const config = makeBacktestConfig({
    startingCash,
    slippageBps: num(c.slippageBps, "Slippage", 0, 500, 5),
    equityFeePerOrder: num(c.equityFeePerOrder, "Fee per order", 0, 1_000, 0),
    equityFeeBps: num(c.equityFeeBps, "Equity fee", 0, 500, 0),
    cryptoFeeBps: num(c.cryptoFeeBps, "Crypto fee", 0, 500, 25),
    maxOrderNotional: num(c.maxOrderNotional, "Max order", 1, 100_000_000, startingCash),
    maxPositionPct: num(c.maxPositionPct, "Max position", 1, 100, 10),
    maxOpenPositions: Math.round(num(c.maxOpenPositions, "Max open positions", 1, 100, 10)),
    outOfSampleFraction: num(c.outOfSampleFraction, "Out-of-sample share", 0, 0.9, 0.3),
    riskFreeRatePct: num(c.riskFreeRatePct, "Risk-free rate", 0, 20, 0),
    // Fixture (test) data is never allowed through this route.
    allowFixtureData: false,
  });
  const window = (typeof body.window === "string" ? body.window : "2y") as HistoryWindow;
  if (!HISTORY_WINDOWS.includes(window)) throw new BacktestRequestError("invalid", `window must be one of ${HISTORY_WINDOWS.join(", ")}.`);
  const asOf = body.asOf === undefined || body.asOf === null ? now : num(body.asOf, "asOf", Date.UTC(2000, 0, 1), now + 60_000, now);
  const benchmark = typeof body.benchmark === "string" && body.benchmark !== "" ? body.benchmark : undefined;
  return { spec, config, window, benchmark, asOf };
}

async function inBatches<T, R>(items: T[], size: number, fn: (item: T) => Promise<R>): Promise<PromiseSettledResult<R>[]> {
  const out: PromiseSettledResult<R>[] = [];
  for (let i = 0; i < items.length; i += size) out.push(...(await Promise.allSettled(items.slice(i, i + size).map(fn))));
  return out;
}

export async function runBacktest(inputs: BacktestInputs, now: number): Promise<BacktestResponse> {
  const { spec, config, window, asOf } = inputs;
  const universe: Instrument[] = spec.universe;
  const settled = await inBatches(universe, 4, (instrument) => history(instrument, spec.timeframe, window, asOf, now));
  const series: Record<string, BarSeries> = {};
  const datasets: DatasetReference[] = [];
  const failures: BacktestResponse["failures"] = [];
  settled.forEach((s, i) => {
    const id = instrumentID(universe[i]);
    if (s.status === "fulfilled") {
      const completed = completedBars(s.value, asOf);
      if (completed.length) {
        series[id] = { ...s.value, bars: completed };
        datasets.push(datasetReference(series[id], window));
      } else {
        failures.push({ instrumentId: id, reasons: ["No completed bars by the selected time"] });
      }
    } else {
      failures.push({ instrumentId: id, reasons: s.reason instanceof HistoryError ? s.reason.reasons : ["The history request failed"] });
    }
  });

  let benchmarkSeries: BarSeries | undefined;
  let benchmarkDataset: DatasetReference | undefined;
  if (inputs.benchmark) {
    const [venue, symbol] = inputs.benchmark.split(":");
    try {
      const instrument = decodeInstrument({ symbol, venue });
      const h = await history(instrument, spec.timeframe, window, asOf, now);
      const bars = completedBars(h, asOf);
      if (!bars.length) throw new HistoryError(inputs.benchmark, ["No completed benchmark bars by the selected time"]);
      benchmarkSeries = { ...h, bars };
      benchmarkDataset = datasetReference(benchmarkSeries, window);
    } catch (error) {
      failures.push({ instrumentId: inputs.benchmark, reasons: error instanceof HistoryError ? error.reasons : ["The benchmark couldn't be loaded"] });
    }
  }

  let result: BacktestResult;
  try {
    result = Backtester.run(spec, series, config, asOf, benchmarkSeries);
  } catch (error) {
    if (error instanceof BacktestError) {
      throw new BacktestRequestError(error.kind, error.message, 422, { failures });
    }
    throw error;
  }
  const first = universe.map(instrumentID).find((id) => series[id]);
  return {
    result, inputs, datasets, benchmarkDataset, failures, engine: ENGINE_VERSION, ranAt: new Date(now).toISOString(),
    chart: first ? { instrumentId: first, bars: series[first].bars } : undefined,
  };
}
