"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, Input, Select } from "@/components/ui/Field";
import { Segmented } from "@/components/ui/Segmented";
import { dilutedOwnership, exitProceeds, pricedRoundOwnership, scenarioAmount, type ShareClass } from "@/lib/private-scenarios";
import { SourceLink } from "./catalog";
import { amount, type PrivateDeal } from "./private-data";

const outcomes = ["Bear", "Base", "Bull"] as const;
const currencies = ["AUD", "USD", "CAD", "EUR", "GBP", "JPY", "NZD", "SGD"];
const percent = new Intl.NumberFormat("en-AU", { style: "percent", minimumFractionDigits: 2, maximumFractionDigits: 4 });
const decimal = new Intl.NumberFormat("en-AU", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const formattedPercent = (value: number | null) => value === null ? "Unavailable" : percent.format(value);

function DecimalField({ label, value, onChange, error }: {
  label: string; value: string; onChange: (value: string) => void; error?: string;
}) {
  const id = useId();
  return <Field label={label} htmlFor={id}>
    <Input id={id} inputMode="decimal" maxLength={32} value={value} aria-invalid={Boolean(error)}
      aria-describedby={error ? id + "-error" : undefined} onChange={(event) => onChange(event.target.value)} />
    {error && <p id={id + "-error"} className="text-xs text-down">{error}</p>}
  </Field>;
}

export function ScenarioCalculator({ deal, onClose }: { deal?: PrivateDeal; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleID = useId();
  const currencyID = useId();
  const classID = useId();
  const round = deal?.round;
  const publishedPostMoney = round && /^post[- ]money(?: valuation)?$/i.test(round.valuation_method?.trim() ?? "")
    ? round.valuation : null;
  const [currency, setCurrency] = useState(round?.currency ?? "AUD");
  const [mode, setMode] = useState<"investment" | "stake">("investment");
  const [invested, setInvested] = useState("");
  const [postMoney, setPostMoney] = useState(publishedPostMoney?.toString() ?? "");
  const [stake, setStake] = useState("");
  const [newCapital, setNewCapital] = useState("");
  const [nextPostMoney, setNextPostMoney] = useState("");
  const [modelPreference, setModelPreference] = useState(false);
  const [shareClass, setShareClass] = useState<ShareClass>("common");
  const [preferredPercent, setPreferredPercent] = useState("");
  const [liquidationPreference, setLiquidationPreference] = useState("");
  const [participating, setParticipating] = useState(false);
  const [exits, setExits] = useState({ Bear: "", Base: "", Bull: "" });

  useEffect(() => {
    const element = dialog.current;
    if (element && !element.open) element.showModal();
  }, []);

  const investment = scenarioAmount(invested);
  const valuation = scenarioAmount(postMoney);
  const currentStake = scenarioAmount(stake);
  const before = mode === "stake"
    ? currentStake !== null && currentStake <= 100 ? currentStake / 100 : null
    : investment !== null && valuation !== null ? pricedRoundOwnership(investment, valuation) : null;
  const raise = scenarioAmount(newCapital);
  const nextValuation = scenarioAmount(nextPostMoney);
  const hasNextRound = Boolean(newCapital.trim() || nextPostMoney.trim());
  const after = !hasNextRound ? before :
    before !== null && raise !== null && nextValuation !== null ? dilutedOwnership(before, raise, nextValuation) : null;

  const preferredShare = scenarioAmount(preferredPercent);
  const totalPreference = scenarioAmount(liquidationPreference);
  const preference = modelPreference && preferredShare !== null && totalPreference !== null
    ? { shareClass, preferredShare: preferredShare / 100, totalPreference, participating } : undefined;
  const scenarios = outcomes.map((label) => {
    const value = scenarioAmount(exits[label]);
    const proceeds = value !== null && after !== null && (!modelPreference || preference)
      ? exitProceeds(value, after, preference) : null;
    const multiple = mode === "investment" && proceeds !== null && investment ? proceeds / investment : null;
    return { label, value, proceeds, multiple };
  });
  const highest = Math.max(0, ...scenarios.map(({ proceeds }) => proceeds ?? 0));

  function money(value: number) {
    return currency + " " + decimal.format(value);
  }

  return <dialog ref={dialog} onClose={onClose} aria-labelledby={titleID}
    className="m-auto max-h-[calc(100dvh-1.5rem)] w-[min(46rem,calc(100vw-1.5rem))] rounded-xl border border-border-strong bg-surface p-0 text-text shadow-2xl backdrop:bg-black/60">
    <header className="sticky top-0 z-10 flex items-center justify-between gap-2 border-b border-border bg-surface px-4 py-3 sm:px-6">
      <h2 id={titleID} className="text-base font-semibold">Scenario calculator</h2>
      <Button size="sm" onClick={() => dialog.current?.close()}>Close</Button>
    </header>
    <div className="space-y-5 p-4 sm:p-6">
      {round ? <div className="rounded-lg border border-border bg-surface-2 p-3 text-sm text-text-2">
        <p className="font-medium text-text">{round.company.name} · {round.stage}</p>
        <p>{round.valuation === null ? `Currency ${round.currency}` : `${amount(round.valuation, round.currency)} disclosed valuation`}</p>
        {round.valuation_method && <p>{round.valuation_method}</p>}
        <SourceLink url={deal?.source_url}>Round disclosure</SourceLink>
      </div> : <Field label="Scenario currency" htmlFor={currencyID} className="max-w-36">
        <Select id={currencyID} value={currency} onChange={(event) => setCurrency(event.target.value)}>
          {currencies.map((code) => <option key={code}>{code}</option>)}
        </Select>
      </Field>}
      <section className="space-y-3">
        <h3 className="text-sm font-semibold">Initial ownership</h3>
        <Segmented label="Starting position" value={mode} onChange={setMode}
          options={[{ value: "investment", label: "New investment" }, { value: "stake", label: "Existing stake" }]} />
        <div className="grid min-w-0 gap-3 sm:grid-cols-2">
          {mode === "stake" ? <DecimalField label="Existing ownership (%)" value={stake} onChange={setStake}
            error={stake.trim() && before === null ? "Enter a percentage from 0 to 100." : undefined} /> : <>
            <DecimalField label={`Investment amount (${currency})`} value={invested} onChange={setInvested}
              error={invested.trim() && (investment === null || investment === 0) ? "Enter a positive amount." : undefined} />
            <DecimalField label={`Post-money valuation (${currency})`} value={postMoney} onChange={setPostMoney}
              error={postMoney.trim() && (valuation === null || valuation === 0 || (investment !== null && investment > valuation))
                ? "Enter a positive valuation at least as large as the investment." : undefined} />
          </>}
        </div>
        <p className="text-sm text-text-2">Initial ownership <output className="ml-1 font-semibold tabular-nums text-text" aria-label="Initial ownership">{formattedPercent(before)}</output></p>
      </section>
      <section className="space-y-3 border-t border-border pt-4">
        <h3 className="text-sm font-semibold">Next funding round <span className="font-normal text-text-3">(optional)</span></h3>
        <div className="grid min-w-0 gap-3 sm:grid-cols-2">
          <DecimalField label={`New capital raised (${currency})`} value={newCapital} onChange={setNewCapital}
            error={newCapital.trim() && raise === null ? "Enter a nonnegative amount." : undefined} />
          <DecimalField label={`Next post-money valuation (${currency})`} value={nextPostMoney} onChange={setNextPostMoney}
            error={nextPostMoney.trim() && (nextValuation === null || nextValuation === 0 || (raise !== null && raise >= nextValuation))
              ? "Enter a valuation greater than the new capital raised." : undefined} />
        </div>
        {hasNextRound && (!newCapital.trim() || !nextPostMoney.trim()) && <p className="text-xs text-text-2">Enter both next-round amounts to calculate dilution.</p>}
        <p className="text-sm text-text-2">Ownership after round <output className="ml-1 font-semibold tabular-nums text-text" aria-label="Ownership after round">{formattedPercent(after)}</output></p>
        <p className="text-xs text-text-3">Assumes the investor sits out the next round and the option pool and convertible securities stay unchanged.</p>
      </section>
      <section className="space-y-3 border-t border-border pt-4">
        <h3 className="text-sm font-semibold">Payout terms</h3>
        <label className="flex items-center gap-2 text-sm text-text-2">
          <input type="checkbox" checked={modelPreference} onChange={(event) => setModelPreference(event.target.checked)} />
          Model a preferred share class
        </label>
        {modelPreference && <>
          <div className="grid min-w-0 gap-3 sm:grid-cols-2">
            <Field label="Your share class" htmlFor={classID}>
              <Select id={classID} value={shareClass} onChange={(event) => setShareClass(event.target.value === "preferred" ? "preferred" : "common")}>
                <option value="common">Common</option>
                <option value="preferred">Preferred</option>
              </Select>
            </Field>
            <DecimalField label="Preferred ownership at exit (%)" value={preferredPercent} onChange={setPreferredPercent}
              error={preferredPercent.trim() && (preferredShare === null || preferredShare <= 0 || preferredShare >= 100)
                ? "Enter a percentage greater than 0 and below 100." : undefined} />
            <DecimalField label={`Total liquidation preference (${currency})`} value={liquidationPreference} onChange={setLiquidationPreference}
              error={liquidationPreference.trim() && totalPreference === null ? "Enter a nonnegative amount." : undefined} />
          </div>
          <label className="flex items-center gap-2 text-sm text-text-2">
            <input type="checkbox" checked={participating} onChange={(event) => setParticipating(event.target.checked)} />
            Participating preferred
          </label>
        </>}
        <p className="text-xs text-text-3">Use exit equity value after debt. {modelPreference
          ? "The model assumes equal terms within one preferred class and uncapped participation when selected."
          : "Proceeds follow the ownership percentage."} Use one currency throughout. Fees and taxes are excluded.</p>
      </section>
      <section className="space-y-3 border-t border-border pt-4">
        <h3 className="text-sm font-semibold">Assumed exit values</h3>
        <div className="grid gap-3 sm:grid-cols-3">
          {scenarios.map(({ label, value, proceeds, multiple }) => <div key={label} className="min-w-0 space-y-2 rounded-lg border border-border bg-surface-2 p-3">
            <DecimalField label={`${label} exit value (${currency})`} value={exits[label]}
              onChange={(value) => setExits((current) => ({ ...current, [label]: value }))}
              error={exits[label].trim() && value === null ? "Enter a nonnegative exit value." : undefined} />
            {proceeds !== null ? <>
              <div aria-hidden className="h-1.5 overflow-hidden rounded-full bg-surface-3">
                <div className="h-full rounded-full bg-primary" style={{ width: `${highest > 0 ? proceeds / highest * 100 : 0}%` }} />
              </div>
              <output aria-label={`${label} proceeds`} className="block break-words text-sm font-semibold tabular-nums">
                {money(proceeds)}
                {multiple !== null && Number.isFinite(multiple) && <span className="ml-1 text-xs text-text-3">{decimal.format(multiple)}×</span>}
              </output>
            </> : value !== null &&
              <p className="text-xs text-text-2">Check the ownership and payout terms to calculate proceeds.</p>}
          </div>)}
        </div>
      </section>
    </div>
  </dialog>;
}
