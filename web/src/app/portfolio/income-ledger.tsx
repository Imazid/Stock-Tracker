"use client";

import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input, Select } from "@/components/ui/Field";
import {
  amountUnits, cashAmount, incomeDay, incomeFields, incomeKinds, incomeMinDay, incomeMoney, incomeNotice,
  type IncomeActivity, type IncomeKind, type IncomeRow, type IncomeTotal,
} from "@/lib/portfolio-income";
import { browserSupabase } from "@/lib/supabase/client";
import { BrokerActivity } from "./broker-activity";
import { DividendReinvestments } from "./dividend-reinvestments";

type Draft = {
  paid_on: string;
  kind: IncomeKind;
  payer: string;
  account_label: string;
  currency: string;
  cash_received: string;
  gross_amount: string;
  withholding: string;
  franking_credit_aud: string;
  statement_reference: string;
};

const blank: Draft = {
  paid_on: "", kind: "dividend", payer: "", account_label: "", currency: "AUD", cash_received: "",
  gross_amount: "", withholding: "", franking_credit_aud: "", statement_reference: "",
};
const pageSize = 20;
const sydneyDay = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Australia/Sydney", dateStyle: "short" }).format(new Date());
const utcDay = (daysAgo: number) => new Date(Date.now() - daysAgo * 86_400_000).toISOString().slice(0, 10);
const amountFields = [
  ["cash_received", "Cash received"],
  ["gross_amount", "Gross payment (optional)"],
  ["withholding", "Withholding (optional)"],
  ["franking_credit_aud", "Franking credit in AUD (optional)"],
] as const;

function db() {
  const client = browserSupabase();
  if (!client) throw new Error("Accounts are unavailable.");
  return client;
}

function readPage(userId: string, from: string, through: string, page: number, signal: AbortSignal) {
  let query = db().from("portfolio_cash_income").select(incomeFields).eq("user_id", userId)
    .order("paid_on", { ascending: false }).order("id", { ascending: false })
    .range(page * pageSize, (page + 1) * pageSize).abortSignal(signal);
  if (from) query = query.gte("paid_on", from);
  if (through) query = query.lte("paid_on", through);
  return query.overrideTypes<IncomeRow[], { merge: false }>();
}

export function IncomeLedger({ userId }: { userId: string }) {
  const [from, setFrom] = useState("");
  const [through, setThrough] = useState("");
  const [page, setPage] = useState(0);
  const [formOpen, setFormOpen] = useState(false);
  const [showBroker, setShowBroker] = useState(false);
  const [brokerStart, setBrokerStart] = useState(() => utcDay(89));
  const [brokerEnd, setBrokerEnd] = useState(() => utcDay(0));
  const [draft, setDraft] = useState(blank);
  const [activity, setActivity] = useState<IncomeActivity>();
  const [editing, setEditing] = useState<IncomeRow>();
  const [removing, setRemoving] = useState<IncomeRow>();
  const [feedback, setFeedback] = useState("");
  const [error, setError] = useState("");
  const cache = useQueryClient();
  const today = sydneyDay();
  const validRange = (!from || (incomeDay(from) && from <= today)) &&
    (!through || (incomeDay(through) && through <= today)) && (!from || !through || from <= through);
  const rows = useQuery({
    queryKey: ["portfolio-income", userId, from, through, page],
    enabled: Boolean(validRange),
    queryFn: async ({ signal }) => {
      const { data, error } = await readPage(userId, from, through, page, signal);
      if (error) throw new Error("Couldn’t load cash income records.");
      return data;
    },
  });
  const totals = useQuery({
    queryKey: ["portfolio-income", userId, "totals", from, through],
    enabled: Boolean(validRange),
    queryFn: async ({ signal }) => {
      const { data, error } = await db().rpc("portfolio_cash_income_totals", {
        p_from: from || null, p_through: through || null,
      }).abortSignal(signal);
      if (error || !Array.isArray(data)) throw new Error("Couldn’t load cash income totals.");
      return data as IncomeTotal[];
    },
  });

  function resetForm() {
    setFormOpen(false);
    setShowBroker(false);
    setEditing(undefined);
    setActivity(undefined);
    setDraft(blank);
  }

  const save = useMutation({
    mutationFn: async ({ draft, editing, activity }: { draft: Draft; editing?: IncomeRow; activity?: IncomeActivity }) => {
      if (!incomeDay(draft.paid_on) || draft.paid_on > today || !draft.payer.trim() || !/^[A-Z]{3}$/.test(draft.currency)) {
        throw new Error("Enter a payment date, payer and three-letter currency code.");
      }
      const { cash_received, gross_amount, withholding, franking_credit_aud } = draft;
      if (!cashAmount.test(cash_received) || amountUnits(cash_received) === 0n ||
          [gross_amount, withholding, franking_credit_aud].some((amount) => amount && !cashAmount.test(amount))) {
        throw new Error("Enter a positive cash amount and use up to eight decimal places.");
      }
      if (gross_amount && amountUnits(cash_received) + amountUnits(withholding || "0") > amountUnits(gross_amount)) {
        throw new Error("Gross payment must cover cash received plus any withholding recorded in that currency.");
      }
      const values = { ...draft, payer: draft.payer.trim(), account_label: draft.account_label.trim(),
        statement_reference: draft.statement_reference.trim(), gross_amount: gross_amount || null,
        withholding: withholding || null, franking_credit_aud: franking_credit_aud || null };
      const table = db().from("portfolio_cash_income");
      const write = editing
        ? table.update(values).eq("user_id", userId).eq("id", editing.id).eq("updated_at", editing.updated_at)
        : table.insert({ ...values, user_id: userId, ...(activity && {
          snaptrade_activity_id: activity.id, snaptrade_reported_on: activity.date,
          snaptrade_reported_currency: activity.currency, snaptrade_reported_amount: activity.amount,
        }) });
      const { data, error } = await write.select("id").maybeSingle();
      if (error?.code === "23505") throw new Error("This SnapTrade payment is already recorded.");
      if (error) throw new Error("Couldn’t save the payment. Try again.");
      if (!data) throw new Error("This payment changed elsewhere. Refresh the list and try again.");
    },
    onSuccess: async (_, { draft }) => {
      if ((from && draft.paid_on < from) || (through && draft.paid_on > through)) {
        setFrom("");
        setThrough("");
      }
      setPage(0);
      resetForm();
      setFeedback("Payment saved.");
      await cache.invalidateQueries({ queryKey: ["portfolio-income", userId] });
    },
    onError: (error) => setError(error.message),
  });
  const remove = useMutation({
    mutationFn: async (row: IncomeRow) => {
      const { data, error } = await db().from("portfolio_cash_income").delete()
        .eq("user_id", userId).eq("id", row.id).eq("updated_at", row.updated_at).select("id").maybeSingle();
      if (error) throw new Error("Couldn’t remove the payment. Try again.");
      if (!data) throw new Error("This payment changed elsewhere. Refresh the list and try again.");
    },
    onSuccess: async (_, row) => {
      if (editing?.id === row.id) resetForm();
      setRemoving(undefined);
      setFeedback("Payment removed.");
      if (page > 0 && rows.data?.length === 1) setPage((current) => Math.max(0, current - 1));
      await cache.invalidateQueries({ queryKey: ["portfolio-income", userId] });
    },
    onError: (error) => setError(error.message),
  });
  const busy = save.isPending || remove.isPending;
  const query = new URLSearchParams();
  if (from) query.set("from", from);
  if (through) query.set("through", through);

  function edit(row: IncomeRow) {
    setEditing(row);
    setRemoving(undefined);
    setActivity(undefined);
    setShowBroker(false);
    setDraft({
      paid_on: row.paid_on, kind: row.kind, payer: row.payer, account_label: row.account_label,
      currency: row.currency, cash_received: row.cash_received, gross_amount: row.gross_amount ?? "",
      withholding: row.withholding ?? "", franking_credit_aud: row.franking_credit_aud ?? "", statement_reference: row.statement_reference,
    });
    setFormOpen(true);
    setError("");
    setFeedback("");
    requestAnimationFrame(() => document.getElementById("income-paid-on")?.focus());
  }

  function review(source: IncomeActivity) {
    setActivity(source);
    setDraft((current) => ({
      ...current, kind: source.kind, paid_on: current.paid_on || source.date,
      payer: current.payer || source.symbol || "", currency: current.cash_received ? current.currency : source.currency,
      account_label: current.account_label || source.account.slice(0, 100),
    }));
    setError("");
    document.getElementById("income-cash_received")?.focus();
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setFeedback("");
    save.mutate({ draft, editing, activity });
  }

  return <Card>
    <CardHeader title="Dividends and distributions" subtitle="Statement payments and reinvestments in their original currencies." />
    <div className="space-y-4 border-t border-border p-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Payments from" htmlFor="income-from">
          <Input id="income-from" type="date" min={incomeMinDay} max={through || today} value={from}
            onChange={(event) => { setFrom(event.target.value); setPage(0); }} />
        </Field>
        <Field label="Payments through" htmlFor="income-through">
          <Input id="income-through" type="date" min={from || incomeMinDay} max={today} value={through}
            onChange={(event) => { setThrough(event.target.value); setPage(0); }} />
        </Field>
      </div>
      {!validRange && <p role="alert" className="text-sm text-down">Choose valid payment dates in chronological order.</p>}
      {validRange && (rows.isPending || totals.isPending) && <p role="status" className="text-sm text-text-2">Loading cash income…</p>}
      {(rows.isError || totals.isError) && <div className="flex flex-wrap items-center gap-2 text-sm">
        <p role="alert">Couldn’t load the cash income ledger.</p>
        <Button size="sm" onClick={() => { void rows.refetch(); void totals.refetch(); }}>Retry</Button>
      </div>}
      {validRange && totals.data && totals.data.length > 0 && <dl className="grid gap-3 sm:grid-cols-3" aria-label="Cash received by currency">
        {totals.data.map((total) => <div key={total.currency} className="rounded-lg border border-border p-3">
          <dt className="text-xs text-text-2">{total.currency} cash received</dt>
          <dd className="break-words text-lg font-semibold tabular">{incomeMoney(total.cash_received, total.currency)}</dd>
          <dd className="text-xs text-text-2">{total.payments} {total.payments === 1 ? "payment" : "payments"}</dd>
        </div>)}
      </dl>}
      {validRange && rows.data?.length === 0 && <p className="text-sm text-text-2">No recorded payments in this date range.</p>}
      {validRange && rows.data && rows.data.length > 0 && <ul className="divide-y divide-border rounded-lg border border-border">
        {rows.data.slice(0, pageSize).map((row) => <li key={row.id} className="flex flex-wrap items-center justify-between gap-2 p-3">
          <div className="min-w-0 [overflow-wrap:anywhere] text-sm">
            <p className="font-medium">{row.payer} · {incomeMoney(row.cash_received, row.currency)}</p>
            <p className="text-xs text-text-2">{[row.paid_on, incomeKinds[row.kind], row.account_label, row.snaptrade_activity_id ? "SnapTrade reference" : ""].filter(Boolean).join(" · ")}</p>
          </div>
          {removing?.id === row.id ? <div className="flex flex-wrap gap-2">
            <Button size="sm" disabled={busy} onClick={() => setRemoving(undefined)}>Cancel</Button>
            <Button size="sm" variant="danger" disabled={busy} onClick={() => { setError(""); setFeedback(""); remove.mutate(row); }}>Remove payment</Button>
          </div> : <div className="flex gap-2">
            <Button size="sm" disabled={busy} onClick={() => edit(row)} aria-label={`Edit ${row.payer} payment on ${row.paid_on}`}>Edit</Button>
            <Button size="sm" disabled={busy} onClick={() => setRemoving(row)} aria-label={`Remove ${row.payer} payment on ${row.paid_on}`}>Remove</Button>
          </div>}
        </li>)}
      </ul>}
      {validRange && (page > 0 || (rows.data?.length ?? 0) > pageSize) && <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={!page} onClick={() => setPage(page - 1)}>Previous payments</Button>
        <Button size="sm" disabled={(rows.data?.length ?? 0) <= pageSize} onClick={() => setPage(page + 1)}>More payments</Button>
      </div>}
      <div className="flex flex-wrap items-center gap-3">
        {!formOpen && <Button size="sm" disabled={busy} onClick={() => { setFormOpen(true); setError(""); setFeedback(""); }}>Record cash payment</Button>}
        {validRange && <a className="text-sm text-primary-fg underline" href={`/api/portfolio/income?${query}`}>Download cash income CSV</a>}
      </div>
      {formOpen && <div className="space-y-3 rounded-lg border border-border p-3">
        <h3 className="text-sm font-semibold">{editing ? "Edit cash payment" : "Record cash payment"}</h3>
        {!editing && <Button size="sm" aria-expanded={showBroker} onClick={() => setShowBroker(!showBroker)}>
          {showBroker ? "Hide brokerage lookup" : "Find payments in linked accounts"}
        </Button>}
        {showBroker && <div className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="First broker payment date" htmlFor="income-broker-from">
              <Input id="income-broker-from" type="date" min={incomeMinDay} max={brokerEnd || today} value={brokerStart}
                onChange={(event) => setBrokerStart(event.target.value)} />
            </Field>
            <Field label="Last broker payment date" htmlFor="income-broker-through">
              <Input id="income-broker-through" type="date" min={brokerStart || incomeMinDay} max={today} value={brokerEnd}
                onChange={(event) => setBrokerEnd(event.target.value)} />
            </Field>
          </div>
          {incomeDay(brokerStart) && incomeDay(brokerEnd) && brokerStart <= brokerEnd && brokerEnd <= today
            ? <BrokerActivity key={`${brokerStart}/${brokerEnd}`} mode="income" start={brokerStart} end={brokerEnd}
                selectedId={activity?.id} canInclude={!busy && !activity}
                imported={new Set(rows.data?.flatMap((row) => row.snaptrade_activity_id ? [row.snaptrade_activity_id] : []))}
                onReview={review} />
            : <p className="text-sm text-text-2">Choose a valid range of broker payment dates.</p>}
        </div>}
        <form aria-label={editing ? "Edit cash payment" : "Record cash payment"} onSubmit={submit}>
          <fieldset disabled={busy} className="space-y-3">
            {activity && <div className="flex flex-wrap items-center justify-between gap-2">
              <p role="status" className="text-sm text-text-2">SnapTrade reported {incomeMoney(activity.amount, activity.currency)} on {activity.date}. Enter the cash received from your statement.</p>
              <Button size="sm" onClick={() => setActivity(undefined)}>Clear broker reference</Button>
            </div>}
            {editing?.snaptrade_activity_id && editing.snaptrade_reported_amount && editing.snaptrade_reported_currency &&
              <p className="text-sm text-text-2">SnapTrade reported {incomeMoney(editing.snaptrade_reported_amount, editing.snaptrade_reported_currency)} on {editing.snaptrade_reported_on}.</p>}
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Payment date (Sydney)" htmlFor="income-paid-on">
                <Input id="income-paid-on" type="date" min={incomeMinDay} max={today} required value={draft.paid_on}
                  onChange={(event) => setDraft({ ...draft, paid_on: event.target.value })} />
              </Field>
              <Field label="Payment type" htmlFor="income-kind">
                <Select id="income-kind" value={draft.kind} onChange={(event) => setDraft({ ...draft, kind: event.target.value as IncomeKind })}>
                  {Object.entries(incomeKinds).map(([kind, label]) => <option key={kind} value={kind}>{label}</option>)}
                </Select>
              </Field>
              <Field label="Payer or ticker" htmlFor="income-payer">
                <Input id="income-payer" required maxLength={100} value={draft.payer}
                  onChange={(event) => setDraft({ ...draft, payer: event.target.value })} />
              </Field>
              <Field label="Account label (optional)" htmlFor="income-account">
                <Input id="income-account" maxLength={100} value={draft.account_label}
                  onChange={(event) => setDraft({ ...draft, account_label: event.target.value })} />
              </Field>
              <Field label="Payment currency" htmlFor="income-currency">
                <Input id="income-currency" required pattern="[A-Z]{3}" maxLength={3} value={draft.currency}
                  onChange={(event) => setDraft({ ...draft, currency: event.target.value.toUpperCase() })} />
              </Field>
              {amountFields.map(([key, label]) => <Field key={key} label={label} htmlFor={`income-${key}`}>
                <Input id={`income-${key}`} inputMode="decimal" maxLength={21} required={key === "cash_received"}
                  pattern={cashAmount.source} value={draft[key]} onChange={(event) => setDraft({ ...draft, [key]: event.target.value })} />
              </Field>)}
              <Field label="Statement reference (optional)" htmlFor="income-reference">
                <Input id="income-reference" maxLength={200} value={draft.statement_reference}
                  onChange={(event) => setDraft({ ...draft, statement_reference: event.target.value })} />
              </Field>
            </div>
            <p className="text-xs text-text-2">Enter gross payment and withholding in the payment currency when your statement provides them.</p>
            <div className="flex flex-wrap gap-2">
              <Button type="submit" size="sm" variant="primary">{editing ? "Save changes" : "Save cash payment"}</Button>
              <Button size="sm" onClick={() => { resetForm(); setError(""); }}>Cancel</Button>
            </div>
          </fieldset>
        </form>
      </div>}
      {error && <p role="alert" className="text-sm text-down">{error}</p>}
      {feedback && <p role="status" className="text-sm text-text-2">{feedback}</p>}
      <p className="text-xs text-text-2">{incomeNotice}</p>
    </div>
    <DividendReinvestments userId={userId} />
  </Card>;
}
