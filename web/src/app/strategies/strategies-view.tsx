"use client";

import { UniverseCatalog } from "@engine/catalog.ts";
import type { Instrument, Timeframe } from "@engine/market.ts";
import { instrumentID } from "@engine/market.ts";
import { makeSpec, ruleLines, type SizingMode, type StrategyKind, type StrategySpec, validate } from "@engine/strategy.ts";
import * as Templates from "@engine/templates.ts";
import { Copy, Save, Sparkles, Trash2, Wand2, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { useSearch } from "@/hooks/market";
import { dateTime } from "@/lib/format";
import { BacktestPanel } from "./backtest-panel";
import { StartAgent } from "./start-agent";
import { asGroup, ConditionEditor, simplify } from "./condition-editor";
import { deleteVersion, readVersions, type SavedVersion, saveVersion } from "./versions";

const TEMPLATES: { id: string; label: string; make: () => StrategySpec }[] = [
  { id: "mac", label: "Moving-average crossover", make: () => Templates.movingAverageCrossover([UniverseCatalog.broadETFs[0]]) },
  { id: "trend", label: "Trend following", make: () => Templates.trendFollowing([UniverseCatalog.broadETFs[0], UniverseCatalog.broadETFs[1]]) },
  { id: "momentum", label: "Momentum", make: () => Templates.momentum(UniverseCatalog.technology.slice(0, 5)) },
  { id: "meanrev", label: "Mean reversion", make: () => Templates.meanReversion(UniverseCatalog.technology.slice(0, 4)) },
  { id: "breakout", label: "Breakout", make: () => Templates.breakout(UniverseCatalog.technology.slice(0, 4)) },
  { id: "crypto", label: "Crypto trend monitor", make: () => Templates.cryptoMonitor(UniverseCatalog.cryptoMajors) },
  { id: "dca", label: "Dollar-cost averaging", make: () => Templates.dollarCostAveraging([UniverseCatalog.broadETFs[0]]) },
  { id: "rebalance", label: "ETF rebalancing", make: () => Templates.etfRebalancing(UniverseCatalog.balancedETFs) },
];

interface ParseResponse {
  draft: { spec: StrategySpec; name: string };
  understood: string[];
  assumptions: string[];
  unrecognisedSymbols: string[];
}

function UniverseEditor({ universe, onChange }: { universe: Instrument[]; onChange: (u: Instrument[]) => void }) {
  const [query, setQuery] = useState("");
  const search = useSearch(query);
  const ids = new Set(universe.map(instrumentID));
  return (
    <div>
      <div className="flex flex-wrap gap-1.5">
        {universe.length === 0 ? <span className="text-xs text-warn">Add at least one asset.</span> : null}
        {universe.map((i) => (
          <span key={instrumentID(i)} className="inline-flex items-center gap-1 rounded-md border border-border bg-surface-2 py-0.5 pl-2 pr-1 text-xs">
            {i.symbol}<span className="text-text-3">{i.venue.toUpperCase()}</span>
            <button type="button" aria-label={`Remove ${i.symbol}`} onClick={() => onChange(universe.filter((x) => instrumentID(x) !== instrumentID(i)))} className="rounded p-0.5 text-text-3 hover:text-text"><X className="h-3 w-3" /></button>
          </span>
        ))}
      </div>
      <div className="relative mt-2">
        <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Add an asset…" aria-label="Add an asset to the strategy" className="h-8 text-xs" />
        {query.trim() && search.data ? (
          <ul className="absolute z-20 mt-1 max-h-56 w-full overflow-y-auto rounded-lg border border-border-strong bg-surface p-1 shadow-xl">
            {search.data.results.length === 0 ? <li className="px-2 py-1.5 text-xs text-text-3">No matches</li> : search.data.results.slice(0, 8).map((r) => (
              <li key={r.id}>
                <button type="button" disabled={ids.has(r.id)} onClick={() => { onChange([...universe, { symbol: r.symbol, name: r.name, assetClass: r.assetClass, venue: r.venue, currency: r.currency }]); setQuery(""); }}
                  className="flex w-full items-center justify-between gap-2 rounded-md px-2 py-1.5 text-left text-xs hover:bg-surface-2 disabled:opacity-40">
                  <span className="truncate"><span className="font-medium">{r.symbol}</span> · {r.name}</span><Badge>{r.venueShort}</Badge>
                </button>
              </li>
            ))}
          </ul>
        ) : null}
      </div>
    </div>
  );
}

function NumberInput({ id, value, onChange, step = 1, min, max, placeholder }: { id: string; value: number | undefined; onChange: (v: number | undefined) => void; step?: number; min?: number; max?: number; placeholder?: string }) {
  return <Input id={id} type="number" inputMode="decimal" step={step} min={min} max={max} placeholder={placeholder} value={value ?? ""} onChange={(e) => onChange(e.target.value === "" ? undefined : Number(e.target.value))} />;
}

export function StrategiesView() {
  const [spec, setSpec] = useState<StrategySpec>(() => TEMPLATES[0].make());
  const [text, setText] = useState("");
  const [parsing, setParsing] = useState(false);
  const [parsed, setParsed] = useState<ParseResponse | null>(null);
  const [parseError, setParseError] = useState<string | null>(null);
  const [versions, setVersions] = useState<SavedVersion[]>([]);
  const [saveNote, setSaveNote] = useState<string | null>(null);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setVersions(readVersions());
  }, []);

  const issues = useMemo(() => validate(spec), [spec]);
  const errors = issues.filter((i) => i.severity === "error");
  const warnings = issues.filter((i) => i.severity === "warning");
  const lines = useMemo(() => ruleLines(spec), [spec]);
  const patch = (p: Partial<StrategySpec>) => setSpec((s) => ({ ...s, ...p }));

  const parse = async () => {
    setParsing(true);
    setParseError(null);
    try {
      const response = await fetch("/api/strategies/parse", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
      const body = await response.json();
      if (!response.ok || body.error) throw new Error(body.error?.message ?? "Couldn't read that.");
      setParsed(body as ParseResponse);
      setSpec((body as ParseResponse).draft.spec);
    } catch (error) {
      setParseError(error instanceof Error ? error.message : "Couldn't read that.");
    } finally {
      setParsing(false);
    }
  };

  const changeKind = (kind: StrategyKind) => {
    if (kind === spec.kind) return;
    if (kind === "dca") setSpec({ ...Templates.dollarCostAveraging(spec.universe.length ? spec.universe : [UniverseCatalog.broadETFs[0]]), title: spec.title });
    else if (kind === "rebalance") {
      const u = spec.universe.length ? spec.universe : UniverseCatalog.balancedETFs;
      const each = Math.floor(100 / u.length);
      setSpec(makeSpec({ kind: "rebalance", title: spec.title, summary: "Keeps each fund near its target share.", universe: u, rebalance: { targets: Object.fromEntries(u.map((i) => [instrumentID(i), each])), driftThresholdPct: 5 } }));
    } else setSpec(makeSpec({ kind: "rules", title: spec.title, summary: spec.summary, universe: spec.universe, entry: { op: "crossesAbove", left: { kind: "sma", period: 20 }, right: { kind: "sma", period: 50 } }, exit: { op: "crossesBelow", left: { kind: "sma", period: 20 }, right: { kind: "sma", period: 50 } } }));
  };

  const setUniverse = (universe: Instrument[]) => {
    if (spec.kind === "rebalance" && spec.rebalance) {
      const targets: Record<string, number> = {};
      for (const i of universe) targets[instrumentID(i)] = spec.rebalance.targets[instrumentID(i)] ?? 0;
      patch({ universe, rebalance: { ...spec.rebalance, targets } });
    } else patch({ universe });
  };

  return (
    <div className="mx-auto max-w-6xl">
      <PageHeader title="Strategy Studio" description="Describe a strategy in plain English or start from a template. Strategies are structured rules — never generated code — checked by the same validator the phone and server use." />

      <Card className="mb-5">
        <CardHeader title={<span className="inline-flex items-center gap-1.5"><Wand2 aria-hidden className="h-4 w-4 text-primary-fg" />Describe it</span>}
          subtitle="Read by a deterministic parser (no AI model): it maps phrases to rules and lists what it assumed." />
        <div className="flex flex-col gap-2 border-t border-border px-4 py-3 md:flex-row">
          <textarea value={text} onChange={(e) => setText(e.target.value)} rows={2} maxLength={1000} aria-label="Describe your strategy"
            placeholder="Buy BTC when its 20-day average crosses above its 50-day average, and sell on the opposite crossover"
            className="min-h-[64px] flex-1 resize-y rounded-lg border border-border bg-surface-2 px-3 py-2 text-sm text-text placeholder:text-text-3 focus:border-primary focus:outline-none" />
          <Button variant="primary" onClick={parse} disabled={parsing || text.trim() === ""} className="md:self-start"><Sparkles className="h-4 w-4" />{parsing ? "Reading…" : "Build strategy"}</Button>
        </div>
        {parseError ? <div className="px-4 pb-3"><Notice tone="down">{parseError}</Notice></div> : null}
        {parsed ? (
          <div className="grid gap-3 border-t border-border px-4 py-3 text-xs md:grid-cols-3">
            <div><p className="mb-1 font-medium text-text">Understood</p><ul className="list-disc space-y-0.5 pl-4 text-text-2">{parsed.understood.map((u) => <li key={u}>{u}</li>)}</ul></div>
            <div><p className="mb-1 font-medium text-text">Assumed</p>{parsed.assumptions.length ? <ul className="list-disc space-y-0.5 pl-4 text-text-2">{parsed.assumptions.map((u) => <li key={u}>{u}</li>)}</ul> : <p className="text-text-3">Nothing.</p>}</div>
            <div><p className="mb-1 font-medium text-text">Not recognised</p>{parsed.unrecognisedSymbols.length ? <p className="text-warn">{parsed.unrecognisedSymbols.join(", ")} — add them by hand below if they exist.</p> : <p className="text-text-3">Nothing.</p>}</div>
          </div>
        ) : null}
      </Card>

      <div className="grid gap-5 lg:grid-cols-[1fr_300px]">
        <div className="flex min-w-0 flex-col gap-5">
          <Card>
            <CardHeader title="Rules" actions={
              <Select aria-label="Start from a template" value="" onChange={(e) => { const t = TEMPLATES.find((x) => x.id === e.target.value); if (t) { setSpec(t.make()); setParsed(null); } }} className="h-8 w-auto text-xs">
                <option value="">Start from a template…</option>
                {TEMPLATES.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
              </Select>
            } />
            <div className="grid gap-4 border-t border-border px-4 py-4">
              <div className="grid gap-3 md:grid-cols-[1fr_160px_140px]">
                <Field label="Name" htmlFor="s-title"><Input id="s-title" value={spec.title} onChange={(e) => patch({ title: e.target.value })} maxLength={80} /></Field>
                <Field label="Type" htmlFor="s-kind"><Select id="s-kind" value={spec.kind} onChange={(e) => changeKind(e.target.value as StrategyKind)}>
                  <option value="rules">Entry / exit rules</option><option value="dca">Dollar-cost averaging</option><option value="rebalance">Rebalancing</option></Select></Field>
                <Field label="Bars" htmlFor="s-tf"><Select id="s-tf" value={spec.timeframe} onChange={(e) => patch({ timeframe: e.target.value as Timeframe })}><option value="day">Daily</option><option value="hour">Hourly</option></Select></Field>
              </div>
              <Field label="Summary" htmlFor="s-summary"><Input id="s-summary" value={spec.summary} onChange={(e) => patch({ summary: e.target.value })} maxLength={240} /></Field>
              <Field label="Assets"><UniverseEditor universe={spec.universe} onChange={setUniverse} /></Field>

              {spec.kind === "rules" ? (
                <>
                  <div><p className="mb-1.5 text-xs font-medium text-text-2">Buy when</p>
                    <ConditionEditor label="Entry" value={asGroup(spec.entry)} timeframe={spec.timeframe} onChange={(c) => patch({ entry: simplify(c) })} /></div>
                  <div><p className="mb-1.5 text-xs font-medium text-text-2">Sell when</p>
                    <ConditionEditor label="Exit" value={asGroup(spec.exit)} timeframe={spec.timeframe} onChange={(c) => patch({ exit: simplify(c) })} /></div>
                </>
              ) : null}

              {spec.kind === "dca" && spec.dca ? (
                <div className="grid gap-3 sm:grid-cols-2">
                  <Field label={`Amount per buy (${spec.universe[0]?.currency ?? "USD"})`} htmlFor="s-dca-amt"><NumberInput id="s-dca-amt" min={1} value={spec.dca.amountPerBuy} onChange={(v) => patch({ dca: { ...spec.dca!, amountPerBuy: v ?? 0 } })} /></Field>
                  <Field label="Bars between buys" htmlFor="s-dca-int" hint="5 daily bars ≈ weekly"><NumberInput id="s-dca-int" min={1} value={spec.dca.intervalBars} onChange={(v) => patch({ dca: { ...spec.dca!, intervalBars: v ?? 1 } })} /></Field>
                </div>
              ) : null}

              {spec.kind === "rebalance" && spec.rebalance ? (
                <div className="grid gap-3">
                  <div className="grid gap-2 sm:grid-cols-3">
                    {spec.universe.map((i) => (
                      <Field key={instrumentID(i)} label={`${i.symbol} target %`} htmlFor={`t-${i.symbol}`}>
                        <NumberInput id={`t-${i.symbol}`} min={0} max={100} value={spec.rebalance!.targets[instrumentID(i)]} onChange={(v) => patch({ rebalance: { ...spec.rebalance!, targets: { ...spec.rebalance!.targets, [instrumentID(i)]: v ?? 0 } } })} />
                      </Field>
                    ))}
                  </div>
                  <Field label="Rebalance when drift exceeds (percentage points)" htmlFor="s-drift"><NumberInput id="s-drift" min={0.5} step={0.5} value={spec.rebalance.driftThresholdPct} onChange={(v) => patch({ rebalance: { ...spec.rebalance!, driftThresholdPct: v ?? 5 } })} /></Field>
                </div>
              ) : null}
            </div>
          </Card>

          <Card>
            <CardHeader title="Sizing and protections" />
            <div className="grid gap-3 border-t border-border px-4 py-4 sm:grid-cols-2 lg:grid-cols-3">
              <Field label="Position size" htmlFor="s-size-mode"><Select id="s-size-mode" value={spec.sizing.mode} onChange={(e) => patch({ sizing: { ...spec.sizing, mode: e.target.value as SizingMode } })}>
                <option value="percentOfEquity">% of equity</option><option value="fixedNotional">Fixed amount</option></Select></Field>
              <Field label={spec.sizing.mode === "percentOfEquity" ? "Percent per position" : `Amount (${spec.universe[0]?.currency ?? "USD"})`} htmlFor="s-size">
                <NumberInput id="s-size" min={0} value={spec.sizing.value} onChange={(v) => patch({ sizing: { ...spec.sizing, value: v ?? 0 } })} /></Field>
              <Field label="Re-entry cooldown (bars)" htmlFor="s-cool"><NumberInput id="s-cool" min={0} value={spec.reentryCooldownBars} onChange={(v) => patch({ reentryCooldownBars: v ?? 0 })} /></Field>
              <Field label="Stop loss %" htmlFor="s-sl"><NumberInput id="s-sl" min={0} step={0.5} placeholder="none" value={spec.protections.stopLossPct} onChange={(v) => patch({ protections: { ...spec.protections, stopLossPct: v } })} /></Field>
              <Field label="Take profit %" htmlFor="s-tp"><NumberInput id="s-tp" min={0} step={0.5} placeholder="none" value={spec.protections.takeProfitPct} onChange={(v) => patch({ protections: { ...spec.protections, takeProfitPct: v } })} /></Field>
              <Field label="Trailing stop %" htmlFor="s-ts"><NumberInput id="s-ts" min={0} step={0.5} placeholder="none" value={spec.protections.trailingStopPct} onChange={(v) => patch({ protections: { ...spec.protections, trailingStopPct: v } })} /></Field>
              <Field label="Max holding (bars)" htmlFor="s-mh"><NumberInput id="s-mh" min={1} placeholder="none" value={spec.protections.maxHoldingBars} onChange={(v) => patch({ protections: { ...spec.protections, maxHoldingBars: v } })} /></Field>
            </div>
          </Card>

          <BacktestPanel spec={spec} valid={errors.length === 0} />
        </div>

        <div className="flex flex-col gap-5">
          <Card>
            <CardHeader title="In plain English" actions={errors.length ? <Badge tone="down">{errors.length} error{errors.length > 1 ? "s" : ""}</Badge> : <Badge tone="up">Valid</Badge>} />
            <div className="space-y-3 border-t border-border px-4 py-3 text-[13px]">
              {lines.length ? <ul className="space-y-1.5 text-text">{lines.map((l) => <li key={l}>{l}</li>)}</ul> : <p className="text-text-3">No rules yet.</p>}
              {errors.length ? <ul className="space-y-1 text-xs text-down" role="alert">{errors.map((e) => <li key={e.message}>{e.message}</li>)}</ul> : null}
              {warnings.length ? <ul className="space-y-1 text-xs text-warn">{warnings.map((e) => <li key={e.message}>{e.message}</li>)}</ul> : null}
            </div>
          </Card>
          <Card>
            <CardHeader title="Versions" subtitle="Saved in this browser only" actions={
              <Button size="sm" variant="primary" disabled={errors.length > 0} onClick={() => {
                const next = saveVersion(spec);
                if (next) { setVersions(next); setSaveNote(`Saved ${next[0].name} v${next[0].version}`); } else setSaveNote("This browser blocks storage, so versions can't be saved here.");
              }}><Save className="h-3.5 w-3.5" />Save</Button>
            } />
            {saveNote ? <p className="px-4 pb-2 text-xs text-text-2" role="status">{saveNote}</p> : null}
            {versions.length === 0 ? <p className="border-t border-border px-4 py-3 text-xs text-text-3">No saved versions yet.</p> : (
              <ul className="max-h-72 divide-y divide-border overflow-y-auto border-t border-border">
                {versions.map((v) => (
                  <li key={v.id} className="flex items-center gap-2 px-4 py-2">
                    <button type="button" className="min-w-0 flex-1 text-left" onClick={() => setSpec(v.spec)} title="Load this version">
                      <span className="block truncate text-[13px] font-medium text-text">{v.name} <span className="text-text-3">v{v.version}</span></span>
                      <span className="block text-[11px] text-text-3">{dateTime(v.savedAt)}</span>
                    </button>
                    <Button size="sm" variant="ghost" aria-label={`Duplicate ${v.name} v${v.version}`} title="Duplicate" onClick={() => setSpec({ ...v.spec, title: `${v.spec.title} (copy)` })}><Copy className="h-3.5 w-3.5" /></Button>
                    <Button size="sm" variant="ghost" aria-label={`Delete ${v.name} v${v.version}`} title="Delete" onClick={() => setVersions(deleteVersion(v.id))}><Trash2 className="h-3.5 w-3.5" /></Button>
                  </li>
                ))}
              </ul>
            )}
          </Card>
          <StartAgent spec={spec} valid={errors.length === 0} />
        </div>
      </div>
    </div>
  );
}
