"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Field";
import { getJSON } from "@/lib/api";
import { type CompanyAlert, type CompanyAlertEvent, type CompanyAlertKind } from "@/lib/research-alert-types";
import { useSession } from "@/lib/session";

const LABELS: Record<CompanyAlertKind, string> = {
  price_above: "Price at or above", price_below: "Price at or below", volume_above: "Session volume at or above",
  filing: "New SEC filing", insider: "New ownership filing", news: "New company news",
};
type Inbox = { alerts: CompanyAlert[]; events: CompanyAlertEvent[] };

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
    onSuccess: async () => client.invalidateQueries({ queryKey }),
  });
  if (!userId) return null;
  const needsThreshold = kind !== "filing" && kind !== "insider" && kind !== "news";
  const options = (Object.keys(LABELS) as CompanyAlertKind[]).filter((item) => id.startsWith("us:") || item !== "filing" && item !== "insider");
  return <details onToggle={(event) => setOpen(event.currentTarget.open)} className="rounded-xl border border-border bg-surface p-4 text-sm">
    <summary className="cursor-pointer font-medium">Company alerts</summary>
    <p className="mt-2 text-xs text-text-2">Triggers appear here after scheduled checks. Price rules use the listing currency.</p>
    <form className="my-3 flex flex-wrap items-end gap-2" onSubmit={(event) => {
      event.preventDefault();
      save.mutate({ method: "POST", body: { kind, threshold: needsThreshold ? Number(threshold) : undefined } });
    }}>
      <label className="grid gap-1 text-xs text-text-2">Trigger
        <select value={kind} onChange={(event) => setKind(event.target.value as CompanyAlertKind)} className="rounded-lg border border-border bg-surface-2 px-2 py-2 text-text">
          {options.map((item) => <option key={item} value={item}>{LABELS[item]}</option>)}
        </select>
      </label>
      {needsThreshold ? <label className="grid gap-1 text-xs text-text-2">Threshold
        <Input type="number" min="0" step="any" required value={threshold} onChange={(event) => setThreshold(event.target.value)} />
      </label> : null}
      <Button type="submit" size="sm" disabled={save.isPending}>Add alert</Button>
    </form>
    {save.error || inbox.error ? <p role="status" className="text-warn">{(save.error ?? inbox.error)?.message}</p> : null}
    {inbox.isFetching && !inbox.data ? <p role="status" className="text-text-2">Loading alerts…</p> : null}
    {inbox.data?.alerts.length ? <ul className="divide-y divide-border">
      {inbox.data.alerts.map((alert) => <li key={alert.id} className="flex items-center justify-between gap-3 py-2">
        <div><p>{LABELS[alert.kind]}{alert.threshold === null ? "" : ` ${alert.threshold} ${alert.currency ?? "shares"}`}</p>
          <p className="text-xs text-text-2">{alert.last_problem ?? (alert.last_checked_at ? `Checked ${new Date(alert.last_checked_at).toLocaleString("en-AU")}` : "Waiting for the first check")}</p></div>
        <Button size="sm" variant="ghost" disabled={save.isPending} onClick={() => save.mutate({ method: "DELETE", body: { id: alert.id } })}>Remove</Button>
      </li>)}
    </ul> : null}
    {inbox.data?.events.length ? <div className="mt-4">
      <h4 className="font-medium">Recent triggers</h4>
      <ul className="mt-1 space-y-2">{inbox.data.events.map((event) => <li key={event.id} className="text-xs">
        <p className="text-text-2">{new Date(event.occurred_at).toLocaleString("en-AU")}</p>
        {event.url ? <a href={event.url} target="_blank" rel="noreferrer" className="text-primary-fg hover:underline">{event.title}</a> : event.title}
      </li>)}</ul>
    </div> : null}
  </details>;
}
