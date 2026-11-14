"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Field";
import { dateTime } from "@/lib/format";
import { getJSON } from "@/lib/api";
import { type CompanyAlert, type CompanyAlertEvent, type CompanyAlertKind } from "@/lib/research-alert-types";
import { useSession } from "@/lib/session";

const LABELS: Record<CompanyAlertKind, string> = {
  price_above: "Price at or above", price_below: "Price at or below", volume_above: "Session volume at or above",
  filing: "New SEC filing", insider: "New ownership filing", news: "New company news",
};
type Inbox = { alerts: CompanyAlert[]; events: CompanyAlertEvent[]; monitoring: boolean; availableKinds: CompanyAlertKind[] };

export function CompanyAlerts({ id }: { id: string }) {
  const session = useSession();
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<CompanyAlertKind>("price_above");
  const [threshold, setThreshold] = useState("");
  const client = useQueryClient();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const queryKey = ["company-alerts", id, userId];
  const path = `/api/markets/instruments/${encodeURIComponent(id)}/research/alerts`;
  const inbox = useQuery({
    queryKey, queryFn: () => getJSON<Inbox>(path), enabled: Boolean(open && userId), retry: false, refetchInterval: open ? 60_000 : false,
  });
  const save = useMutation({
    mutationFn: async ({ method, body }: { method: "POST" | "DELETE"; body: object }) => {
      const response = await fetch(path, { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error?.message ?? "The alert could not be updated.");
    },
    onSuccess: async () => { await Promise.all([client.invalidateQueries({ queryKey }), client.invalidateQueries({ queryKey: ["activity", userId] })]); },
  });
  useEffect(() => {
    if (!userId) return;
    function openLinkedAlert() {
      if (window.location.hash === "#company-alerts") {
        const details = document.getElementById("company-alerts");
        if (details instanceof HTMLDetailsElement) {
          details.open = true;
          details.scrollIntoView({ block: "start" });
        }
      }
    }
    openLinkedAlert();
    window.addEventListener("hashchange", openLinkedAlert);
    return () => window.removeEventListener("hashchange", openLinkedAlert);
  }, [userId]);
  if (!userId) return null;
  const options = inbox.data?.availableKinds ?? [];
  const selectedKind = options.includes(kind) ? kind : options[0];
  const needsThreshold = selectedKind === "price_above" || selectedKind === "price_below" || selectedKind === "volume_above";
  return <details id="company-alerts" onToggle={(event) => setOpen(event.currentTarget.open)} className="scroll-mt-20 rounded-xl border border-border bg-surface p-4 text-sm">
    <summary className="cursor-pointer font-medium">Company alerts</summary>
    <p className="mt-2 text-xs text-text-2">Triggers appear here and in Activity. Price rules use the listing currency.</p>
    <Link href="/activity" className="mt-2 inline-block text-xs text-primary-fg hover:underline">Open Activity</Link>
    {inbox.data && !inbox.data.monitoring && <p role="status" className="mt-2 text-xs text-text-2">Scheduled checks are temporarily unavailable.</p>}
    {selectedKind && <form className="my-3 flex flex-wrap items-end gap-2" onSubmit={(event) => {
      event.preventDefault();
      save.mutate({ method: "POST", body: { kind: selectedKind, threshold: needsThreshold ? Number(threshold) : undefined } });
    }}>
      <label className="grid gap-1 text-xs text-text-2">Trigger
        <select value={selectedKind} onChange={(event) => setKind(event.target.value as CompanyAlertKind)} className="rounded-lg border border-border bg-surface-2 px-2 py-2 text-text">
          {options.map((item) => <option key={item} value={item}>{LABELS[item]}</option>)}
        </select>
      </label>
      {needsThreshold ? <label className="grid gap-1 text-xs text-text-2">Threshold
        <Input type="number" min="0" step="any" required value={threshold} onChange={(event) => setThreshold(event.target.value)} />
      </label> : null}
      <Button type="submit" size="sm" disabled={save.isPending}>Add alert</Button>
    </form>}
    {save.error || inbox.error ? <p role="status" className="text-warn">{(save.error ?? inbox.error)?.message}</p> : null}
    {inbox.data?.monitoring && !inbox.data.availableKinds.includes("volume_above") &&
      <p className="my-2 text-xs text-text-2">Volume alerts require a verified consolidated feed.</p>}
    {inbox.isFetching && !inbox.data ? <p role="status" className="text-text-2">Loading alerts…</p> : null}
    {inbox.data?.alerts.length ? <ul className="divide-y divide-border">
      {inbox.data.alerts.map((alert) => <li key={alert.id} className="flex items-center justify-between gap-3 py-2">
        <div><p>{LABELS[alert.kind]}{alert.threshold === null ? "" : ` ${alert.threshold} ${alert.currency ?? "shares"}`}</p>
          <p className="text-xs text-text-2">{alert.last_problem ?? (alert.last_checked_at ? `Checked ${dateTime(alert.last_checked_at)}` : "Waiting for the first check")}</p></div>
        <Button size="sm" variant="ghost" disabled={save.isPending} aria-label={`Remove ${LABELS[alert.kind].toLowerCase()} alert`} onClick={() => save.mutate({ method: "DELETE", body: { id: alert.id } })}>Remove</Button>
      </li>)}
    </ul> : null}
    {inbox.data?.events.length ? <div className="mt-4">
      <h4 className="font-medium">Recent triggers</h4>
      <ul className="mt-1 space-y-2">{inbox.data.events.map((event) => <li key={event.id} className="text-xs">
        <p className="text-text-2">{dateTime(event.occurred_at)}</p>
        {event.url ? <a href={event.url} target="_blank" rel="noreferrer" className="text-primary-fg hover:underline">{event.title}</a> : event.title}
      </li>)}</ul>
    </div> : null}
  </details>;
}
