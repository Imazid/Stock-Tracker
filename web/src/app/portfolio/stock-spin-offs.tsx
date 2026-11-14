"use client";

import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Field, Input, Select } from "@/components/ui/Field";
import { incomeDay, incomeMinDay } from "@/lib/portfolio-income";
import { reinvestmentShares } from "@/lib/portfolio-reinvestments";
import { distinctSpinOffHoldings, matchesSpinOffSnapshot, spinOffPercent, stockSpinOffFields, type StockSpinOff } from "@/lib/portfolio-spin-offs";
import { sydneyDate } from "@/lib/portfolio-transfers";
import { db, holdingLabel, loadHoldings, loadSnapshots } from "./lot-record-inputs";

const blank = {
  parent_holding_id: "", child_holding_id: "", effective_on: "", parent_shares: "", child_shares: "",
  child_basis_pct_usd: "", child_basis_pct_aud: "", average_aud_basis: false, statement_reference: "", child_snapshot_id: "",
};

async function loadSpinOffs(userId: string, signal: AbortSignal) {
  const rows: StockSpinOff[] = [];
  while (true) {
    const query = db().from("portfolio_stock_spin_offs").select(stockSpinOffFields).eq("user_id", userId)
      .order("id").limit(500).abortSignal(signal);
    if (rows.length) query.gt("id", rows[rows.length - 1].id);
    const { data, error } = await query.overrideTypes<StockSpinOff[], { merge: false }>();
    if (error) throw error;
    rows.push(...data);
    if (data.length < 500) return rows.sort((a, b) => b.effective_on.localeCompare(a.effective_on));
  }
}

export function StockSpinOffs({ userId }: { userId: string }) {
  const [expanded, setExpanded] = useState(false);
  const [draft, setDraft] = useState(blank);
  const [editing, setEditing] = useState<StockSpinOff>();
  const [removing, setRemoving] = useState<StockSpinOff>();
  const [message, setMessage] = useState("");
  const [problem, setProblem] = useState("");
  const [limit, setLimit] = useState(10);
  const cache = useQueryClient();
  const key = ["stock-spin-offs", userId];
  const holdings = useQuery({ queryKey: ["transfer-holdings", userId], enabled: expanded,
    queryFn: ({ signal }) => loadHoldings(userId, signal) });
  const records = useQuery({ queryKey: key, enabled: expanded, queryFn: ({ signal }) => loadSpinOffs(userId, signal) });
  const snapshots = useQuery({ queryKey: ["receiving-snapshots", userId, draft.child_holding_id], enabled: expanded && Boolean(draft.child_holding_id),
    queryFn: ({ signal }) => loadSnapshots(userId, draft.child_holding_id, signal) });
  const today = sydneyDate(new Date().toISOString())!;
  const parent = holdings.data?.find((holding) => holding.id === draft.parent_holding_id) ?? null;
  const children = holdings.data?.filter((holding) => distinctSpinOffHoldings(parent, holding)) ?? [];
  const usedSnapshots = new Set(records.data?.filter((entry) => entry.id !== editing?.id).map((entry) => entry.child_snapshot_id));
  const candidates = snapshots.data?.filter((snapshot) => draft.effective_on && !usedSnapshots.has(snapshot.id) &&
    matchesSpinOffSnapshot(snapshot, draft.child_holding_id, draft.effective_on, draft.child_shares)) ?? [];
  const availableSnapshot = candidates.some((snapshot) => snapshot.id === draft.child_snapshot_id);

  function update(field: keyof typeof blank, value: string | boolean) {
    setDraft((current) => ({
      ...current, [field]: value, ...(field === "parent_holding_id" ? { child_holding_id: "" } : {}),
      ...(["parent_holding_id", "child_holding_id", "effective_on", "child_shares"].includes(field) ? { child_snapshot_id: "" } : {}),
    }));
  }

  function reset() {
    setDraft(blank);
    setEditing(undefined);
    setRemoving(undefined);
    setMessage("");
    setProblem("");
  }

  async function saved(status: string) {
    reset();
    setMessage(status);
    await Promise.all([cache.invalidateQueries({ queryKey: key }),
      cache.invalidateQueries({ queryKey: ["portfolio-gains", userId] })]);
  }

  const save = useMutation({
    mutationFn: async () => {
      const { effective_on, parent_shares, child_shares, child_basis_pct_usd, child_basis_pct_aud, statement_reference } = draft;
      const validShares = (value: string) => reinvestmentShares.test(value) && /[1-9]/.test(value);
      const usd = spinOffPercent(child_basis_pct_usd);
      const aud = spinOffPercent(child_basis_pct_aud);
      if (!children.some((holding) => holding.id === draft.child_holding_id) || !incomeDay(effective_on) || effective_on > today ||
          !validShares(parent_shares) || !validShares(child_shares) || !statement_reference.trim()) {
        throw new Error("Check the holdings, spin-off date, share quantities and statement reference.");
      }
      if ((!usd && !aud) || (child_basis_pct_usd && !usd) || (child_basis_pct_aud && !aud)) {
        throw new Error("Enter at least one confirmed allocation as a percentage greater than 0 and below 100.");
      }
      if ((candidates.length || draft.child_snapshot_id) && !availableSnapshot) {
        throw new Error("Choose the matching child position snapshot before saving.");
      }
      const values = { ...draft, child_basis_pct_usd: child_basis_pct_usd || null,
        child_basis_pct_aud: child_basis_pct_aud || null, average_aud_basis: Boolean(aud && draft.average_aud_basis),
        statement_reference: statement_reference.trim(), child_snapshot_id: draft.child_snapshot_id || null };
      const table = db().from("portfolio_stock_spin_offs");
      const write = editing ? table.update(values).eq("id", editing.id).eq("user_id", userId).eq("updated_at", editing.updated_at)
        : table.insert({ ...values, user_id: userId });
      const { data, error } = await write.select("id").maybeSingle();
      if (error?.code === "23505") throw new Error("This spin-off or child position snapshot is already recorded.");
      if (error) throw new Error("Couldn’t save the spin-off. Check the entries against your records.");
      if (!data) throw new Error("This spin-off changed elsewhere. Reload the records and try again.");
    },
    onSuccess: () => saved("Spin-off saved."),
    onError: (error) => setProblem(error.message),
  });

  const remove = useMutation({
    mutationFn: async (entry: StockSpinOff) => {
      const { data, error } = await db().from("portfolio_stock_spin_offs").delete()
        .eq("user_id", userId).eq("id", entry.id).eq("updated_at", entry.updated_at).select("id").maybeSingle();
      if (error || !data) throw new Error("Couldn’t remove the spin-off. Reload the records and try again.");
    },
    onSuccess: () => saved("Spin-off removed."),
    onError: (error) => setProblem(error.message),
  });
  const busy = save.isPending || remove.isPending;

  function edit(entry: StockSpinOff) {
    reset();
    setEditing(entry);
    setDraft({
      parent_holding_id: entry.parent_holding_id, child_holding_id: entry.child_holding_id, effective_on: entry.effective_on,
      parent_shares: entry.parent_shares, child_shares: entry.child_shares, child_basis_pct_usd: entry.child_basis_pct_usd ?? "",
      child_basis_pct_aud: entry.child_basis_pct_aud ?? "", average_aud_basis: entry.average_aud_basis,
      statement_reference: entry.statement_reference, child_snapshot_id: entry.child_snapshot_id ?? "",
    });
    document.getElementById("spin-off-parent")?.focus();
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setProblem("");
    setMessage("");
    save.mutate();
  }

  return (
    <section className="space-y-3 border-t border-border p-4">
      <Button size="sm" variant="secondary" aria-expanded={expanded} aria-controls="stock-spin-off-editor"
        onClick={() => setExpanded(!expanded)}>Manage stock spin-offs</Button>
      <div id="stock-spin-off-editor" hidden={!expanded} className="space-y-3">
        <p className="text-sm text-text-2">
          Record a share-only allotment with an issuer or broker basis allocation. Use two holdings in the same brokerage account.
          Enter the parent shares eligible immediately before the allotment and the full quantity of child shares received.
        </p>
        {(holdings.isError || records.isError) && <div className="space-y-2">
          <p role="alert" className="text-sm text-down">Couldn’t load holdings or spin-offs.</p>
          <Button size="sm" onClick={() => { void holdings.refetch(); void records.refetch(); }}>Reload spin-off records</Button>
        </div>}
        {(holdings.isLoading || records.isLoading) && <p role="status" className="text-sm text-text-2">Loading spin-off records…</p>}
        {holdings.isSuccess && records.isSuccess && (holdings.data.length < 2
          ? <p className="text-sm text-text-2">Add or sync both stock holdings before recording a spin-off.</p>
          : <form className="space-y-3" onSubmit={submit}>
          <fieldset disabled={busy} className="grid min-w-0 gap-3 sm:grid-cols-2">
            <Field label="Parent holding" htmlFor="spin-off-parent">
              <Select id="spin-off-parent" value={draft.parent_holding_id} required onChange={(event) => update("parent_holding_id", event.target.value)}>
                <option value="">Select parent</option>
                {holdings.data.map((holding) => <option key={holding.id} value={holding.id}>{holdingLabel(holding)}</option>)}
              </Select>
            </Field>
            <Field label="Child holding" htmlFor="spin-off-child">
              <Select id="spin-off-child" value={draft.child_holding_id} required onChange={(event) => update("child_holding_id", event.target.value)}>
                <option value="">Select the newly allotted stock</option>
                {children.map((holding) => <option key={holding.id} value={holding.id}>{holdingLabel(holding)}</option>)}
              </Select>
            </Field>
            <Field label="Spin-off date (Sydney time)" htmlFor="spin-off-date">
              <Input id="spin-off-date" type="date" min={incomeMinDay} max={today} value={draft.effective_on} required
                onChange={(event) => update("effective_on", event.target.value)} />
            </Field>
            <Field label="Statement or issuer reference" htmlFor="spin-off-reference" hint="Use a reference without personal account numbers.">
              <Input id="spin-off-reference" maxLength={200} value={draft.statement_reference} required
                onChange={(event) => update("statement_reference", event.target.value)} />
            </Field>
            <Field label="Eligible parent shares" htmlFor="spin-off-parent-shares">
              <Input id="spin-off-parent-shares" inputMode="decimal" maxLength={31} value={draft.parent_shares} required
                onChange={(event) => update("parent_shares", event.target.value)} />
            </Field>
            <Field label="Child shares received" htmlFor="spin-off-child-shares">
              <Input id="spin-off-child-shares" inputMode="decimal" maxLength={31} value={draft.child_shares} required
                onChange={(event) => update("child_shares", event.target.value)} />
            </Field>
            <Field label="Basis allocated to child (USD %)" htmlFor="spin-off-usd">
              <Input id="spin-off-usd" inputMode="decimal" maxLength={15} value={draft.child_basis_pct_usd}
                onChange={(event) => update("child_basis_pct_usd", event.target.value)} />
            </Field>
            <Field label="Basis allocated to child (AUD %)" htmlFor="spin-off-aud">
              <Input id="spin-off-aud" inputMode="decimal" maxLength={15} value={draft.child_basis_pct_aud}
                onChange={(event) => update("child_basis_pct_aud", event.target.value)} />
            </Field>
            <p className="text-xs text-text-2 sm:col-span-2">Enter the confirmed percentage for at least one currency. The adjusted basis stays blank in a currency without a confirmed allocation.</p>
            {draft.child_basis_pct_aud && <label className="flex items-center gap-2 text-sm text-text sm:col-span-2">
              <input type="checkbox" checked={draft.average_aud_basis} onChange={(event) => update("average_aud_basis", event.target.checked)} />
              Average AUD basis across eligible shares as specified in the source
            </label>}
            {draft.child_holding_id && draft.effective_on && draft.child_shares && <Field label="Replace child position snapshot (optional)"
              htmlFor="spin-off-snapshot" className="sm:col-span-2" hint="Select the matching snapshot if the same shares were already imported as a position.">
              <Select id="spin-off-snapshot" value={draft.child_snapshot_id} onChange={(event) => update("child_snapshot_id", event.target.value)}>
                <option value="">{candidates.length ? "Select the matching position" : "Keep existing position records"}</option>
                {draft.child_snapshot_id && !availableSnapshot && <option value={draft.child_snapshot_id}>Selection needs review</option>}
                {candidates.map((snapshot) => <option key={snapshot.id} value={snapshot.id}>{sydneyDate(snapshot.transaction_date)} · {snapshot.shares} shares · {snapshot.id.slice(0, 8)}</option>)}
              </Select>
            </Field>}
          </fieldset>
          {snapshots.isError && <p role="alert" className="text-sm text-down">Couldn’t check imported child positions. <button type="button"
            className="underline" onClick={() => void snapshots.refetch()}>Retry snapshot lookup</button></p>}
          <div className="flex flex-wrap gap-2">
            <Button size="sm" type="submit" disabled={busy || snapshots.isFetching || snapshots.isError}>{editing ? "Save spin-off changes" : "Save spin-off"}</Button>
            {editing && <Button size="sm" variant="ghost" disabled={busy} onClick={reset}>Cancel edit</Button>}
          </div>
        </form>)}
        {problem && <p role="alert" className="text-sm text-down">{problem}</p>}
        {message && <p role="status" className="text-sm text-text-2">{message}</p>}
        {!!records.data?.length && <ul className="divide-y divide-border rounded border border-border">
          {records.data.slice(0, limit).map((entry) => (
            <li key={entry.id} className="space-y-1.5 p-3">
              <p className="text-sm font-medium">{entry.parent?.asset_symbol} → {entry.child?.asset_symbol} · {entry.effective_on}</p>
              <p className="break-words text-xs text-text-2">{entry.parent_shares} parent / {entry.child_shares} child shares · {entry.statement_reference}</p>
              {removing?.id === entry.id ? <div className="flex flex-wrap items-center gap-2">
                <p className="text-xs text-text-2">Remove this adjustment from the reports?</p>
                <Button size="sm" variant="danger" disabled={busy} onClick={() => remove.mutate(entry)}>Confirm removal</Button>
                <Button size="sm" variant="ghost" disabled={busy} onClick={() => setRemoving(undefined)}>Cancel removal</Button>
              </div> : <div className="flex gap-2">
                <Button size="sm" variant="ghost" disabled={busy} onClick={() => edit(entry)}>Edit spin-off</Button>
                <Button size="sm" variant="ghost" disabled={busy} onClick={() => setRemoving(entry)}>Remove spin-off</Button>
              </div>}
            </li>
          ))}
        </ul>}
        {(records.data?.length ?? 0) > limit && <Button size="sm" onClick={() => setLimit(limit + 10)}>Show more spin-offs</Button>}
      </div>
    </section>
  );
}
