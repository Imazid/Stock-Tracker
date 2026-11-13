"use client";

import Link from "next/link";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, Select } from "@/components/ui/Field";
import { cashAmount, type IncomeActivity, type IncomeKind } from "@/lib/portfolio-income";
import type { SplitActivity } from "@/lib/portfolio-splits";
import { service } from "@/workspace/lib/backend";

type Account = { id: string; name?: string; institution_name?: string; number?: string };

export type HistoricalFx = { source: "ECB"; currency: string; amount: string; usd_per_unit: string; rate_date: string };
export type BrokerCashFlow = { date: string; kind: "deposit" | "withdrawal"; amount: number; snaptrade_id: string; fx?: HistoricalFx };
type ForeignCashFlow = Omit<BrokerCashFlow, "snaptrade_id" | "amount" | "fx"> & { amount: string; currency: string };
type Conversion = { usdAmount: number; fx: HistoricalFx };

type Activity = {
  id: string;
  date: string;
  label: string;
  amount: number | null;
  currency: string | null;
  units: number | null;
  fee: number | null;
  symbol: string | null;
  cashFlow: Omit<BrokerCashFlow, "snaptrade_id"> | null;
  foreignCashFlow?: ForeignCashFlow | null;
};
type Page = { activities: Activity[]; omitted: number; nextOffset: number | null; snapshot?: string; syncedAt?: string };

type ReviewMode = { imported: ReadonlySet<string>; canInclude: boolean } & (
  { mode: "cash"; onInclude: (flow: BrokerCashFlow) => void } |
  { mode: "splits"; selectedId?: string; onReview: (activity: SplitActivity) => void } |
  { mode: "income"; selectedId?: string; onReview: (activity: IncomeActivity) => void }
);

function isSplitActivity(activity: Activity): activity is Activity & SplitActivity {
  return activity.label === "Stock split" || activity.label === "Reverse stock split";
}

function incomeKind(label: string): IncomeKind | undefined {
  switch (label) {
    case "Dividend": return "dividend";
    case "Distribution": return "distribution";
    case "Substitute dividend": return "substitute_dividend";
  }
}

function brokerAccountLabel(account: Account) {
  return [account.name || account.institution_name || "Brokerage account", account.number?.slice(-4)].filter(Boolean).join(" · ");
}

function quantity(value: number | string, currency?: string | null) {
  return [new Intl.NumberFormat(undefined, { maximumFractionDigits: 12 }).format(Number(value)), currency].filter(Boolean).join(" ");
}

export function conversionDetails(fx: HistoricalFx) {
  return `${quantity(fx.amount, fx.currency)} · ${fx.usd_per_unit} USD per ${fx.currency} · ECB ${fx.rate_date}`;
}

export function BrokerActivity({ start, end, ...review }: { start: string; end: string } & ReviewMode) {
  const [accounts, setAccounts] = useState<Account[]>();
  const [accountId, setAccountId] = useState("");
  const [page, setPage] = useState<Page>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [conversions, setConversions] = useState<Record<string, Conversion>>({});
  const [lookup, setLookup] = useState<string>();
  const [fxError, setFxError] = useState<{ id: string; message: string }>();

  async function convert(activity: Activity) {
    if (!activity.foreignCashFlow || lookup) return;
    const { currency, date, amount } = activity.foreignCashFlow;
    setLookup(activity.id);
    setFxError(undefined);
    try {
      const result = await service<Conversion>("market", { action: "historicalFx", currency, date, amount });
      setConversions((current) => ({ ...current, [activity.id]: result }));
    } catch (failure) {
      setFxError({ id: activity.id, message: failure instanceof Error ? failure.message : "Historical exchange rate unavailable." });
    } finally {
      setLookup(undefined);
    }
  }

  async function loadAccounts() {
    setBusy(true);
    setError("");
    try {
      const { registered } = await service<{ registered: boolean }>("brokerage", { operation: "status" });
      const linked = registered ? await service<Account[]>("brokerage", { operation: "listAccounts" }) : [];
      setAccounts(linked);
      setAccountId(linked[0]?.id ?? "");
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : "Couldn’t load brokerage accounts.");
    } finally {
      setBusy(false);
    }
  }

  async function loadPage(offset: number, preferCached = true) {
    if (!accountId || !start || end < start || lookup) return;
    setBusy(true);
    setError("");
    if (!offset) { setConversions({}); setFxError(undefined); }
    try {
      const result = await service<Page>("brokerage", {
        operation: "accountActivities", params: { accountId, startDate: start, endDate: end, offset, preferCached, snapshot: offset ? page?.snapshot : undefined },
      });
      setPage((current) => {
        if (!offset || !current) return result;
        const rows = new Map(current.activities.map((activity) => [activity.id, activity]));
        for (const activity of result.activities) rows.set(activity.id, activity);
        return { ...result, omitted: current.omitted + result.omitted, activities: [...rows.values()] };
      });
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : "Couldn’t load brokerage activity.");
    } finally {
      setBusy(false);
    }
  }

  const nextOffset = page?.nextOffset ?? null;
  const accountField = `broker-account-${review.mode}`;
  const selectedAccount = accounts?.find((account) => account.id === accountId);
  const activities = page?.activities.filter((activity) => review.mode === "cash" ||
    (review.mode === "splits" ? isSplitActivity(activity) : incomeKind(activity.label)));
  const brokerTitles = { cash: "Broker activity", splits: "Broker-reported splits", income: "Broker-reported payments" };
  const emptyLabels = { cash: "cash or corporate activity", splits: "splits", income: "dividends or distributions" };

  return <fieldset className="space-y-3 rounded-md border border-border p-3">
    <legend className="px-1 text-sm font-medium">{brokerTitles[review.mode]}</legend>
    <p className="text-xs text-text-2">{review.mode === "splits"
      ? "Choose an event to bring its reference and reported date into the adjustment form. Confirm the holding, effective date and ratio against your statement."
      : review.mode === "income" ? "Select a reported payment, then enter the cash received from your statement. Review any prior manual entry for the same payment."
        : "Review reported activity for the selected dates. Include cash that entered or left the portfolio you valued. For a transfer between included accounts, leave both entries out. Check against transfers already entered from statements."}</p>
    {!accounts ? <Button size="sm" disabled={busy} onClick={() => void loadAccounts()}>Find linked accounts</Button>
      : accounts.length === 0 ? <p className="text-sm text-text-2">No linked brokerage accounts. <Link className="underline" href="/#settings">Open brokerage connections</Link></p>
      : <div className="flex flex-wrap items-end gap-2">
        <Field label="Brokerage account" htmlFor={accountField}>
          <Select id={accountField} disabled={busy || Boolean(lookup)} value={accountId} onChange={(event) => { setAccountId(event.target.value); setPage(undefined); setError(""); setConversions({}); setFxError(undefined); }}>
            {accounts.map((account) => <option key={account.id} value={account.id}>
              {brokerAccountLabel(account)}
            </option>)}
          </Select>
        </Field>
        <Button size="sm" disabled={busy || Boolean(lookup)} onClick={() => void loadPage(0)}>Load broker activity</Button>
      </div>}
    {busy && <p role="status" className="text-xs text-text-2">Loading brokerage data…</p>}
    {error && <p role="alert" className="text-sm text-down">{error}</p>}
    {page && <div className="space-y-2">
      {page.syncedAt && <div className="flex flex-wrap items-center gap-2">
        <p className="text-xs text-text-2">Imported {new Date(page.syncedAt).toLocaleString()}</p>
        <Button size="sm" disabled={busy || Boolean(lookup)} onClick={() => void loadPage(0, false)}>Fetch from broker</Button>
      </div>}
      <p className="text-xs text-text-2">SnapTrade refreshes activity daily.{review.mode === "cash" && " For foreign cash, you can look up an ECB reference rate or enter the USD amount from your statement."}</p>
      {page.omitted > 0 && <p role="status" className="text-xs text-warn">{page.omitted} records had missing or unsupported data. Check your statement for complete activity.</p>}
      {activities?.length === 0 && <p className="text-sm text-text-2">{nextOffset === null
        ? `No reported ${emptyLabels[review.mode]} in this date range.`
        : `No reported ${emptyLabels[review.mode]} on the loaded pages. Load more activity to keep looking.`}</p>}
      <ul className="divide-y divide-border">
        {activities?.map((activity) => {
          const included = review.imported.has(activity.id);
          if (review.mode === "splits") {
            if (!isSplitActivity(activity)) return null;
            const { id, date, label, symbol } = activity;
            const selected = review.selectedId === id;
            return <li key={id} className="flex flex-wrap items-center justify-between gap-2 py-2">
              <div className="min-w-0 [overflow-wrap:anywhere]">
                <p className="text-sm">{label}{symbol && ` · ${symbol}`}</p>
                <p className="text-xs text-text-2">Reported {date}</p>
              </div>
              <Button size="sm" disabled={busy || included || selected || !review.canInclude}
                aria-label={included || selected ? undefined : `Review split ${symbol ?? "event"} reported ${date}`}
                onClick={() => review.onReview({ id, date, label, symbol })}>
                {included ? "Already recorded" : selected ? "Selected" : "Review split"}
              </Button>
            </li>;
          }
          if (review.mode === "income") {
            const { id, date, label, symbol, currency } = activity;
            const kind = incomeKind(label);
            const amount = String(activity.amount);
            const selected = review.selectedId === id;
            const eligible = kind && currency && /^[A-Z]{3}$/.test(currency) && cashAmount.test(amount) && Number(amount) > 0;
            return <li key={id} className="flex flex-wrap items-center justify-between gap-2 py-2">
              <div className="min-w-0 [overflow-wrap:anywhere]">
                <p className="text-sm">{label}{symbol && ` · ${symbol}`}</p>
                <p className="text-xs text-text-2">{date}{activity.amount !== null && ` · Reported ${quantity(activity.amount, currency)}`}</p>
                {!eligible && <p className="text-xs text-text-2">Check the statement for a cash payment or reversal.</p>}
              </div>
              {eligible && <Button size="sm" disabled={busy || included || selected || !review.canInclude}
                aria-label={included || selected ? undefined : `Review ${label.toLowerCase()} ${symbol ?? "payment"} reported ${date}`}
                onClick={() => review.onReview({ id, date, kind, symbol, currency, amount,
                  account: selectedAccount ? brokerAccountLabel({ ...selectedAccount, name: undefined }) : "" })}>
                {included ? "Already recorded" : selected ? "Selected" : "Review payment"}
              </Button>}
            </li>;
          }
          const foreign = activity.foreignCashFlow;
          const converted = conversions[activity.id];
          const cashFlow = activity.cashFlow ?? (foreign && converted
            ? { date: foreign.date, kind: foreign.kind, amount: converted.usdAmount, fx: converted.fx } : null);
          return <li key={activity.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
            <div>
              <p className="text-sm">{activity.label}{activity.symbol && ` · ${activity.symbol}`}</p>
              <p className="text-xs text-text-2">
                {[activity.date, activity.amount !== null && quantity(activity.amount, activity.currency),
                  activity.units !== null && activity.units !== 0 && `${quantity(activity.units)} units`,
                  activity.fee !== null && activity.fee !== 0 && `Fee ${quantity(activity.fee, activity.currency)}`].filter(Boolean).join(" · ")}
              </p>
              {converted && <p className="text-xs text-text-2">{quantity(converted.usdAmount, "USD")} · {conversionDetails(converted.fx)}</p>}
              {fxError?.id === activity.id && <p className="text-xs text-down" role="alert">{fxError.message} You can enter the USD amount manually.</p>}
            </div>
            {foreign && !cashFlow && activity.date > start && !included && <Button size="sm"
              disabled={Boolean(lookup) || busy || !review.canInclude} onClick={() => void convert(activity)}>
              {lookup === activity.id ? "Looking up rate…" : "Look up USD value"}
            </Button>}
            {(cashFlow || included) && activity.date > start && <Button size="sm" disabled={included || !review.canInclude} aria-label={included ? "Already included" : `Include ${activity.label.toLowerCase()} on ${activity.date}`}
              onClick={() => { if (cashFlow) review.onInclude({ ...cashFlow, snaptrade_id: activity.id }); }}>
              {included ? "Included" : "Include transfer"}
            </Button>}
          </li>;
        })}
      </ul>
      {nextOffset !== null && <Button size="sm" disabled={busy || Boolean(lookup)} onClick={() => void loadPage(nextOffset)}>Load more activity</Button>}
    </div>}
  </fieldset>;
}
