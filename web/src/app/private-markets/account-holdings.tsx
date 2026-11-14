"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useId, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { ManualHoldingCard, type ManualHolding } from "./manual-portfolio";
import { dayInSydney, privateMarkets } from "./private-data";

type AccountHoldings = { revision: string | null; updated_at: string | null; holdings: ManualHolding[] };
type EditableHolding = Pick<ManualHolding, "id" | "name" | "assetClass" | "currency" |
  "units" | "ownership" | "commitment" | "shareClass" | "lockupUntil" | "valuation"> & { excerptID?: string };

export function accountHoldingsQuery(owner: string) {
  return {
    queryKey: ["private-markets", owner, "account-holdings"], gcTime: 0, retry: false as const,
    queryFn: ({ signal }: { signal: AbortSignal }) => privateMarkets<AccountHoldings>("account_holdings", { owner, signal }),
  };
}

const classes = ["Startup equity", "Venture fund", "Private equity", "Syndicate or SPV", "Private secondary", "Other alternative"];

function HoldingForm({ owner, holding, now, busy, save, cancel }: {
  owner: string; holding: ManualHolding | null; now: number; busy: boolean;
  save: (holding: EditableHolding) => void; cancel: () => void;
}) {
  const formID = useId();
  const [draftID] = useState(() => holding?.id ?? crypto.randomUUID());
  const [error, setError] = useState("");
  const documents = useQuery({
    queryKey: ["private-markets", owner, "documents", "account-holding"], gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ items: { id: string; title: string }[] }>("documents", { owner, signal }),
  });
  const field = (name: string) => `${formID}-${name}`;
  const numeric = [
    ["units", "Shares or units", holding?.units], ["ownership", "Ownership percentage", holding?.ownership],
    ["commitment", "Committed capital", holding?.commitment],
  ] as const;

  return <Card as="div">
    <CardHeader title={holding ? "Edit private holding" : "Add private holding"} />
    <form className="space-y-3 border-t border-border p-4" onSubmit={(event) => {
      event.preventDefault();
      const form = new FormData(event.currentTarget);
      const value = (key: string) => String(form.get(key) ?? "").trim();
      const name = value("name");
      const currency = value("currency").toUpperCase();
      const excerptID = value("excerpt");
      const valuation = value("valuation");
      const date = value("valuedOn");
      const source = value("source");
      const method = value("method");
      const decimals = /^\d{1,15}(?:\.\d{1,8})?$/;
      if (!name || !/^[A-Z]{3}$/.test(currency) ||
        [...numeric.map(([key]) => value(key)), valuation].some((entry) => entry && !decimals.test(entry)) ||
        Number(value("ownership")) > 100) {
        setError("Enter a name, a three-letter currency and valid amounts. Ownership must be between zero and 100 percent.");
        return;
      }
      if ((valuation || date || source || method) && (!valuation || !date || date > dayInSydney(now) || !source || !method)) {
        setError("A valuation needs an amount, a date through today, a source and a method.");
        return;
      }
      if (excerptID && !form.has("reviewed")) {
        setError("Confirm you reviewed the selected ownership excerpt.");
        return;
      }
      setError("");
      save({ id: draftID, name, currency, assetClass: value("assetClass"),
        units: value("units") || undefined, ownership: value("ownership") || undefined, commitment: value("commitment") || undefined,
        shareClass: value("shareClass") || undefined, lockupUntil: value("lockup") ? `${value("lockup")}T00:00:00Z` : undefined,
        valuation: valuation ? { value: valuation, date: `${date}T00:00:00Z`, source, method } : undefined,
        excerptID: excerptID || undefined,
      });
    }}>
      <fieldset disabled={busy} className="grid gap-3 sm:grid-cols-2">
        <Field label="Company or fund name" htmlFor={field("name")}><Input id={field("name")} name="name" required maxLength={160} defaultValue={holding?.name} /></Field>
        <Field label="Asset class" htmlFor={field("assetClass")}><Select id={field("assetClass")} name="assetClass" defaultValue={holding?.assetClass}>{classes.map((name) => <option key={name}>{name}</option>)}</Select></Field>
        <Field label="Currency" htmlFor={field("currency")}><Input id={field("currency")} name="currency" required maxLength={3} defaultValue={holding?.currency ?? "AUD"} /></Field>
        {numeric.map(([key, label, value]) => <Field key={key} label={label} htmlFor={field(key)}><Input id={field(key)} name={key} inputMode="decimal" maxLength={24} defaultValue={value} /></Field>)}
        <Field label="Share class" htmlFor={field("shareClass")}><Input id={field("shareClass")} name="shareClass" maxLength={160} defaultValue={holding?.shareClass} /></Field>
        <Field label="Lock-up ends" htmlFor={field("lockup")}><Input id={field("lockup")} type="date" name="lockup" defaultValue={holding?.lockupUntil?.slice(0, 10)} /></Field>
        <Field label="Carrying value" htmlFor={field("valuation")}><Input id={field("valuation")} name="valuation" inputMode="decimal" maxLength={24} defaultValue={holding?.valuation?.value} /></Field>
        <Field label="Valuation date" htmlFor={field("valuedOn")}><Input id={field("valuedOn")} type="date" name="valuedOn" max={dayInSydney(now)} defaultValue={holding?.valuation?.date.slice(0, 10)} /></Field>
        <Field label="Valuation source" htmlFor={field("source")}><Input id={field("source")} name="source" maxLength={400} defaultValue={holding?.valuation?.source} /></Field>
        <Field label="Valuation method" htmlFor={field("method")}><Input id={field("method")} name="method" maxLength={400} defaultValue={holding?.valuation?.method} /></Field>
        <Field label="Deal Room ownership excerpt" htmlFor={field("excerpt")} hint={documents.error ? "The Deal Room could not be loaded." : undefined}>
          <Select id={field("excerpt")} name="excerpt" defaultValue={holding?.ownershipEvidence?.excerptID ?? ""}>
            <option value="">None</option>
            {holding?.ownershipEvidence && !documents.data?.items.some(({ id }) => id === holding.ownershipEvidence?.excerptID) &&
              <option value={holding.ownershipEvidence.excerptID}>Previously linked excerpt</option>}
            {documents.data?.items.map(({ id, title }) => <option key={id} value={id}>{title}</option>)}
          </Select>
        </Field>
        <label className="flex items-center gap-2 self-end py-2 text-sm"><input type="checkbox" name="reviewed" />I reviewed the selected excerpt.</label>
      </fieldset>
      {error && <Notice tone="down">{error}</Notice>}
      <div className="flex gap-2"><Button type="submit" variant="primary" disabled={busy}>Save holding</Button><Button type="button" disabled={busy} onClick={cancel}>Cancel</Button></div>
    </form>
  </Card>;
}

export function AccountHoldingsPanel({ owner }: { owner: string }) {
  const cache = useQueryClient();
  const options = accountHoldingsQuery(owner);
  const result = useQuery(options);
  const [editor, setEditor] = useState<{ holding: ManualHolding | null; revision: string | null }>();
  const [deleting, setDeleting] = useState<{ id: string; revision: string | null }>();
  const mutation = useMutation({
    mutationFn: (change: { holding: EditableHolding; revision: string | null } | { id: string; revision: string | null }) =>
      privateMarkets<AccountHoldings>("holding" in change ? "save_account_holding" : "remove_account_holding", {
        owner, expected_revision: change.revision, ...("holding" in change ? { holding: change.holding } : { id: change.id }),
      }),
    onMutate: () => cache.cancelQueries({ queryKey: options.queryKey }),
    onSuccess: (value) => {
      cache.setQueryData(options.queryKey, value);
      setEditor(undefined);
      setDeleting(undefined);
    },
  });
  const current = result.error ? undefined : result.data;
  async function refresh() {
    await result.refetch();
    mutation.reset();
    setEditor(undefined);
    setDeleting(undefined);
  }
  return <section className="min-w-0 space-y-3">
    <div className="flex flex-wrap items-center justify-between gap-2">
      <div><h2 className="font-semibold text-text">Holdings added on web</h2>
        <p className="text-sm text-text-2">Self-reported holdings saved to your account and visible on iPhone. Enter each position once so allocation counts it once.</p></div>
      {current && !editor && <Button size="sm" disabled={mutation.isPending} onClick={() => {
        mutation.reset(); setDeleting(undefined); setEditor({ holding: null, revision: current.revision });
      }}>Add private holding</Button>}
    </div>
    {result.isPending && <p role="status" className="text-sm text-text-2">Loading holdings added on web…</p>}
    {result.error && <Notice tone="down">{result.error.message} <Button size="sm" onClick={() => void refresh()}>Retry holdings</Button></Notice>}
    {mutation.error && <Notice tone="down">{mutation.error.message} <Button size="sm" onClick={() => void refresh()}>Refresh holdings</Button></Notice>}
    {editor && <HoldingForm key={editor.holding?.id ?? "new"} owner={owner} holding={editor.holding}
      now={result.dataUpdatedAt} busy={mutation.isPending} save={(holding) => mutation.mutate({ holding, revision: editor.revision })}
      cancel={() => { mutation.reset(); setEditor(undefined); }} />}
    {current?.holdings.map((holding) => <ManualHoldingCard key={holding.id} owner={owner} holding={holding} now={result.dataUpdatedAt} published={false}
      controls={<div className="flex flex-wrap items-center gap-2 border-t border-border p-4">
        {deleting?.id === holding.id ? <>
          <span className="text-sm">Remove this holding from your account?</span>
          <Button size="sm" variant="danger" disabled={mutation.isPending} onClick={() => mutation.mutate(deleting)}>Confirm removal</Button>
          <Button size="sm" disabled={mutation.isPending} onClick={() => { mutation.reset(); setDeleting(undefined); }}>Cancel</Button>
        </> : <>
          <Button size="sm" disabled={!!editor || mutation.isPending} onClick={() => {
            mutation.reset(); setDeleting(undefined); setEditor({ holding, revision: current.revision });
          }}>Edit holding</Button>
          <Button size="sm" disabled={!!editor || mutation.isPending} onClick={() => {
            mutation.reset(); setDeleting({ id: holding.id, revision: current.revision });
          }}>Remove holding</Button>
        </>}
      </div>} />)}
  </section>;
}
