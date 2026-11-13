"use client";

// Edits a strategy rule tree: groups (all / any) of comparisons between two operands. The
// tree is plain data (StrategySpec JSON) — nothing here produces code, and only operand kinds
// the evaluator supports can be chosen.

import { type Condition, type ConditionOp, type Operand, type OperandKind, OPERAND_KINDS, Op, operandLabel, type PriceField } from "@engine/strategy.ts";
import type { Timeframe } from "@engine/market.ts";
import { FolderPlus, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { Input, Select } from "@/components/ui/Field";
import { cn } from "@/lib/cn";

const KIND_LABEL: Record<OperandKind, string> = {
  price: "Price", volume: "Volume", volumeAverage: "Average volume", sma: "Moving average (SMA)", ema: "Exponential MA (EMA)",
  rsi: "RSI", macdLine: "MACD line", macdSignal: "MACD signal", macdHistogram: "MACD histogram",
  bollingerUpper: "Bollinger upper", bollingerMiddle: "Bollinger middle", bollingerLower: "Bollinger lower",
  atr: "ATR", highest: "Prior high", lowest: "Prior low", rateOfChange: "Rate of change %", constant: "Number",
};

const COMPARE: { value: ConditionOp; label: string }[] = [
  { value: "crossesAbove", label: "crosses above" }, { value: "crossesBelow", label: "crosses below" },
  { value: "above", label: "is above" }, { value: "below", label: "is below" },
];

function defaultOperand(kind: OperandKind): Operand {
  switch (kind) {
    case "price": return Op.close;
    case "volume": return Op.volume;
    case "volumeAverage": return Op.volumeAverage(20);
    case "sma": return Op.sma(20);
    case "ema": return Op.ema(20);
    case "rsi": return Op.rsi(14);
    case "macdLine": return Op.macdLine();
    case "macdSignal": return Op.macdSignal();
    case "macdHistogram": return Op.macdHistogram();
    case "bollingerUpper": return Op.bollingerUpper();
    case "bollingerMiddle": return Op.bollingerMiddle();
    case "bollingerLower": return Op.bollingerLower();
    case "atr": return Op.atr(14);
    case "highest": return Op.highest(20);
    case "lowest": return Op.lowest(20);
    case "rateOfChange": return Op.rateOfChange(10);
    case "constant": return Op.constant(50);
  }
}

function NumberField({ label, value, onChange, step = 1, min, max }: { label: string; value: number | undefined; onChange: (v: number | undefined) => void; step?: number; min?: number; max?: number }) {
  return (
    <label className="flex items-center gap-1 text-[11px] text-text-3">
      {label}
      <Input type="number" inputMode="decimal" step={step} min={min} max={max} value={value ?? ""} aria-label={label}
        onChange={(e) => onChange(e.target.value === "" ? undefined : Number(e.target.value))} className="h-7 w-[68px] px-2 text-xs" />
    </label>
  );
}

function OperandEditor({ value, onChange, label }: { value: Operand; onChange: (o: Operand) => void; label: string }) {
  const set = (patch: Partial<Operand>) => onChange({ ...value, ...patch });
  const k = value.kind;
  return (
    <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label={label}>
      <Select value={k} onChange={(e) => onChange(defaultOperand(e.target.value as OperandKind))} aria-label={`${label} kind`} className="h-7 w-auto px-2 text-xs">
        {OPERAND_KINDS.map((kind) => <option key={kind} value={kind}>{KIND_LABEL[kind]}</option>)}
      </Select>
      {k === "price" ? (
        <Select value={value.field ?? "close"} onChange={(e) => set({ field: e.target.value as PriceField })} aria-label={`${label} price field`} className="h-7 w-auto px-2 text-xs">
          {["open", "high", "low", "close"].map((f) => <option key={f} value={f}>{f}</option>)}
        </Select>
      ) : null}
      {["volumeAverage", "sma", "ema", "rsi", "atr", "highest", "lowest", "rateOfChange", "bollingerUpper", "bollingerMiddle", "bollingerLower"].includes(k)
        ? <NumberField label="period" value={value.period} min={1} max={400} onChange={(v) => set({ period: v })} /> : null}
      {k.startsWith("bollinger") && k !== "bollingerMiddle" ? <NumberField label="σ" step={0.5} value={value.deviations} onChange={(v) => set({ deviations: v })} /> : null}
      {k.startsWith("macd") ? (<>
        <NumberField label="fast" value={value.fast} onChange={(v) => set({ fast: v })} />
        <NumberField label="slow" value={value.slow} onChange={(v) => set({ slow: v })} />
        <NumberField label="signal" value={value.signal} onChange={(v) => set({ signal: v })} />
      </>) : null}
      {k === "constant" ? <NumberField label="value" step={0.1} value={value.value} onChange={(v) => set({ value: v })} /> : null}
      {k !== "constant" ? <NumberField label="×" step={0.01} value={value.factor} onChange={(v) => set({ factor: v === 1 ? undefined : v })} /> : null}
    </div>
  );
}

export function ConditionEditor({ value, onChange, onRemove, timeframe, depth = 0, label }: {
  value: Condition; onChange: (c: Condition) => void; onRemove?: () => void; timeframe: Timeframe; depth?: number; label: string;
}) {
  const isGroup = value.op === "all" || value.op === "any";
  if (isGroup) {
    const children = value.conditions ?? [];
    const setChild = (i: number, c: Condition) => onChange({ ...value, conditions: children.map((x, j) => (j === i ? c : x)) });
    const removeChild = (i: number) => onChange({ ...value, conditions: children.filter((_, j) => j !== i) });
    return (
      <div className={cn("rounded-lg border border-border p-2.5", depth > 0 && "bg-surface-2/60")} role="group" aria-label={label}>
        <div className="mb-2 flex items-center justify-between gap-2">
          <div className="flex items-center gap-2 text-xs text-text-2">
            Match
            <Select value={value.op} onChange={(e) => onChange({ ...value, op: e.target.value as ConditionOp })} aria-label={`${label}: match all or any`} className="h-7 w-auto px-2 text-xs">
              <option value="all">all of</option><option value="any">any of</option>
            </Select>
          </div>
          {onRemove ? <Button size="sm" variant="ghost" aria-label={`Remove ${label}`} onClick={onRemove}><Trash2 className="h-3.5 w-3.5" /></Button> : null}
        </div>
        <div className="flex flex-col gap-2">
          {children.length === 0 ? <p className="text-xs text-warn">An empty group never matches. Add a rule.</p> : null}
          {children.map((c, i) => (
            <ConditionEditor key={i} value={c} timeframe={timeframe} depth={depth + 1} label={`${label}, rule ${i + 1}`}
              onChange={(n) => setChild(i, n)} onRemove={() => removeChild(i)} />
          ))}
        </div>
        <div className="mt-2 flex gap-1.5">
          <Button size="sm" variant="ghost" onClick={() => onChange({ ...value, conditions: [...children, { op: "above", left: Op.close, right: Op.sma(50) }] })}><Plus className="h-3.5 w-3.5" />Rule</Button>
          {depth < 2 ? <Button size="sm" variant="ghost" onClick={() => onChange({ ...value, conditions: [...children, { op: "all", conditions: [{ op: "above", left: Op.close, right: Op.sma(20) }] }] })}><FolderPlus className="h-3.5 w-3.5" />Group</Button> : null}
        </div>
      </div>
    );
  }
  const left = value.left ?? Op.close;
  const right = value.right ?? Op.sma(50);
  return (
    <div className="rounded-lg border border-border bg-surface p-2.5" role="group" aria-label={label}>
      <div className="flex flex-wrap items-center gap-2">
        <OperandEditor label={`${label} left side`} value={left} onChange={(o) => onChange({ ...value, left: o })} />
        <Select value={value.op} onChange={(e) => onChange({ ...value, op: e.target.value as ConditionOp })} aria-label={`${label} comparison`} className="h-7 w-auto px-2 text-xs font-medium">
          {COMPARE.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
        </Select>
        <OperandEditor label={`${label} right side`} value={right} onChange={(o) => onChange({ ...value, right: o })} />
        {onRemove ? <Button size="sm" variant="ghost" className="ml-auto" aria-label={`Remove ${label}`} onClick={onRemove}><Trash2 className="h-3.5 w-3.5" /></Button> : null}
      </div>
      <p className="mt-1.5 text-[11px] text-text-3">{operandLabel(left, timeframe)} {COMPARE.find((c) => c.value === value.op)?.label} {operandLabel(right, timeframe)}</p>
    </div>
  );
}

/** Wraps a single rule in an "all" group so the editor can always add siblings. */
export function asGroup(c: Condition | undefined): Condition {
  if (!c) return { op: "all", conditions: [] };
  return c.op === "all" || c.op === "any" ? c : { op: "all", conditions: [c] };
}

/** Collapses a one-rule "all" group back to the rule, as the templates write it. */
export function simplify(c: Condition): Condition | undefined {
  if ((c.op === "all" || c.op === "any") && (c.conditions ?? []).length === 0) return undefined;
  if (c.op === "all" && c.conditions?.length === 1) return c.conditions[0];
  return c;
}
