"use client";

import Link from "next/link";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, Select } from "@/components/ui/Field";
import { service } from "@/workspace/lib/backend";

type Account = { id: string; name?: string; institution_name?: string; number?: string };

export type BrokerCashFlow = { date: string; kind: "deposit" | "withdrawal"; amount: number; snaptrade_id: string };

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
};
type Page = { activities: Activity[]; omitted: number; nextOffset: number | null };

function quantity(value: number, currency?: string | null) {
  return [new Intl.NumberFormat(undefined, { maximumFractionDigits: 12 }).format(value), currency].filter(Boolean).join(" ");
}

export function BrokerActivity({ start, end, imported, canInclude, onInclude }: {
  start: string;
  end: string;
  imported: ReadonlySet<string>;
  canInclude: boolean;
  onInclude: (flow: BrokerCashFlow) => void;
}) {
  const [accounts, setAccounts] = useState<Account[]>();
  const [accountId, setAccountId] = useState("");
  const [page, setPage] = useState<Page>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

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

  async function loadPage(offset: number) {
    if (!accountId || !start || end <= start) return;
    setBusy(true);
    setError("");
    try {
      const result = await service<Page>("brokerage", {
        operation: "accountActivities", params: { accountId, startDate: start, endDate: end, offset },
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

  return <fieldset className="space-y-3 rounded-md border border-border p-3">
    <legend className="px-1 text-sm font-medium">Broker activity</legend>
    <p className="text-xs text-text-2">Review reported activity for the selected dates. Include cash that entered or left the portfolio you valued. For a transfer between included accounts, leave both entries out. Check against transfers already entered from statements.</p>
    {!accounts ? <Button size="sm" disabled={busy} onClick={() => void loadAccounts()}>Find linked accounts</Button>
      : accounts.length === 0 ? <p className="text-sm text-text-2">No linked brokerage accounts. <Link className="underline" href="/#settings">Open brokerage connections</Link></p>
      : <div className="flex flex-wrap items-end gap-2">
        <Field label="Brokerage account" htmlFor="returns-broker-account">
          <Select id="returns-broker-account" disabled={busy} value={accountId} onChange={(event) => { setAccountId(event.target.value); setPage(undefined); setError(""); }}>
            {accounts.map((account) => <option key={account.id} value={account.id}>
              {[account.name || account.institution_name || "Brokerage account", account.number?.slice(-4)].filter(Boolean).join(" · ")}
            </option>)}
          </Select>
        </Field>
        <Button size="sm" disabled={busy} onClick={() => void loadPage(0)}>Load broker activity</Button>
      </div>}
    {busy && <p role="status" className="text-xs text-text-2">Loading brokerage data…</p>}
    {error && <p role="alert" className="text-sm text-down">{error}</p>}
    {page && <div className="space-y-2">
      <p className="text-xs text-text-2">SnapTrade refreshes activity daily. For cash in other currencies, use the USD amount from your statement or convert at the activity date before adding it manually.</p>
      {page.omitted > 0 && <p role="status" className="text-xs text-warn">{page.omitted} records had missing or unsupported data. Check your statement for complete activity.</p>}
      {page.activities.length === 0 && <p className="text-sm text-text-2">No reported cash or corporate activity in this date range.</p>}
      <ul className="divide-y divide-border">
        {page.activities.map((activity) => {
          const available = activity.cashFlow && activity.date > start;
          const included = imported.has(activity.id);
          return <li key={activity.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
            <div>
              <p className="text-sm">{activity.label}{activity.symbol && ` · ${activity.symbol}`}</p>
              <p className="text-xs text-text-2">
                {[activity.date, activity.amount !== null && quantity(activity.amount, activity.currency),
                  activity.units !== null && activity.units !== 0 && `${quantity(activity.units)} units`,
                  activity.fee !== null && activity.fee !== 0 && `Fee ${quantity(activity.fee, activity.currency)}`].filter(Boolean).join(" · ")}
              </p>
            </div>
            {available && <Button size="sm" disabled={included || !canInclude} aria-label={included ? "Already included" : `Include ${activity.label.toLowerCase()} on ${activity.date}`}
              onClick={() => { if (activity.cashFlow) onInclude({ ...activity.cashFlow, snaptrade_id: activity.id }); }}>
              {included ? "Included" : "Include transfer"}
            </Button>}
          </li>;
        })}
      </ul>
      {nextOffset !== null && <Button size="sm" disabled={busy} onClick={() => void loadPage(nextOffset)}>Load more activity</Button>}
    </div>}
  </fieldset>;
}
