"use client";

import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Field, Input, Select } from "@/components/ui/Field";
import { amountUnits, cashAmount, incomeDay, incomeMinDay, incomeMoney } from "@/lib/portfolio-income";
import { reinvestmentFields, reinvestmentShares, type Reinvestment } from "@/lib/portfolio-reinvestments";
import { browserSupabase } from "@/lib/supabase/client";

type Holding = { id: string; asset_symbol: string; asset_exchange: string | null; deleted_at: string | null };
type Draft = {
  holding_id: string; paid_on: string; acquired_on: string; currency: string; dividend_amount: string;
  reinvested_amount: string; shares: string; basis_usd: string; franking_credit_aud: string; statement_reference: string;
};
const blank: Draft = {
  holding_id: "", paid_on: "", acquired_on: "", currency: "AUD", dividend_amount: "",
  reinvested_amount: "", shares: "", basis_usd: "", franking_credit_aud: "", statement_reference: "",
};
const moneyFields = [
  ["dividend_amount", "Dividend amount"], ["reinvested_amount", "Amount applied to shares"],
  ["basis_usd", "Acquisition basis in USD (optional)"], ["franking_credit_aud", "Franking credit in AUD (optional)"],
] as const;

function db() {
  const client = browserSupabase();
  if (!client) throw new Error("Accounts are unavailable.");
  return client;
}

async function loadRecords(userId: string, signal: AbortSignal) {
  const [holdings, entries] = await Promise.all([
    db().from("portfolio_holdings").select("id,asset_symbol,asset_exchange,deleted_at")
      .eq("user_id", userId).eq("asset_kind", "Stock").order("asset_symbol").order("id").limit(1000)
      .abortSignal(signal).overrideTypes<Holding[], { merge: false }>(),
    db().from("portfolio_dividend_reinvestments").select(reinvestmentFields).eq("user_id", userId)
      .order("acquired_on", { ascending: false }).order("id").limit(1000)
      .abortSignal(signal).overrideTypes<Reinvestment[], { merge: false }>(),
  ]);
  if (holdings.error || entries.error) throw new Error("Couldn’t load reinvestments.");
  return { holdings: holdings.data, entries: entries.data };
}

export function DividendReinvestments({ userId }: { userId: string }) {
  const [expanded, setExpanded] = useState(false);
  const [draft, setDraft] = useState(blank);
  const [editing, setEditing] = useState<Reinvestment>();
  const [removing, setRemoving] = useState<Reinvestment>();
  const [feedback, setFeedback] = useState("");
  const [error, setError] = useState("");
  const cache = useQueryClient();
  const queryKey = ["portfolio-dividend-reinvestments", userId];
  const records = useQuery({ queryKey, queryFn: ({ signal }) => loadRecords(userId, signal), enabled: expanded });
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Australia/Sydney", dateStyle: "short" }).format(new Date());

  function clearMessages() {
    setError("");
    setFeedback("");
  }

  const save = useMutation({
    mutationFn: async () => {
      const { holding_id, paid_on, acquired_on, currency, dividend_amount, reinvested_amount, shares, basis_usd, franking_credit_aud } = draft;
      if (!holding_id || !incomeDay(paid_on) || !incomeDay(acquired_on) || paid_on > today || acquired_on > today || !/^[A-Z]{3}$/.test(currency)) {
        throw new Error("Choose the holding, statement dates and payment currency.");
      }
      if (![dividend_amount, reinvested_amount].every((amount) => cashAmount.test(amount) && amountUnits(amount) > 0n) ||
          !reinvestmentShares.test(shares) || !/[1-9]/.test(shares) ||
          (basis_usd && (!cashAmount.test(basis_usd) || amountUnits(basis_usd) === 0n)) ||
          (franking_credit_aud && !cashAmount.test(franking_credit_aud))) {
        throw new Error("Enter positive amounts and a positive quantity. Use up to eight decimals for amounts and 18 for shares.");
      }
      const values = { ...draft, basis_usd: currency === "USD" ? null : basis_usd || null,
        franking_credit_aud: franking_credit_aud || null, statement_reference: draft.statement_reference.trim() };
      const table = db().from("portfolio_dividend_reinvestments");
      const write = editing
        ? table.update(values).eq("id", editing.id).eq("user_id", userId).eq("updated_at", editing.updated_at)
        : table.insert({ ...values, user_id: userId });
      const { data, error } = await write.select("id").maybeSingle();
      if (error?.code === "23505") throw new Error("This reinvestment is already recorded. Edit the existing record to correct it.");
      if (error) throw new Error("Couldn’t save the reinvestment. Try again.");
      if (!data) throw new Error("This reinvestment changed elsewhere. Refresh the list and try again.");
    },
    onSuccess: async () => {
      setEditing(undefined);
      setDraft(blank);
      setFeedback("Reinvestment saved.");
      await cache.invalidateQueries({ queryKey });
    },
    onError: (error) => setError(error.message),
  });

  const remove = useMutation({
    mutationFn: async (entry: Reinvestment) => {
      const { data, error } = await db().from("portfolio_dividend_reinvestments").delete().eq("user_id", userId)
        .eq("id", entry.id).eq("updated_at", entry.updated_at).select("id").maybeSingle();
      if (error) throw new Error("Couldn’t remove the reinvestment. Try again.");
      if (!data) throw new Error("This reinvestment changed elsewhere. Refresh the list and try again.");
    },
    onSuccess: async (_, entry) => {
      setRemoving(undefined);
      if (editing?.id === entry.id) {
        setEditing(undefined);
        setDraft(blank);
      }
      setFeedback("Reinvestment removed.");
      await cache.invalidateQueries({ queryKey });
    },
    onError: (error) => setError(error.message),
  });
  const busy = save.isPending || remove.isPending;

  function edit(entry: Reinvestment) {
    clearMessages();
    setEditing(entry);
    setRemoving(undefined);
    setDraft({
      holding_id: entry.holding_id, paid_on: entry.paid_on, acquired_on: entry.acquired_on, currency: entry.currency,
      dividend_amount: entry.dividend_amount, reinvested_amount: entry.reinvested_amount, shares: entry.shares,
      basis_usd: entry.basis_usd ?? "", franking_credit_aud: entry.franking_credit_aud ?? "", statement_reference: entry.statement_reference,
    });
    document.getElementById("drp-holding")?.focus();
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    clearMessages();
    save.mutate();
  }

  return <section className="space-y-3 border-t border-border p-4" aria-label="Dividend reinvestments">
    <Button size="sm" aria-expanded={expanded} aria-controls="drp-controls" onClick={() => setExpanded(!expanded)}>
      {expanded ? "Hide dividend reinvestments" : "Manage dividend reinvestments"}
    </Button>
    {expanded && <div id="drp-controls" className="space-y-4">
      <p className="text-sm text-text-2">
        Record the dividend and the amount applied to new shares from your statement. The income CSV uses the payment date.
        The lot CSV uses the acquisition date and applies the shares after timestamped trades that day. Add acquisitions missing from your synced purchases.
      </p>
      {records.isPending && <p role="status" className="text-sm text-text-2">Loading reinvestments…</p>}
      {records.isError && <div className="flex flex-wrap items-center gap-2 text-sm">
        <p role="alert">{records.error.message}</p><Button size="sm" onClick={() => void records.refetch()}>Retry</Button>
      </div>}
      {records.data && records.data.entries.length > 0 && <ul className="divide-y divide-border rounded-lg border border-border">
        {records.data.entries.map((entry) => <li key={entry.id} className="flex flex-wrap items-center justify-between gap-2 p-3">
          <div className="min-w-0 [overflow-wrap:anywhere] text-sm">
            <p className="font-medium">{entry.portfolio_holdings?.asset_symbol ?? "Holding"} · {entry.shares} shares</p>
            <p className="text-xs text-text-2">{entry.acquired_on} · {incomeMoney(entry.reinvested_amount, entry.currency)} applied</p>
          </div>
          {removing?.id === entry.id ? <div className="flex flex-wrap gap-2">
            <Button size="sm" disabled={busy} onClick={() => setRemoving(undefined)}>Cancel</Button>
            <Button size="sm" variant="danger" disabled={busy} onClick={() => { clearMessages(); remove.mutate(entry); }}>Remove reinvestment</Button>
          </div> : <div className="flex gap-2">
            <Button size="sm" disabled={busy} onClick={() => edit(entry)}>Edit</Button>
            <Button size="sm" disabled={busy} onClick={() => setRemoving(entry)}>Remove</Button>
          </div>}
        </li>)}
      </ul>}
      {records.data?.holdings.length === 0 && <p className="text-sm text-text-2">Sync a stock holding to record a reinvestment.</p>}
      {records.data && records.data.holdings.length > 0 && <form aria-label="Record dividend reinvestment" onSubmit={submit}>
        <fieldset disabled={busy} className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Stock holding" htmlFor="drp-holding">
              <Select id="drp-holding" required value={draft.holding_id} onChange={(event) => setDraft({ ...draft, holding_id: event.target.value })}>
                <option value="">Choose a holding</option>
                {records.data.holdings.map((holding) => <option key={holding.id} value={holding.id}>
                  {[holding.asset_symbol, holding.asset_exchange, holding.deleted_at ? "Archived" : ""].filter(Boolean).join(" · ")}
                </option>)}
              </Select>
            </Field>
            <Field label="Dividend payment date (Sydney)" htmlFor="drp-paid">
              <Input id="drp-paid" type="date" required min={incomeMinDay} max={today} value={draft.paid_on}
                onChange={(event) => setDraft({ ...draft, paid_on: event.target.value })} />
            </Field>
            <Field label="Share acquisition date (Sydney)" htmlFor="drp-acquired">
              <Input id="drp-acquired" type="date" required min={incomeMinDay} max={today} value={draft.acquired_on}
                onChange={(event) => setDraft({ ...draft, acquired_on: event.target.value })} />
            </Field>
            <Field label="New shares acquired" htmlFor="drp-shares">
              <Input id="drp-shares" required inputMode="decimal" maxLength={31} pattern={reinvestmentShares.source} value={draft.shares}
                onChange={(event) => setDraft({ ...draft, shares: event.target.value })} />
            </Field>
            <Field label="Statement currency" htmlFor="drp-currency">
              <Input id="drp-currency" required pattern="[A-Z]{3}" maxLength={3} value={draft.currency}
                onChange={(event) => setDraft({ ...draft, currency: event.target.value.toUpperCase(), basis_usd: "" })} />
            </Field>
            {moneyFields.filter(([key]) => key !== "basis_usd" || draft.currency !== "USD").map(([key, label]) =>
              <Field key={key} label={label} htmlFor={`drp-${key}`}>
                <Input id={`drp-${key}`} inputMode="decimal" pattern={cashAmount.source} maxLength={21}
                  required={key === "dividend_amount" || key === "reinvested_amount"} value={draft[key]}
                  onChange={(event) => setDraft({ ...draft, [key]: event.target.value })} />
              </Field>)}
            <Field label="Reinvestment statement reference (optional)" htmlFor="drp-reference">
              <Input id="drp-reference" maxLength={200} value={draft.statement_reference}
                onChange={(event) => setDraft({ ...draft, statement_reference: event.target.value })} />
            </Field>
          </div>
          <p className="text-xs text-text-2">Use the total amount applied to shares, including any balance carried forward. If you also received cash, record that cash separately and enter the statement’s gross dividend and credits here once.</p>
          <div className="flex flex-wrap gap-2">
            <Button size="sm" type="submit">{editing ? "Save changes" : "Add dividend reinvestment"}</Button>
            {editing && <Button size="sm" onClick={() => { setEditing(undefined); setDraft(blank); clearMessages(); }}>Cancel edit</Button>}
          </div>
        </fieldset>
      </form>}
      {error && <p role="alert" className="text-sm text-down">{error}</p>}
      {feedback && <p role="status" className="text-sm text-text-2">{feedback}</p>}
    </div>}
  </section>;
}
