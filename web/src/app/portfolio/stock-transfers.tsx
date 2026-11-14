"use client";

import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Field, Input, Select } from "@/components/ui/Field";
import type { BrokerStockMatch } from "@/lib/broker-stock-transfers";
import { incomeDay, incomeMinDay } from "@/lib/portfolio-income";
import { reinvestmentShares } from "@/lib/portfolio-reinvestments";
import {
  receivingSnapshotFields, sameListedStock, stockTransferFields, sydneyDate, transferHoldingFields,
  type BrokerStockTransferReference, type ReceivingSnapshot, type StockTransfer, type TransferHolding,
} from "@/lib/portfolio-transfers";
import { browserSupabase } from "@/lib/supabase/client";
import { BrokerStockTransferReview } from "./broker-stock-transfer-review";

type Draft = {
  from_holding_id: string; to_holding_id: string; sent_on: string; received_on: string; shares: string;
  same_day_order: string; from_account: string; to_account: string; statement_reference: string; receiving_snapshot_id: string;
};
const blank: Draft = {
  from_holding_id: "", to_holding_id: "", sent_on: "", received_on: "", shares: "", same_day_order: "1",
  from_account: "", to_account: "", statement_reference: "", receiving_snapshot_id: "",
};

function db() {
  const client = browserSupabase();
  if (!client) throw new Error("Accounts are unavailable.");
  return client;
}

function holdingLabel(holding: TransferHolding) {
  return [holding.asset_symbol, holding.asset_exchange, holding.broker_account?.label, holding.date_added.slice(0, 10),
    holding.deleted_at ? "Archived" : null, holding.id.slice(0, 8)].filter(Boolean).join(" · ");
}

async function loadHoldings(userId: string, signal: AbortSignal) {
  const all: TransferHolding[] = [];
  while (true) {
    const query = db().from("portfolio_holdings").select(transferHoldingFields).eq("user_id", userId)
      .eq("asset_kind", "Stock").order("id").limit(500).abortSignal(signal);
    if (all.length) query.gt("id", all[all.length - 1].id);
    const { data, error } = await query.overrideTypes<TransferHolding[], { merge: false }>();
    if (error) throw error;
    all.push(...data);
    if (data.length < 500) return all.sort((a, b) => holdingLabel(a).localeCompare(holdingLabel(b)));
  }
}

async function loadTransfers(userId: string, signal: AbortSignal) {
  const all: StockTransfer[] = [];
  while (true) {
    const query = db().from("portfolio_stock_transfers").select(stockTransferFields).eq("user_id", userId)
      .order("id").limit(500).abortSignal(signal);
    if (all.length) query.gt("id", all[all.length - 1].id);
    const { data, error } = await query.overrideTypes<StockTransfer[], { merge: false }>();
    if (error) throw error;
    all.push(...data);
    if (data.length < 500) return all.sort((a, b) => b.sent_on.localeCompare(a.sent_on) || a.same_day_order - b.same_day_order);
  }
}

async function loadSnapshots(userId: string, holdingId: string, signal: AbortSignal) {
  const all: ReceivingSnapshot[] = [];
  while (true) {
    const query = db().from("transactions").select(receivingSnapshotFields).eq("user_id", userId).eq("holding_id", holdingId)
      .eq("type", "Buy").in("trade_provenance->>source", ["csv_position", "broker_position"])
      .is("deleted_at", null).order("id").limit(500).abortSignal(signal);
    if (all.length) query.gt("id", all[all.length - 1].id);
    const { data, error } = await query.overrideTypes<ReceivingSnapshot[], { merge: false }>();
    if (error) throw error;
    all.push(...data);
    if (data.length < 500) return all.sort((a, b) => b.transaction_date.localeCompare(a.transaction_date));
  }
}

function decimalKey(value: string) {
  const [significand, exponent] = value.split("e-");
  if (exponent) {
    const [whole, fraction = ""] = significand.split(".");
    return "0." + "0".repeat(Number(exponent) - whole.length) + whole + fraction;
  }
  return value.includes(".") ? value.replace(/0+$/, "").replace(/\.$/, "") : value;
}

export function StockTransfers({ userId }: { userId: string }) {
  const [expanded, setExpanded] = useState(false);
  const [draft, setDraft] = useState(blank);
  const [editing, setEditing] = useState<StockTransfer>();
  const [reference, setReference] = useState<BrokerStockTransferReference>();
  const [confirmed, setConfirmed] = useState(false);
  const [removing, setRemoving] = useState<StockTransfer>();
  const [message, setMessage] = useState("");
  const [problem, setProblem] = useState("");
  const [limit, setLimit] = useState(10);
  const cache = useQueryClient();
  const holdings = useQuery({ queryKey: ["transfer-holdings", userId], enabled: expanded,
    queryFn: ({ signal }) => loadHoldings(userId, signal) });
  const key = ["stock-transfers", userId];
  const transfers = useQuery({ queryKey: key, enabled: expanded, queryFn: ({ signal }) => loadTransfers(userId, signal) });
  const snapshots = useQuery({ queryKey: ["receiving-snapshots", userId, draft.to_holding_id], enabled: expanded && Boolean(draft.to_holding_id),
    queryFn: ({ signal }) => loadSnapshots(userId, draft.to_holding_id, signal) });
  const today = sydneyDate(new Date().toISOString())!;
  const source = holdings.data?.find((holding) => holding.id === draft.from_holding_id) ?? null;
  const candidates = holdings.data?.filter((holding) => sameListedStock(source, holding)) ?? [];
  const usedSnapshots = new Set(transfers.data?.filter((row) => row.id !== editing?.id).map((row) => row.receiving_snapshot_id));
  const matchingSnapshots = snapshots.data?.filter((snapshot) => !usedSnapshots.has(snapshot.id) &&
    (sydneyDate(snapshot.transaction_date) ?? "") >= draft.received_on &&
    decimalKey(String(snapshot.shares)) === decimalKey(draft.shares)) ?? [];

  function update(field: keyof Draft, value: string) {
    const accountLabel = holdings.data?.find((holding) => holding.id === value)?.broker_account?.label ?? "";
    setDraft((current) => ({ ...current, [field]: value,
      ...(field === "from_holding_id" ? { to_holding_id: "", from_account: accountLabel, to_account: "" } : {}),
      ...(field === "to_holding_id" ? { to_account: accountLabel } : {}),
      ...(["from_holding_id", "to_holding_id", "received_on", "shares"].includes(field) ? { receiving_snapshot_id: "" } : {}),
    }));
    if (reference && ["sent_on", "received_on", "shares"].includes(field)) setConfirmed(false);
  }

  function clear() {
    setDraft(blank);
    setEditing(undefined);
    setReference(undefined);
    setConfirmed(false);
    setRemoving(undefined);
    setProblem("");
    setMessage("");
  }

  const save = useMutation({
    mutationFn: async () => {
      const from = draft.from_account.trim();
      const to = draft.to_account.trim();
      const order = Number(draft.same_day_order);
      if (!candidates.some((holding) => holding.id === draft.to_holding_id) || !from || !to || from.toLowerCase() === to.toLowerCase() ||
          !incomeDay(draft.sent_on) || !incomeDay(draft.received_on) || draft.sent_on > draft.received_on || draft.received_on > today ||
          !reinvestmentShares.test(draft.shares) || !/[1-9]/.test(draft.shares) || !Number.isInteger(order) || order < 1 || order > 999) {
        throw new Error("Check the two holdings, account labels, statement dates, shares and transfer order.");
      }
      if (draft.receiving_snapshot_id && !matchingSnapshots.some((snapshot) => snapshot.id === draft.receiving_snapshot_id)) {
        throw new Error("Choose a matching receiving snapshot or clear the existing selection.");
      }
      if (reference && !confirmed) throw new Error("Confirm the transfer details against both statements.");
      const values = { ...draft, from_account: from, to_account: to, same_day_order: order,
        statement_reference: draft.statement_reference.trim(), receiving_snapshot_id: draft.receiving_snapshot_id || null,
        ...(reference ? { snaptrade_reference: reference } : {}) };
      const table = db().from("portfolio_stock_transfers");
      const write = editing ? table.update(values).eq("id", editing.id).eq("user_id", userId).eq("updated_at", editing.updated_at)
        : table.insert({ ...values, user_id: userId });
      const { data, error } = await write.select("id").maybeSingle();
      if (error?.code === "23505") throw new Error("This transfer, daily order number or receiving snapshot is already recorded.");
      if (error) throw new Error("Couldn’t save the transfer. Check the holdings and snapshot, then try again.");
      if (!data) throw new Error("This transfer changed elsewhere. Refresh and try again.");
    },
    onSuccess: async () => { clear(); setMessage("Transfer saved."); await cache.invalidateQueries({ queryKey: key }); },
    onError: (error) => setProblem(error.message),
  });

  const remove = useMutation({
    mutationFn: async (transfer: StockTransfer) => {
      const { data, error } = await db().from("portfolio_stock_transfers").delete()
        .eq("id", transfer.id).eq("user_id", userId).eq("updated_at", transfer.updated_at).select("id").maybeSingle();
      if (error) throw new Error("Couldn’t remove the transfer. Try again.");
      if (!data) throw new Error("This transfer changed elsewhere. Refresh and try again.");
    },
    onSuccess: async () => { clear(); setMessage("Transfer removed."); await cache.invalidateQueries({ queryKey: key }); },
    onError: (error) => setProblem(error.message),
  });
  const busy = save.isPending || remove.isPending;

  function edit(transfer: StockTransfer) {
    clear();
    setEditing(transfer);
    setReference(transfer.snaptrade_reference ?? undefined);
    setConfirmed(Boolean(transfer.snaptrade_reference));
    setDraft({
      from_holding_id: transfer.from_holding_id, to_holding_id: transfer.to_holding_id,
      sent_on: transfer.sent_on, received_on: transfer.received_on, shares: transfer.shares,
      same_day_order: String(transfer.same_day_order), from_account: transfer.from_account, to_account: transfer.to_account,
      statement_reference: transfer.statement_reference, receiving_snapshot_id: transfer.receiving_snapshot_id ?? "",
    });
    document.getElementById("transfer-source")?.focus();
  }

  function reviewMatch(match: BrokerStockMatch) {
    const { reference, source, destination } = match;
    const prior = transfers.data?.find((row) => !row.snaptrade_reference && row.from_holding_id === source.id &&
      row.to_holding_id === destination.id && row.sent_on === reference.sentOn && row.received_on === reference.receivedOn &&
      decimalKey(row.shares) === decimalKey(reference.shares));
    if (prior) {
      edit(prior);
    } else {
      clear();
      const usedOrders = new Set(transfers.data?.filter((row) => row.sent_on === reference.sentOn).map((row) => row.same_day_order));
      let order = 1;
      while (order <= 999 && usedOrders.has(order)) order++;
      setDraft({ ...blank, from_holding_id: source.id, to_holding_id: destination.id,
        sent_on: reference.sentOn, received_on: reference.receivedOn, shares: reference.shares, same_day_order: String(order),
        from_account: source.broker_account?.label ?? "", to_account: destination.broker_account?.label ?? "" });
    }
    setReference(reference);
    setConfirmed(false);
    document.getElementById("transfer-sent")?.focus();
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    setProblem("");
    save.mutate();
  }

  return <section className="space-y-3 border-t border-border p-4" aria-label="Stock transfers">
    <Button size="sm" aria-expanded={expanded} aria-controls="stock-transfer-controls" onClick={() => setExpanded(!expanded)}>
      {expanded ? "Hide stock transfers" : "Manage stock transfers"}
    </Button>
    {expanded && <div id="stock-transfer-controls" className="space-y-4">
      <p className="text-sm text-text-2">Use both brokerage statements to record shares moved between your own accounts. The lot report carries earlier acquisition dates and costs across the transfer. Confirm that the two synced holdings represent separate accounts for the same listed stock.</p>
      {(holdings.isError || transfers.isError) && <div className="flex items-center gap-2">
        <p role="alert" className="text-sm text-down">Couldn’t load stock transfers.</p>
        <Button size="sm" onClick={() => { void holdings.refetch(); void transfers.refetch(); }}>Retry</Button>
      </div>}
      {(holdings.isPending || transfers.isPending) && <p role="status" className="text-sm text-text-2">Loading stock transfers…</p>}
      {holdings.data && transfers.data && <BrokerStockTransferReview holdings={holdings.data} transfers={transfers.data}
        busy={busy} onReview={reviewMatch} />}
      {transfers.data?.length ? <ul className="divide-y divide-border rounded-md border border-border">
        {transfers.data.slice(0, limit).map((entry) => <li key={entry.id} className="flex flex-wrap justify-between gap-2 p-3">
          <div className="min-w-0 [overflow-wrap:anywhere]">
            <p className="text-sm font-medium">{entry.source?.asset_symbol ?? "Stock"} · {entry.shares} shares</p>
            <p className="text-xs text-text-2">{entry.from_account} → {entry.to_account} · {entry.sent_on} → {entry.received_on}</p>
            {entry.snaptrade_reference && <p className="text-xs text-text-2">SnapTrade reference attached</p>}
          </div>
          <div className="flex flex-wrap gap-2">{removing?.id === entry.id ? <>
            <Button size="sm" disabled={busy} onClick={() => setRemoving(undefined)}>Cancel</Button>
            <Button size="sm" variant="danger" disabled={busy} onClick={() => remove.mutate(entry)}>Remove transfer</Button>
          </> : <>
            <Button size="sm" disabled={busy} onClick={() => edit(entry)}>Edit transfer</Button>
            <Button size="sm" disabled={busy} onClick={() => setRemoving(entry)}>Remove</Button>
          </>}</div>
        </li>)}
      </ul> : null}
      {(transfers.data?.length ?? 0) > limit && <Button size="sm" onClick={() => setLimit(limit + 10)}>Show more transfers</Button>}
      {holdings.data && transfers.data && (holdings.data.length < 2
        ? <p className="text-sm text-text-2">Sync the sending and receiving stock holdings before recording a transfer.</p>
        : <form aria-label="Record stock transfer" onSubmit={submit}>
          <fieldset disabled={busy} className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Sending holding" htmlFor="transfer-source">
                <Select id="transfer-source" required disabled={Boolean(reference)} value={draft.from_holding_id} onChange={(e) => update("from_holding_id", e.target.value)}>
                  <option value="">Choose sending holding</option>
                  {holdings.data.map((holding) => <option key={holding.id} value={holding.id}>{holdingLabel(holding)}</option>)}
                </Select>
              </Field>
              <Field label="Receiving holding" htmlFor="transfer-destination">
                <Select id="transfer-destination" required disabled={!source || Boolean(reference)} value={draft.to_holding_id}
                  onChange={(e) => update("to_holding_id", e.target.value)}>
                  <option value="">Choose receiving holding</option>
                  {candidates.map((holding) => <option key={holding.id} value={holding.id}>{holdingLabel(holding)}</option>)}
                </Select>
              </Field>
              <Field label="Sending account label" htmlFor="transfer-from-account">
                <Input id="transfer-from-account" required maxLength={100} value={draft.from_account} onChange={(e) => update("from_account", e.target.value)} />
              </Field>
              <Field label="Receiving account label" htmlFor="transfer-to-account">
                <Input id="transfer-to-account" required maxLength={100} value={draft.to_account} onChange={(e) => update("to_account", e.target.value)} />
              </Field>
              <Field label="Shares sent (Sydney date)" htmlFor="transfer-sent">
                <Input id="transfer-sent" type="date" required min={incomeMinDay} max={draft.received_on || today}
                  value={draft.sent_on} onChange={(e) => update("sent_on", e.target.value)} />
              </Field>
              <Field label="Shares received (Sydney date)" htmlFor="transfer-received">
                <Input id="transfer-received" type="date" required min={draft.sent_on || incomeMinDay} max={today}
                  value={draft.received_on} onChange={(e) => update("received_on", e.target.value)} />
              </Field>
              <Field label="Shares transferred" htmlFor="transfer-shares">
                <Input id="transfer-shares" required inputMode="decimal" maxLength={31} pattern={reinvestmentShares.source}
                  value={draft.shares} onChange={(e) => update("shares", e.target.value)} />
              </Field>
              <Field label="Order among transfers sent that day" htmlFor="transfer-order">
                <Input id="transfer-order" type="number" required min={1} max={999} step={1} value={draft.same_day_order}
                  onChange={(e) => update("same_day_order", e.target.value)} />
              </Field>
              <Field label="Transfer statement reference (optional)" htmlFor="transfer-reference">
                <Input id="transfer-reference" maxLength={200} value={draft.statement_reference}
                  onChange={(e) => update("statement_reference", e.target.value)} />
              </Field>
            </div>
            {source && candidates.length === 0 && <p className="text-xs text-text-2">This stock needs a separate synced receiving holding on the same exchange.</p>}
            {draft.to_holding_id && <Field label="Receiving position snapshot (optional)" htmlFor="transfer-snapshot">
              <Select id="transfer-snapshot" value={draft.receiving_snapshot_id} onChange={(e) => update("receiving_snapshot_id", e.target.value)}>
                <option value="">No matching snapshot to replace</option>
                {draft.receiving_snapshot_id && !matchingSnapshots.some((item) => item.id === draft.receiving_snapshot_id) &&
                  <option value={draft.receiving_snapshot_id}>Saved snapshot needs review</option>}
                {matchingSnapshots.map((item) => <option key={item.id} value={item.id}>
                  {sydneyDate(item.transaction_date)} · {item.shares} shares · {item.id.slice(0, 8)}
                </option>)}
              </Select>
            </Field>}
            {draft.to_holding_id && snapshots.isError && <Button size="sm" onClick={() => void snapshots.refetch()}>Retry receiving snapshots</Button>}
            <p className="text-xs text-text-2">Select a receiving snapshot only when it represents exactly these shares. The lot report will use the transferred lots in its place. Date-only transfers post after the day’s trades.</p>
            {reference && <div className="space-y-2 rounded-md border border-border p-2">
              <p className="text-xs text-text-2">SnapTrade reported {reference.shares} shares of {reference.symbol}, sent {reference.sentOn} and received {reference.receivedOn}.</p>
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" required checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} />
                I checked the two holdings, dates and quantity against my statements
              </label>
            </div>}
            <div className="flex gap-2">
              <Button type="submit" size="sm">{editing ? "Save transfer changes" : "Record transfer"}</Button>
              {(editing || reference) && <Button size="sm" onClick={clear}>{editing ? "Cancel edit" : "Cancel review"}</Button>}
            </div>
          </fieldset>
        </form>)}
      {problem && <p role="alert" className="text-sm text-down">{problem}</p>}
      {message && <p role="status" className="text-sm text-text-2">{message}</p>}
    </div>}
  </section>;
}
