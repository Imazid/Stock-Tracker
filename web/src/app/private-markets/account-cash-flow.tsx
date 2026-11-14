"use client";

import { useId, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { dateLabel, dayInSydney, groupedDecimal } from "./private-data";

export type AccountCashFlow = {
  id: string;
  status: "contribution" | "pending" | "paid" | "cancelled" | "distribution";
  amount: string; date: string; source: string; dueOn?: string; resolutionSource?: string;
};

export type CashFlowChange = { id: string; cash_flow: AccountCashFlow } | { id: string; flow_id: string };
const labels = {
  contribution: "Contribution", pending: "Capital call due", paid: "Capital call paid",
  cancelled: "Capital call cancelled", distribution: "Distribution",
};

export function AccountCashFlows({ holding, revision, now, busy, save }: {
  holding: { id: string; currency: string; cashFlows?: AccountCashFlow[] };
  revision: string | null; now: number; busy: boolean; save: (change: CashFlowChange, revision: string | null) => void;
}) {
  const inputID = useId();
  const [draft, setDraft] = useState<{
    id: string; revision: string | null; record?: AccountCashFlow; resolution?: "paid" | "cancelled";
  }>();
  const [deleting, setDeleting] = useState<{ id: string; revision: string | null }>();
  const [error, setError] = useState("");
  const records = [...(holding.cashFlows ?? [])].sort((a, b) => b.date.localeCompare(a.date));
  const current = draft?.record;
  const resolving = draft?.resolution ?? (current?.status === "paid" || current?.status === "cancelled" ? current.status : undefined);
  function open(record?: AccountCashFlow, resolution?: "paid" | "cancelled") {
    setError("");
    setDeleting(undefined);
    setDraft({ id: record?.id ?? crypto.randomUUID(), record, resolution, revision });
  }

  return <details className="border-t border-border p-4 text-sm">
    <summary className="cursor-pointer font-medium">Cash flows</summary>
    <div className="mt-3 space-y-3">
      <Button size="sm" disabled={busy || !!draft} onClick={() => open()}>Add cash flow</Button>
      {draft && <form className="space-y-3" onSubmit={(event) => {
        event.preventDefault();
        const data = new FormData(event.currentTarget);
        const field = (key: string) => String(data.get(key) ?? "").trim();
        const status = resolving ?? current?.status ?? field("status") as AccountCashFlow["status"];
        const date = field("date");
        const amount = resolving ? current!.amount : field("amount");
        const source = resolving ? current!.source : field("source");
        if (!/^\d{1,22}(?:\.\d{1,16})?$/.test(amount) || !/[1-9]/.test(amount) || !source || !date ||
          (status !== "pending" && date > dayInSydney(now)) || (resolving && !field("resolution"))) {
          setError("Enter a positive amount, a valid date and a source.");
          return;
        }
        save({ id: holding.id, cash_flow: { id: draft.id, status, amount, date, source,
          ...(resolving ? { dueOn: current!.dueOn ?? current!.date, resolutionSource: field("resolution") } : {}) } }, draft.revision);
        setDraft(undefined);
        setError("");
      }}>
        <fieldset disabled={busy} className="grid gap-3 sm:grid-cols-2">
          {resolving ? <p className="sm:col-span-2">Original call due {dateLabel(current?.dueOn ?? current?.date)} · {current?.source}</p>
            : <>
              <Field label="Cash flow type" htmlFor={inputID + "-type"}>
                <Select id={inputID + "-type"} name="status" defaultValue={current?.status} disabled={!!current}>
                  <option value="contribution">Contribution</option><option value="pending">Capital call due</option>
                  <option value="distribution">Distribution</option>
                </Select>
              </Field>
              <Field label="Cash flow amount" htmlFor={inputID + "-amount"}><Input id={inputID + "-amount"} name="amount"
                inputMode="decimal" maxLength={39} required defaultValue={current?.amount} /></Field>
            </>}
          <Field label={resolving === "paid" ? "Payment date" : resolving === "cancelled" ? "Cancellation date" : "Cash flow date"}
            htmlFor={inputID + "-date"}>
            <Input id={inputID + "-date"} type="date" name="date" required
              defaultValue={draft.resolution ? dayInSydney(now) : current?.date} />
          </Field>
          <Field label={resolving ? "Resolution source" : "Cash flow source"} htmlFor={inputID + "-source"}>
            <Input id={inputID + "-source"} name={resolving ? "resolution" : "source"} maxLength={400}
              required defaultValue={resolving ? current?.resolutionSource : current?.source} />
          </Field>
        </fieldset>
        {error && <Notice tone="down">{error}</Notice>}
        <div className="flex gap-2"><Button size="sm" type="submit" disabled={busy}>Save cash flow</Button>
          <Button size="sm" type="button" onClick={() => setDraft(undefined)}>Cancel</Button></div>
      </form>}
      {!records.length && <p>No cash flows recorded.</p>}
      <ul className="divide-y divide-border">
        {records.map((flow) => <li key={flow.id} className="space-y-2 py-2.5">
          <p className="font-medium">{labels[flow.status]} · {holding.currency} {groupedDecimal(flow.amount)}</p>
          <p>{dateLabel(flow.date)} · {flow.resolutionSource ?? flow.source}</p>
          {flow.dueOn && <p>Originally due {dateLabel(flow.dueOn)} · {flow.source}</p>}
          {deleting?.id === flow.id ? <div className="flex flex-wrap gap-2">
            <span>Remove this cash flow?</span>
            <Button size="sm" variant="danger" disabled={busy} onClick={() => {
              save({ id: holding.id, flow_id: flow.id }, deleting.revision);
              setDeleting(undefined);
            }}>Confirm cash flow removal</Button>
            <Button size="sm" onClick={() => setDeleting(undefined)}>Cancel</Button>
          </div> : <div className="flex flex-wrap gap-2">
            <Button size="sm" disabled={busy || !!draft} onClick={() => open(flow)}>Edit cash flow</Button>
            {flow.status === "pending" && <>
              <Button size="sm" disabled={busy || !!draft} onClick={() => open(flow, "paid")}>Record payment</Button>
              <Button size="sm" disabled={busy || !!draft} onClick={() => open(flow, "cancelled")}>Record cancellation</Button>
            </>}
            <Button size="sm" disabled={busy || !!draft} onClick={() => setDeleting({ id: flow.id, revision })}>Remove cash flow</Button>
          </div>}
        </li>)}
      </ul>
    </div>
  </details>;
}
