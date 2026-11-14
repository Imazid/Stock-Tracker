"use client";

import { ruleLines, type StrategySpec } from "@engine/strategy.ts";
import type { BacktestMetrics } from "@studio/backtester.ts";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { FlaskConical, Play, RotateCcw } from "lucide-react";
import { useMemo, useState } from "react";
import { DEFAULT_INDICATORS, EquityChart, PriceChart } from "@/components/market/PriceChart";
import { backtestFingerprint, type BacktestArchive } from "@/lib/backtest-archive";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";
import { uuid } from "@/lib/uuid";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { ApiError } from "@/lib/api";
import { dateTime, money, percent, plainNumber } from "@/lib/format";
import type { BacktestResponse } from "@/server/strategy/backtest";

interface Settings {
  startingCash: number;
  window: "1y" | "2y" | "5y" | "10y";
  slippageBps: number;
  equityFeePerOrder: number;
  equityFeeBps: number;
  cryptoFeeBps: number;
  maxPositionPct: number;
  maxOpenPositions: number;
  outOfSampleFraction: number;
  benchmark: string;
}

const DEFAULTS: Settings = { startingCash: 10_000, window: "2y", slippageBps: 5, equityFeePerOrder: 0, equityFeeBps: 0, cryptoFeeBps: 25, maxPositionPct: 10, maxOpenPositions: 10, outOfSampleFraction: 0.3, benchmark: "" };

const BENCHMARKS = [
  { value: "", label: "None" }, { value: "us:SPY", label: "S&P 500 ETF (SPY)" }, { value: "us:QQQ", label: "Nasdaq-100 ETF (QQQ)" },
  { value: "asx:IOZ", label: "ASX 200 ETF (IOZ)" }, { value: "crypto:BTC", label: "Bitcoin (BTC)" },
];

async function post(body: unknown): Promise<BacktestResponse> {
  const response = await fetch("/api/backtests", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const json = (await response.json().catch(() => undefined)) as (BacktestResponse & { error?: { code: string; message: string; details?: Record<string, unknown> } }) | undefined;
  if (!response.ok || !json || json.error) throw new ApiError(json?.error?.code ?? "http_error", json?.error?.message ?? `Backtest failed (${response.status})`, response.status, json?.error?.details);
  return json;
}

const EXIT_REASON: Record<string, string> = {
  rule: "Exit rule", stopLoss: "Stop loss", takeProfit: "Take profit", trailingStop: "Trailing stop", timeLimit: "Max holding time",
  rebalance: "Rebalance", entry: "Entry", scheduled: "Scheduled buy",
};
const exitText = (reason: string | undefined) => (reason ? EXIT_REASON[reason] ?? reason : undefined);

function Metric({ label, value, tone }: { label: string; value: string; tone?: "up" | "down" }) {
  return (
    <div className="rounded-lg border border-border bg-surface-2/50 px-3 py-2">
      <p className="text-[11px] text-text-3">{label}</p>
      <p className={`tabular text-sm font-semibold ${tone === "up" ? "text-up" : tone === "down" ? "text-down" : "text-text"}`}>{value}</p>
    </div>
  );
}

function MetricsGrid({ m, currency }: { m: BacktestMetrics; currency: string }) {
  const tone = (x: number | undefined) => (x === undefined ? undefined : x > 0 ? "up" : x < 0 ? "down" : undefined);
  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 xl:grid-cols-4">
      <Metric label="Total return" value={percent(m.totalReturnPct)} tone={tone(m.totalReturnPct)} />
      <Metric label="Annualised (CAGR)" value={m.cagrPct === undefined ? "— (under 1 year)" : percent(m.cagrPct)} tone={tone(m.cagrPct)} />
      <Metric label="Max drawdown" value={percent(-m.maxDrawdownPct)} tone={m.maxDrawdownPct > 0 ? "down" : undefined} />
      <Metric label="Volatility (annual)" value={percent(m.volatilityPct, { signed: false })} />
      <Metric label="Sharpe" value={m.sharpe === undefined ? "—" : plainNumber(m.sharpe, 2)} />
      <Metric label="Sortino" value={m.sortino === undefined ? "—" : plainNumber(m.sortino, 2)} />
      <Metric label="Closed trades" value={String(m.closedTrades)} />
      <Metric label="Win rate" value={m.winRatePct === undefined ? "—" : percent(m.winRatePct, { signed: false })} />
      <Metric label="Profit factor" value={m.profitFactor === undefined ? "—" : plainNumber(m.profitFactor, 2)} />
      <Metric label="Average win" value={m.averageWinPct === undefined ? "—" : percent(m.averageWinPct)} tone={tone(m.averageWinPct)} />
      <Metric label="Average loss" value={m.averageLossPct === undefined ? "—" : percent(m.averageLossPct)} tone={tone(m.averageLossPct)} />
      <Metric label="Time invested" value={percent(m.exposurePct, { signed: false })} />
      <Metric label="Fees paid" value={money(m.feesPaid, currency)} />
      <Metric label="End equity" value={money(m.endEquity, currency)} />
      <Metric label="Bars tested" value={plainNumber(m.bars, 0)} />
      <Metric label="Period" value={`${new Date(m.start).toLocaleDateString("en-AU")} – ${new Date(m.end).toLocaleDateString("en-AU")}`} />
    </div>
  );
}

export function BacktestPanel({ spec, valid, capital, positionLimit }: {
  spec: StrategySpec; valid: boolean; capital?: number; positionLimit?: number;
}) {
  const [s, setS] = useState<Settings>(() => ({
    ...DEFAULTS, startingCash: capital ?? DEFAULTS.startingCash, maxPositionPct: positionLimit ?? DEFAULTS.maxPositionPct,
  }));
  const [completed, setCompleted] = useState<{ id: string; report: BacktestResponse; owner?: string } | null>(null);
  const session = useSession();
  const owner = session.status === "signedIn" ? session.user.id : undefined;
  const current = completed?.owner === owner ? completed : null;
  const last = current?.report ?? null;
  const cache = useQueryClient();
  const save = useMutation({
    mutationFn: async ({ id, report, owner }: { id: string; report: BacktestResponse; owner: string }) => {
      const db = browserSupabase();
      if (!db || (await db.auth.getUser()).data.user?.id !== owner) throw new Error("Sign in again to save this report.");
      const { chart, ...snapshot } = report;
      void chart;
      const archive: BacktestArchive = { ...snapshot, schemaVersion: 1, title: report.inputs.spec.title.trim().slice(0, 200) || "Backtest" };
      const { error } = await db.from("backtest_runs").upsert({ user_id: owner, id, report: archive }, { onConflict: "user_id,id", ignoreDuplicates: true });
      if (error) throw new Error(error.code === "23514" ? "This report is too large or could not be archived." : "The report could not be saved. Try again.");
    },
    onSuccess: (_, { owner }) => cache.invalidateQueries({ queryKey: ["backtest-runs", owner] }),
  });
  const [rerunMatch, setRerunMatch] = useState<boolean | null>(null);
  const currency = spec.universe[0]?.currency ?? "USD";
  const run = useMutation({
    mutationFn: (inputs?: BacktestResponse["inputs"]) => post(inputs ?? {
      spec, window: s.window, benchmark: s.benchmark || undefined,
      config: { startingCash: s.startingCash, slippageBps: s.slippageBps, equityFeePerOrder: s.equityFeePerOrder, equityFeeBps: s.equityFeeBps, cryptoFeeBps: s.cryptoFeeBps, maxPositionPct: s.maxPositionPct, maxOpenPositions: s.maxOpenPositions, outOfSampleFraction: s.outOfSampleFraction },
    }),
  });
  const set = <K extends keyof Settings>(k: K, v: Settings[K]) => setS((x) => ({ ...x, [k]: v }));

  const start = () => {
    setRerunMatch(null);
    save.reset();
    run.mutate(undefined, { onSuccess: (report) => setCompleted({ id: uuid(), report, owner }) });
  };
  const rerun = () => {
    if (!last) return;
    run.mutate(last.inputs, { onSuccess: (r) => setRerunMatch(backtestFingerprint(r.result) === backtestFingerprint(last.result)) });
  };


  return (
    <Card>
      <CardHeader title={<span className="inline-flex items-center gap-1.5"><FlaskConical aria-hidden className="h-4 w-4 text-primary-fg" />Backtest</span>}
        subtitle="Real historical prices only. Signals on completed bars; fills at the next bar's open with slippage and fees." />
      <div className="grid grid-cols-2 gap-3 border-t border-border px-4 py-3 md:grid-cols-4">
        <Field label={`Starting cash (${currency})`} htmlFor="bt-cash"><Input id="bt-cash" type="number" min={100} value={s.startingCash} onChange={(e) => set("startingCash", Number(e.target.value))} /></Field>
        <Field label="History" htmlFor="bt-window"><Select id="bt-window" value={s.window} onChange={(e) => set("window", e.target.value as Settings["window"])}>
          <option value="1y">1 year</option><option value="2y">2 years</option><option value="5y">5 years</option><option value="10y">10 years</option></Select></Field>
        <Field label="Benchmark" htmlFor="bt-bench"><Select id="bt-bench" value={s.benchmark} onChange={(e) => set("benchmark", e.target.value)}>{BENCHMARKS.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}</Select></Field>
        <Field label="Slippage (bps)" htmlFor="bt-slip"><Input id="bt-slip" type="number" min={0} value={s.slippageBps} onChange={(e) => set("slippageBps", Number(e.target.value))} /></Field>
        <Field label="Equity fee / order" htmlFor="bt-fee"><Input id="bt-fee" type="number" min={0} step={0.5} value={s.equityFeePerOrder} onChange={(e) => set("equityFeePerOrder", Number(e.target.value))} /></Field>
        <Field label="Equity fee (bps)" htmlFor="bt-feebps"><Input id="bt-feebps" type="number" min={0} value={s.equityFeeBps} onChange={(e) => set("equityFeeBps", Number(e.target.value))} /></Field>
        <Field label="Crypto fee (bps)" htmlFor="bt-cfee"><Input id="bt-cfee" type="number" min={0} value={s.cryptoFeeBps} onChange={(e) => set("cryptoFeeBps", Number(e.target.value))} /></Field>
        <Field label="Max position (%)" htmlFor="bt-pos"><Input id="bt-pos" type="number" min={1} max={100} value={s.maxPositionPct} onChange={(e) => set("maxPositionPct", Number(e.target.value))} /></Field>
        <Field label="Out-of-sample share" htmlFor="bt-oos" hint="Last part of history held back to check the rules on unseen data."><Input id="bt-oos" type="number" min={0} max={0.9} step={0.05} value={s.outOfSampleFraction} onChange={(e) => set("outOfSampleFraction", Number(e.target.value))} /></Field>
        <Field label="Max open positions" htmlFor="bt-open"><Input id="bt-open" type="number" min={1} max={100} value={s.maxOpenPositions} onChange={(e) => set("maxOpenPositions", Number(e.target.value))} /></Field>
      </div>
      <div className="flex flex-wrap items-center gap-2 border-t border-border px-4 py-3">
        <Button variant="primary" onClick={start} disabled={!valid || run.isPending || save.isPending}><Play className="h-4 w-4" />{run.isPending ? "Running…" : "Run backtest"}</Button>
        {last ? <Button onClick={rerun} disabled={run.isPending} title="Same strategy, settings and as-of time"><RotateCcw className="h-4 w-4" />Rerun saved inputs</Button> : null}
        {current && owner && <Button disabled={save.isPending || save.isSuccess} onClick={() => save.mutate({ id: current.id, report: current.report, owner })}>
          {save.isSuccess ? "Report saved" : save.isPending ? "Saving report…" : "Save report"}
        </Button>}
        {current && !owner && <a href="/login?next=/strategies" className="text-xs text-primary-fg underline">Sign in to save reports</a>}
        {!valid ? <span className="text-xs text-warn">Fix the strategy&apos;s errors first.</span> : null}
        {rerunMatch === true ? <Badge tone="up">Identical result ({backtestFingerprint(last!.result)})</Badge> : rerunMatch === false ? <Badge tone="down">Result differed from the original</Badge> : null}
      </div>
      {current && save.isError && <p role="status" className="px-4 pb-3 text-sm text-down">{save.error.message}</p>}
      {run.isError ? (
        <div className="px-4 pb-4"><Notice tone="down" title="The backtest didn't run">{(run.error as Error).message}
          {run.error instanceof ApiError && Array.isArray(run.error.details?.failures) ? <ul className="mt-1 list-disc pl-4 text-xs">{(run.error.details!.failures as { instrumentId: string; reasons: string[] }[]).map((f) => <li key={f.instrumentId}>{f.instrumentId}: {f.reasons.join("; ")}</li>)}</ul> : null}
        </Notice></div>
      ) : null}

      {last ? <BacktestReport last={last} /> : !run.isPending ? <EmptyState title="No backtest yet" body="Run it to see returns, drawdown, risk-adjusted metrics, every trade and the assumptions behind them." />
        : <div className="space-y-2 p-4"><div className="skeleton h-24" /><div className="skeleton h-48" /></div>}
    </Card>
  );
}

export function BacktestReport({ last }: { last: BacktestResponse }) {
  const r = last.result;
  const spec = last.inputs.spec;
  const currency = spec.universe[0]?.currency ?? "USD";
  const markers = useMemo(() => {
    if (!last?.chart || !r) return [];
    const out: { time: number; side: "buy" | "sell"; text?: string }[] = [];
    for (const t of r.trades) {
      const id = `${t.instrument.venue}:${t.instrument.symbol}`;
      if (id !== last.chart.instrumentId) continue;
      out.push({ time: Math.floor(t.entryTime / 1000), side: "buy", text: "Buy" });
      if (t.exitTime !== undefined) out.push({ time: Math.floor(t.exitTime / 1000), side: "sell", text: exitText(t.exitReason) ?? "Sell" });
    }
    return out;
  }, [last, r]);
  const chartCandles = useMemo(() => (last?.chart?.bars ?? []).map((b) => ({ ...b, time: Math.floor(b.time / 1000) })), [last]);
  const indicators = useMemo(() => ({ ...DEFAULT_INDICATORS, volume: false }), []);

  const testedRules = ruleLines(spec);
  return (
        <div className="space-y-5 border-t border-border px-4 py-4">
          {r.warnings.length > 0 ? <Notice tone="warn" title="Read before trusting this">{<ul className="list-disc pl-4">{r.warnings.map((w) => <li key={w}>{w}</li>)}</ul>}</Notice> : null}
          <section aria-label="Overall metrics">
            <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-sm font-semibold">{r.strategyTitle} · overall</h3>
              {r.benchmarkReturnPct !== undefined ? <span className="text-xs text-text-2">{r.benchmarkName}: <span className={r.benchmarkReturnPct >= 0 ? "text-up" : "text-down"}>{percent(r.benchmarkReturnPct)}</span></span> : null}
            </div>
            <MetricsGrid m={r.overall} currency={currency} />
          </section>
          <section aria-label="Equity curve">
            <h3 className="mb-2 text-sm font-semibold">Equity curve</h3>
            <EquityChart equity={r.equityCurve.map((p) => ({ time: p.time, value: p.equity }))} benchmark={r.benchmarkCurve.map((p) => ({ time: p.time, value: p.equity }))} benchmarkName={r.benchmarkName} ariaLabel="Backtest equity curve" />
            <EquityData key={last.ranAt} result={r} currency={currency} />
          </section>
          {last?.chart && chartCandles.length > 0 ? (
            <section aria-label="Entries and exits">
              <h3 className="mb-2 text-sm font-semibold">Entries and exits · {last.chart.instrumentId}</h3>
              <PriceChart candles={chartCandles} type="candles" indicators={indicators} markers={markers} intraday={spec.timeframe === "hour"} height={320} ariaLabel="Price chart with backtest entries and exits" />
            </section>
          ) : null}
          {r.inSample && r.outOfSample ? (
            <section aria-label="In-sample versus out-of-sample" className="grid gap-4 xl:grid-cols-2">
              <div><h3 className="mb-2 text-sm font-semibold">In-sample{r.splitTime ? ` (to ${new Date(r.splitTime).toLocaleDateString("en-AU")})` : ""}</h3><MetricsGrid m={r.inSample} currency={currency} /></div>
              <div><h3 className="mb-2 text-sm font-semibold">Out-of-sample (held back)</h3><MetricsGrid m={r.outOfSample} currency={currency} /></div>
            </section>
          ) : null}
          <section aria-label="Trades">
            <h3 className="mb-2 text-sm font-semibold">Trades · {r.trades.length}</h3>
            {r.trades.length === 0 ? <p className="text-xs text-text-3">The rules never triggered in this period.</p> : (
              <div className="max-h-80 overflow-auto rounded-lg border border-border" tabIndex={0} role="region" aria-label="Backtest trade table">
                <table className="w-full text-left text-xs">
                  <thead className="sticky top-0 bg-surface-2 text-text-3"><tr>{["Asset", "Entry", "Entry price", "Exit", "Exit price", "Qty", "P/L", "P/L %", "Bars", "Why it exited"].map((h) => <th key={h} scope="col" className="px-2.5 py-2 font-medium whitespace-nowrap">{h}</th>)}</tr></thead>
                  <tbody className="divide-y divide-border">
                    {r.trades.map((t) => (
                      <tr key={t.id} className="tabular">
                        <td className="px-2.5 py-1.5 font-medium">{t.instrument.symbol}</td>
                        <td className="px-2.5 py-1.5 whitespace-nowrap">{new Date(t.entryTime).toLocaleDateString("en-AU")}</td>
                        <td className="px-2.5 py-1.5">{money(t.entryPrice, t.instrument.currency)}</td>
                        <td className="px-2.5 py-1.5 whitespace-nowrap">{t.exitTime ? new Date(t.exitTime).toLocaleDateString("en-AU") : <Badge>Open</Badge>}</td>
                        <td className="px-2.5 py-1.5">{t.exitPrice !== undefined ? money(t.exitPrice, t.instrument.currency) : "—"}</td>
                        <td className="px-2.5 py-1.5">{plainNumber(t.quantity, 6)}</td>
                        <td className={`px-2.5 py-1.5 ${t.pnl >= 0 ? "text-up" : "text-down"}`}>{money(t.pnl, t.instrument.currency)}</td>
                        <td className={`px-2.5 py-1.5 ${t.pnlPct >= 0 ? "text-up" : "text-down"}`}>{percent(t.pnlPct)}</td>
                        <td className="px-2.5 py-1.5">{t.barsHeld}</td>
                        <td className="px-2.5 py-1.5 text-text-2">{exitText(t.exitReason) ?? "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
          {testedRules.length > 0 && <section aria-label="Rules tested">
            <h3 className="mb-2 text-sm font-semibold">Rules tested</h3>
            <ul className="list-disc space-y-1 pl-4 text-xs text-text-2">{testedRules.map((line, index) => <li key={index}>{line}</li>)}</ul>
          </section>}
          <section aria-label="Assumptions" className="grid gap-4 lg:grid-cols-2">
            <div>
              <h3 className="mb-2 text-sm font-semibold">Assumptions</h3>
              <ul className="list-disc space-y-1 pl-4 text-xs text-text-2">{r.assumptions.map((a) => <li key={a}>{a}</li>)}</ul>
            </div>
            <div>
              <h3 className="mb-2 text-sm font-semibold">What was run</h3>
              <dl className="space-y-1 text-xs text-text-2">
                <div><dt className="inline text-text-3">Engine: </dt><dd className="inline">{last.engine}</dd></div>
                <div><dt className="inline text-text-3">As of: </dt><dd className="inline">{dateTime(new Date(last.inputs.asOf).toISOString())}</dd></div>
                <div><dt className="inline text-text-3">Result fingerprint: </dt><dd className="inline font-mono">{backtestFingerprint(last.result)}</dd></div>
                <div><dt className="inline text-text-3">Real market data only: </dt><dd className="inline">{r.usedRealMarketData ? "yes" : "no"}</dd></div>
                {[...last.datasets, ...(last.benchmarkDataset ? [last.benchmarkDataset] : [])].map((d, index) => (
                  <div key={index}><dt className="inline text-text-3">{index === last.datasets.length ? "Benchmark " : ""}{d.instrumentId}: </dt>
                    <dd className="inline">{d.source}, {d.bars} {d.timeframe === "day" ? "daily" : "hourly"} bars {d.firstBar?.slice(0, 10)} → {d.lastBar?.slice(0, 10)}, {d.currency}, sha256 <span className="font-mono">{d.sha256.slice(0, 12)}</span></dd></div>
                ))}
                {last.failures.map((f) => <div key={f.instrumentId} className="text-warn">{f.instrumentId} left out: {f.reasons.join("; ")}</div>)}
              </dl>
            </div>
          </section>
          <p className="text-[11px] text-text-3">A backtest is a simulation on past prices. It isn&apos;t a forecast, and a good result doesn&apos;t make a strategy safe to trade with real money.</p>
        </div>
  );
}

function EquityData({ result, currency }: { result: BacktestResponse["result"]; currency: string }) {
  const [expanded, setExpanded] = useState(false);
  const [page, setPage] = useState(0);
  const size = 50;
  const length = Math.ceil(result.equityCurve.length / size);
  const rows = result.equityCurve.slice(page * size, (page + 1) * size);
  const benchmark = useMemo(() => new Map(result.benchmarkCurve.map((point) => [point.time, point.equity])), [result]);
  return <details onToggle={(event) => setExpanded(event.currentTarget.open)} className="text-xs text-text-2">
    <summary className="w-fit cursor-pointer py-2">Equity data table</summary>
    {expanded && <>
      <div className="overflow-auto" tabIndex={0} role="region" aria-label="Backtest equity data"><table className="w-full text-left">
        <thead><tr><th scope="col">Time</th><th scope="col">Equity</th>{result.benchmarkName && <th scope="col">{result.benchmarkName}</th>}</tr></thead>
        <tbody>{rows.map((row) => <tr key={row.time}><td>{dateTime(new Date(row.time).toISOString())}</td><td>{money(row.equity, currency)}</td>
          {result.benchmarkName && <td>{money(benchmark.get(row.time), currency)}</td>}</tr>)}</tbody>
      </table></div>
      {length > 1 && <div className="mt-2 flex flex-wrap items-center gap-2">
        <Button size="sm" disabled={page === 0} onClick={() => setPage(page - 1)}>Previous points</Button>
        <span aria-live="polite">Page {page + 1} of {length}</span>
        <Button size="sm" disabled={page + 1 >= length} onClick={() => setPage(page + 1)}>Next points</Button>
      </div>}
    </>}
  </details>;
}
