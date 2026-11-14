"use client";

import { useState, type FormEvent } from "react";
import { useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input, Select } from "@/components/ui/Field";
import { money, percent, signedMoney } from "@/lib/format";
import { browserSupabase } from "@/lib/supabase/client";
import { uuid } from "@/lib/uuid";
import { BenchmarkComparison } from "./benchmark-comparison";
import { BrokerActivity, conversionDetails, type HistoricalFx } from "./broker-activity";

type FlowKind = "deposit" | "withdrawal";
type Flow = { date: string; kind: FlowKind; amount: number; snaptrade_id?: string; fx?: HistoricalFx };
type ReturnMethods = {
  return_pct: number | null;
  time_weighted_return_pct: number | null;
  money_weighted_return_pct: number | null;
};
type Period = ReturnMethods & {
  id: string;
  starts_on: string;
  ends_on: string;
  opening_value_usd: number;
  closing_value_usd: number;
  external_flows: Flow[];
  deposits_usd: number;
  withdrawals_usd: number;
  investment_change_usd: number;
  transfer_values_usd: Record<string, number>;
};
type Summary = ReturnMethods & Pick<Period, "starts_on" | "ends_on" | "investment_change_usd"> & { periods: number };
type FlowInput = Omit<Flow, "amount"> & { id: string; amount: string };

async function readPeriods(userId: string) {
  const db = browserSupabase();
  if (!db) throw new Error("Accounts are unavailable.");
  const [periods, summary] = await Promise.all([
    db.from("portfolio_performance_results").select("*").eq("user_id", userId).order("ends_on", { ascending: false }).limit(101),
    db.from("portfolio_performance_summary").select("starts_on,ends_on,periods,investment_change_usd,return_pct,time_weighted_return_pct,money_weighted_return_pct").eq("user_id", userId).maybeSingle(),
  ]);
  if (periods.error || summary.error) throw periods.error ?? summary.error;
  return { rows: periods.data as Period[], summary: summary.data as Summary | null };
}

function displayReturn(value: number | null) {
  return value === null ? "Unavailable" : percent(value);
}

function returnMetrics(methods: ReturnMethods) {
  return [
    ["Time-weighted return", displayReturn(methods.time_weighted_return_pct)],
    ["Money-weighted return", displayReturn(methods.money_weighted_return_pct)],
    ["Modified Dietz return", displayReturn(methods.return_pct)],
  ];
}

export function PerformanceLedger({ userId }: { userId: string }) {
  const periods = useQuery({ queryKey: ["portfolio-performance", userId], queryFn: () => readPeriods(userId) });
  const [editor, setEditor] = useState<{ period?: Period }>();
  const [removing, setRemoving] = useState<string>();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function remove(id: string) {
    const db = browserSupabase();
    if (!db) return;
    setBusy(true);
    setError("");
    try {
      const { error } = await db.from("portfolio_performance_periods").delete().eq("id", id).eq("user_id", userId);
      if (error) throw error;
      setRemoving(undefined);
      await periods.refetch();
    } catch {
      setError("Couldn’t remove the period. Try again.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <CardHeader title="Portfolio returns" subtitle="Separate deposits and withdrawals from investment gains or losses."
        actions={!editor && <Button size="sm" onClick={() => { setRemoving(undefined); setEditor({}); }}>Add period</Button>} />
      <div className="space-y-4 border-t border-border p-4">
        {editor && <PeriodEditor key={editor.period?.id ?? "new"} userId={userId} period={editor.period}
          onClose={() => setEditor(undefined)} onSave={async () => { await periods.refetch(); setEditor(undefined); }} />}
        {periods.isPending ? <div className="skeleton h-20" role="status" aria-label="Loading portfolio returns" />
          : periods.isError ? <EmptyState title="Couldn’t load portfolio returns" tone="down"
            actions={<Button onClick={() => void periods.refetch()}>Retry</Button>} />
          : !periods.data.rows.length ? <EmptyState title="No reconciled periods yet" body="Use opening and closing values from your statements, including cash, and record transfers into or out of the portfolio." />
          : <>
            <p className="text-xs text-text-3">Time-weighted return uses a valuation after transfers on each transfer date. Money-weighted return uses the size and dates of transfers. All returns cover the displayed period.</p>
            {periods.data.summary && periods.data.summary.periods > 1 && (
              <div className="rounded-lg border border-border bg-surface-2 p-3">
                <h3 className="font-medium">Latest continuous returns</h3>
                <p className="text-xs text-text-3">{periods.data.summary.starts_on} to {periods.data.summary.ends_on} · {periods.data.summary.periods} periods</p>
                <dl className="mt-2 grid grid-cols-2 gap-2 tabular sm:grid-cols-3">
                  {[...returnMetrics(periods.data.summary), ["Investment change", signedMoney(periods.data.summary.investment_change_usd, "USD")]].map(([label, value]) => (
                    <div key={label}><dt className="text-xs text-text-3">{label}</dt><dd>{value}</dd></div>
                  ))}
                </dl>
              </div>
            )}
            <BenchmarkComparison periods={periods.data.rows.slice(0, 100)}
              continuous={periods.data.summary && periods.data.summary.periods > 1 ? periods.data.summary : null} />
            {periods.data.rows.length > 100 && <p role="status" className="text-xs text-warn">Showing the 100 most recent periods.</p>}
            <ol className="divide-y divide-border">
              {periods.data.rows.slice(0, 100).map((period) => (
                <li key={period.id} className="space-y-2 py-3">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <h3 className="font-medium"><time dateTime={period.starts_on}>{period.starts_on}</time> to <time dateTime={period.ends_on}>{period.ends_on}</time></h3>
                    <div className="flex items-center gap-1">
                      {removing === period.id ? <>
                        <Button size="sm" disabled={busy} onClick={() => setRemoving(undefined)}>Cancel</Button>
                        <Button size="sm" variant="danger" disabled={busy} onClick={() => void remove(period.id)}>Remove period</Button>
                      </> : <>
                        <Button size="sm" variant="ghost" disabled={busy} onClick={() => setEditor({ period })} aria-label={`Edit period ending ${period.ends_on}`}>Edit</Button>
                        <Button size="sm" variant="ghost" disabled={busy} onClick={() => setRemoving(period.id)} aria-label={`Remove period ending ${period.ends_on}`}>Remove</Button>
                      </>}
                    </div>
                  </div>
                  <dl className="grid grid-cols-2 gap-2 tabular sm:grid-cols-3">
                    {[
                      ["Opening value", money(period.opening_value_usd, "USD")],
                      ["Closing value", money(period.closing_value_usd, "USD")],
                      ["Deposits", money(period.deposits_usd, "USD")],
                      ["Withdrawals", money(period.withdrawals_usd, "USD")],
                      ["Investment change", signedMoney(period.investment_change_usd, "USD")],
                      ...returnMetrics(period),
                    ].map(([label, value]) => <div key={label}><dt className="text-xs text-text-3">{label}</dt><dd>{value}</dd></div>)}
                  </dl>
                </li>
              ))}
            </ol>
          </>}
        {error && <p role="alert" className="text-sm text-down">{error}</p>}
      </div>
    </Card>
  );
}

function PeriodEditor({ userId, period, onClose, onSave }: { userId: string; period?: Period; onClose: () => void; onSave: () => Promise<void> }) {
  const [start, setStart] = useState(period?.starts_on ?? "");
  const [end, setEnd] = useState(period?.ends_on ?? "");
  const [flows, setFlows] = useState<FlowInput[]>(() => period?.external_flows.map((flow) => ({ ...flow, id: uuid(), amount: String(flow.amount) })) ?? []);
  const [transferValues, setTransferValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(Object.entries(period?.transfer_values_usd ?? {}).map(([date, value]) => [date, String(value)])));
  const valuationDates = [...new Set(flows.map((flow) => flow.date).filter((date) => date > start && date < end))].sort();
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const [id] = useState(() => period?.id ?? uuid());

  function setFlow(flowId: string, patch: Partial<FlowInput>) {
    setFlows((current) => current.map((flow) => flow.id === flowId ? { ...flow, ...patch } : flow));
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const db = browserSupabase();
    if (!db || saving) return;
    setError("");
    if (end <= start || flows.some((flow) => flow.date <= start || flow.date > end)) {
      setError("The closing date must follow the opening date. Transfers must occur after opening and through the closing date.");
      return;
    }
    const form = new FormData(event.currentTarget);
    setSaving(true);
    try {
      const { error } = await db.from("portfolio_performance_periods").upsert({
        id, user_id: userId, starts_on: start, ends_on: end,
        opening_value_usd: Number(form.get("opening")), closing_value_usd: Number(form.get("closing")),
        external_flows: flows.map(({ date, kind, amount, snaptrade_id, fx }) => ({ date, kind, amount: Number(amount), snaptrade_id, fx })),
        transfer_values_usd: Object.fromEntries(valuationDates.filter((date) => transferValues[date]?.trim())
          .map((date) => [date, Number(transferValues[date])])),
      }, { onConflict: "id" });
      if (error) {
        setError(error.code === "23P01" ? "This period overlaps an existing period. Edit that period or choose different dates." : "Couldn’t save the period. Check the values and try again.");
        return;
      }
      await onSave();
    } catch {
      setError("Couldn’t save the period. Try again.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form aria-label="Reconcile a performance period" onSubmit={(event) => void save(event)} className="space-y-3 rounded-lg border border-border bg-surface-2 p-3">
      <h3 className="font-medium">{period ? `Edit period ending ${period.ends_on}` : "Reconcile a performance period"}</h3>
      <p className="text-xs text-text-2">Enter end-of-day values for the same accounts, including cash. Convert balances and transfers to USD at their dates. Purchases, sales, reinvested income and transfers within those accounts stay inside the portfolio.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Opening date" htmlFor="performance-start"><Input id="performance-start" type="date" min="1900-01-01" max="9999-12-31" required value={start} onChange={(event) => setStart(event.target.value)} /></Field>
        <Field label="Opening value (USD)" htmlFor="performance-opening"><Input id="performance-opening" name="opening" type="number" min="0" max="9999999999999.99" step="0.01" required defaultValue={period?.opening_value_usd} /></Field>
        <Field label="Closing date" htmlFor="performance-end"><Input id="performance-end" type="date" min={start || "1900-01-01"} max="9999-12-31" required value={end} onChange={(event) => setEnd(event.target.value)} /></Field>
        <Field label="Closing value (USD)" htmlFor="performance-closing"><Input id="performance-closing" name="closing" type="number" min="0" max="9999999999999.99" step="0.01" required defaultValue={period?.closing_value_usd} /></Field>
      </div>
      {start && end > start && <BrokerActivity key={`${start}/${end}`} mode="cash" start={start} end={end}
        imported={new Set(flows.flatMap((flow) => flow.snaptrade_id ? [flow.snaptrade_id] : []))} canInclude={flows.length < 366 && !saving}
        onInclude={(flow) => setFlows((current) => current.length >= 366 || current.some((existing) => existing.snaptrade_id === flow.snaptrade_id)
          ? current : [...current, { ...flow, id: uuid(), amount: String(flow.amount) }])} />}
      {flows.map((flow, index) => (
        <fieldset key={flow.id} className="grid gap-2 border-t border-border pt-2 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end">
          <legend className={flow.snaptrade_id ? "text-xs text-text-2" : "sr-only"}>{flow.snaptrade_id ? "SnapTrade transfer" : `External transfer ${index + 1}`}</legend>
          <Field label="Transfer date" htmlFor={`flow-date-${flow.id}`}><Input id={`flow-date-${flow.id}`} type="date" min={start || "1900-01-01"} max={end || "9999-12-31"} required value={flow.date} disabled={Boolean(flow.snaptrade_id)} onChange={(event) => setFlow(flow.id, { date: event.target.value })} /></Field>
          <Field label="Transfer type" htmlFor={`flow-kind-${flow.id}`}><Select id={`flow-kind-${flow.id}`} value={flow.kind} disabled={Boolean(flow.snaptrade_id)} onChange={(event) => setFlow(flow.id, { kind: event.target.value === "withdrawal" ? "withdrawal" : "deposit" })}><option value="deposit">Deposit</option><option value="withdrawal">Withdrawal</option></Select></Field>
          <Field label="Transfer amount (USD)" htmlFor={`flow-amount-${flow.id}`}><Input id={`flow-amount-${flow.id}`} type="number" min="0.01" max="9999999999999.99" step="0.01" required value={flow.amount} disabled={Boolean(flow.snaptrade_id)} onChange={(event) => setFlow(flow.id, { amount: event.target.value })} /></Field>
          {flow.fx && <p className="text-xs text-text-2 sm:col-span-4">{conversionDetails(flow.fx)}</p>}
          <Button size="sm" variant="ghost" onClick={() => setFlows((current) => current.filter((item) => item.id !== flow.id))} aria-label={`Remove transfer ${index + 1}`}>Remove</Button>
        </fieldset>
      ))}
      {valuationDates.length > 0 && <fieldset className="grid gap-3 rounded-md border border-border p-2 sm:grid-cols-2">
        <legend className="px-1 text-sm font-medium">Transfer-day valuations</legend>
        <p className="text-xs text-text-2 sm:col-span-2">For time-weighted return, enter the total value including cash after all transfers on each date. The closing value covers transfers on the closing date.</p>
        {valuationDates.map((date) => (
          <Field key={date} label={`Value after transfers on ${date} (USD)`} htmlFor={`transfer-value-${date}`}>
            <Input id={`transfer-value-${date}`} type="number" min="0" max="9999999999999.99" step="0.01"
              value={transferValues[date] ?? ""} onChange={(event) => setTransferValues((current) => ({ ...current, [date]: event.target.value }))} />
          </Field>
        ))}
      </fieldset>}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={saving || flows.length >= 366} onClick={() => setFlows((current) => [...current, { id: uuid(), date: "", kind: "deposit", amount: "" }])}>Add transfer</Button>
        <Button size="sm" disabled={saving} onClick={onClose}>Cancel</Button>
        <Button size="sm" disabled={saving} variant="primary" type="submit">{saving ? "Saving…" : "Save period"}</Button>
      </div>
      {error && <p role="alert" className="text-sm text-down">{error}</p>}
    </form>
  );
}
