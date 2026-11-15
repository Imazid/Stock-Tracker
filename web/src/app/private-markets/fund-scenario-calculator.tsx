"use client";

import { useId, useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, Input, Select } from "@/components/ui/Field";
import { Segmented } from "@/components/ui/Segmented";
import { scenarioAmount } from "@/lib/private-scenarios";
import { SourceLink } from "./catalog";
import { amount, type PrivateDeal } from "./private-data";
import { fundScenario } from "./private-performance";
import { DecimalField, ScenarioDialog, scenarioCurrencies, scenarioOutcomes } from "./scenario-calculator";

type Outcome = (typeof scenarioOutcomes)[number];
type DraftFlow = { id: number; day: string; value: string };
type DraftScenario = { day: string; nav: string; distributions: DraftFlow[] };

const newScenario = (): DraftScenario => ({ day: "", nav: "", distributions: [] });
const multiple = new Intl.NumberFormat("en-AU", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const percent = new Intl.NumberFormat("en-AU", { style: "percent", minimumFractionDigits: 2, maximumFractionDigits: 4 });

function parseFlows(rows: DraftFlow[]) {
  const flows = [];
  for (const { day, value } of rows) {
    if (!day && !value.trim()) continue;
    const amount = scenarioAmount(value);
    if (!day || amount === null || amount <= 0) return null;
    flows.push({ day, amount });
  }
  return flows;
}

function DateField({ label, value, onChange }: { label: string; value: string; onChange: (day: string) => void }) {
  const id = useId();
  return <Field label={label} htmlFor={id}>
    <Input type="date" id={id} value={value} onChange={(event) => onChange(event.target.value)} />
  </Field>;
}

function CashFlowEditor({ kind, rows, currency, onChange, nextID }: {
  kind: "Capital call" | "Distribution"; rows: DraftFlow[]; currency: string;
  onChange: (values: DraftFlow[]) => void; nextID: () => number;
}) {
  function update(id: number, patch: Partial<Omit<DraftFlow, "id">>) {
    onChange(rows.map((row) => row.id === id ? { ...row, ...patch } : row));
  }
  return <div className="space-y-2">
    {rows.map(({ id, day, value }, index) => {
      const label = `${kind} ${index + 1}`;
      return <div key={id} className="grid min-w-0 items-end gap-2 rounded-lg border border-border bg-surface-2 p-3 sm:grid-cols-[1fr_1fr_auto]">
        <DateField label={`${label} date`} value={day} onChange={(day) => update(id, { day })} />
        <DecimalField label={`${label} amount (${currency})`} value={value} onChange={(value) => update(id, { value })}
          error={value.trim() && (scenarioAmount(value) ?? 0) <= 0 ? "Enter a positive amount." : undefined} />
        <Button size="sm" variant="ghost" aria-label={`Remove ${label.toLowerCase()}`}
          onClick={() => onChange(rows.filter((row) => row.id !== id))}>Remove</Button>
      </div>;
    })}
    <Button size="sm" onClick={() => onChange([...rows, { id: nextID(), day: "", value: "" }])}>Add {kind.toLowerCase()}</Button>
  </div>;
}

export function FundScenarioCalculator({ deal, onClose }: { deal?: PrivateDeal; onClose: () => void }) {
  const round = deal?.round;
  const currencyID = useId();
  const sequence = useRef(1);
  const [currency, setCurrency] = useState(round?.currency ?? "AUD");
  const [calls, setCalls] = useState<DraftFlow[]>([{ id: 0, day: "", value: "" }]);
  const [drafts, setDrafts] = useState({ Bear: newScenario(), Base: newScenario(), Bull: newScenario() });
  const [selected, setSelected] = useState<Outcome>("Base");
  const draft = drafts[selected];
  const parsedCalls = parseFlows(calls);
  const scenarios = scenarioOutcomes.map((label) => {
    const { day, nav, distributions } = drafts[label];
    const parsedDistributions = parseFlows(distributions);
    const remaining = nav.trim() ? scenarioAmount(nav) : 0;
    const result = parsedCalls && parsedDistributions && remaining !== null && day
      ? fundScenario(parsedCalls, parsedDistributions, remaining, day) : null;
    const error = parsedDistributions === null ? "Enter a date and a positive amount for each distribution."
      : day && parsedCalls?.length && remaining !== null && !result
        ? "Check the projection date and enter distributions on or after the first capital call." : null;
    return { label, result, error };
  });
  const active = scenarios.find(({ label }) => label === selected);

  function updateDraft(patch: Partial<DraftScenario>) {
    setDrafts((current) => ({ ...current, [selected]: { ...current[selected], ...patch } }));
  }

  return <ScenarioDialog title="Fund cash-flow scenarios" onClose={onClose}>
    {round ? <div className="rounded-lg border border-border bg-surface-2 p-3 text-sm text-text-2">
      <p className="font-medium text-text">{round.company.name} · {round.stage}</p>
      <p>Currency {currency}</p>
      <SourceLink url={deal?.source_url}>Published disclosure</SourceLink>
    </div> : <Field label="Fund scenario currency" htmlFor={currencyID} className="max-w-36">
      <Select id={currencyID} value={currency} onChange={(event) => setCurrency(event.target.value)}>
        {scenarioCurrencies.map((code) => <option key={code}>{code}</option>)}
      </Select>
    </Field>}
    <section className="space-y-3">
      <h3 className="text-sm font-semibold">Capital calls</h3>
      <p className="text-xs text-text-2">Enter your cash flows in one currency. The same calls apply to all three scenarios. Include fees or taxes in the amounts if you want them reflected.</p>
      <CashFlowEditor kind="Capital call" rows={calls} currency={currency} onChange={setCalls} nextID={() => sequence.current++} />
      {parsedCalls === null && <p className="text-xs text-down">Enter a date and a positive amount for each capital call.</p>}
    </section>
    <section className="space-y-3 border-t border-border pt-4">
      <h3 className="text-sm font-semibold">Projection assumptions</h3>
      <Segmented label="Fund outcome" options={scenarioOutcomes.map((value) => ({ value, label: value }))}
        value={selected} onChange={setSelected} />
      <div className="grid gap-3 sm:grid-cols-2">
        <DateField label="Projection date" value={draft.day} onChange={(day) => updateDraft({ day })} />
        <DecimalField label={`Remaining NAV (${currency}, optional)`} value={draft.nav} onChange={(nav) => updateDraft({ nav })}
          error={draft.nav.trim() && scenarioAmount(draft.nav) === null ? "Enter a nonnegative value." : undefined} />
      </div>
      <p className="text-xs text-text-2">Leave remaining net asset value (NAV) blank to assume zero. Enter expected payouts as dated distributions.</p>
      <CashFlowEditor kind="Distribution" rows={draft.distributions} currency={currency}
        onChange={(distributions) => updateDraft({ distributions })} nextID={() => sequence.current++} />
      {active?.error && <p className="text-xs text-down" role="status">{active.error}</p>}
    </section>
    <section className="space-y-3 border-t border-border pt-4">
      <h3 className="text-sm font-semibold">Projected returns</h3>
      <p className="text-xs text-text-2">TVPI includes remaining NAV. DPI measures cash distributed. XIRR uses dated cash flows and the assumed NAV at the projection date.</p>
      <div className="grid gap-3 sm:grid-cols-3">
        {scenarios.map(({ label, result }) => <div key={label} className="min-w-0 space-y-2 rounded-lg border border-border bg-surface-2 p-3 text-xs">
          <h4 className="text-sm font-semibold">{label}</h4>
          {result ? <dl className="space-y-1">
            {[
              ["Paid in", amount(result.paidIn, currency)], ["Distributions", amount(result.distributions, currency)],
              ["TVPI", multiple.format(result.tvpi) + "×"], ["DPI", multiple.format(result.dpi) + "×"],
              ["XIRR", result.xirr === null ? "Unavailable" : percent.format(result.xirr)],
            ].map(([name, value]) => <div key={name} className="flex flex-wrap justify-between gap-x-2">
              <dt className="text-text-2">{name}</dt>
              <dd className="break-words font-medium tabular-nums"><output aria-label={`${label} ${name}`}>{value}</output></dd>
            </div>)}
          </dl> : <p className="text-text-2">Enter the cash flows and projection date.</p>}
        </div>)}
      </div>
    </section>
  </ScenarioDialog>;
}
