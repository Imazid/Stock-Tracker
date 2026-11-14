"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { SourceLink } from "./catalog";
import {
  dateLabel, privateMarkets, type CompanyUpdate, type MonitorAlert, type MonitorPreferences, type PrivateDeal, type SavedReport,
} from "./private-data";

type SettingsResponse = { preferences: MonitorPreferences | null };
type Options = Pick<MonitorPreferences, "company_ids" | "eligible_opportunities" | "digest_enabled"> & { enabled: boolean };

const keyFor = (owner: string) => ["private-markets", owner, "monitor"];
const maxCompanies = 250;
const groupSize = 100;
const alertLabels: Record<string, string> = {
  announcement: "Company announcement",
  financial_disclosure: "Financial disclosure",
  closed_round: "Closed funding round",
  open_round: "Funding round",
  eligible_round: "Matches verified eligibility",
  interest: "Expression of interest",
  capital_call: "Capital call",
  distribution: "Distribution",
  holding_exit: "Confirmed exit",
};

function MonitoringForm({ preferences, saving, deals, onSave }: {
  preferences: MonitorPreferences | null;
  saving: boolean;
  deals: PrivateDeal[];
  onSave: (options: Options) => void;
}) {
  const [enabled, setEnabled] = useState(Boolean(preferences));
  const [followed, setFollowed] = useState(preferences?.company_ids ?? []);
  const [eligible, setEligible] = useState(preferences?.eligible_opportunities ?? false);
  const [digest, setDigest] = useState(preferences?.digest_enabled ?? false);
  const [query, setQuery] = useState("");
  const companies = new Map(deals.map(({ round }) => [round.company.id, round.company]));
  const visible = [...companies.values()].filter(({ name }) => name.toLowerCase().includes(query.trim().toLowerCase()))
    .sort((first, second) => Number(followed.includes(second.id)) - Number(followed.includes(first.id)) || first.name.localeCompare(second.name));
  const uncatalogued = followed.filter((id) => !companies.has(id));
  const activeUntil = preferences && new Date(Date.parse(preferences.refreshed_at) + 90 * 86_400_000).toISOString();

  function toggle(id: string, selected: boolean) {
    setFollowed((current) => selected ? [...current, id] : current.filter((item) => item !== id));
  }

  return <form className="space-y-4 border-t border-border p-4" onSubmit={(event) => {
    event.preventDefault();
    if (!saving) onSave({ enabled, company_ids: followed, eligible_opportunities: eligible, digest_enabled: digest });
  }}>
    <fieldset disabled={saving} className="min-w-0 space-y-4 disabled:opacity-60">
      <label className="flex items-start gap-2 text-sm font-medium text-text">
        <input className="mt-0.5" type="checkbox" checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />
        Collect alerts for this account from the web
      </label>
      <p className="text-[13px] text-text-2">
        The inbox is shared with iPhone. This subscription collects published updates for the companies you select and provider-confirmed activity.
      </p>
      {enabled && <>
        <div className="space-y-2 rounded-lg border border-border bg-surface-2 p-3">
          <Field label="Find a company to follow" htmlFor="private-monitor-company">
            <Input id="private-monitor-company" type="search" value={query} onChange={(event) => setQuery(event.target.value)} />
          </Field>
          <p className="text-xs text-text-2" role="status">{followed.length} of {maxCompanies} followed</p>
          <div className="max-h-56 space-y-1 overflow-y-auto">
            {visible.map(({ id, name, sector }) => <label key={id} className="flex items-start gap-2 rounded-md px-1 py-1.5 text-sm text-text hover:bg-surface-3">
              <input className="mt-0.5 shrink-0" type="checkbox" checked={followed.includes(id)}
                disabled={!followed.includes(id) && followed.length >= maxCompanies} onChange={(event) => toggle(id, event.target.checked)} />
              <span className="min-w-0 break-words">{name}<span className="block text-xs text-text-3">{sector}</span></span>
            </label>)}
            {visible.length === 0 && <p className="p-1 text-xs text-text-2">No matching companies in the catalogue.</p>}
          </div>
          {uncatalogued.length > 0 && <p className="text-xs text-text-2">
            {uncatalogued.length} followed {uncatalogued.length === 1 ? "company is" : "companies are"} outside the current catalogue.
            <Button size="sm" variant="ghost" onClick={() => setFollowed((current) => current.filter((id) => companies.has(id)))}>Remove from selection</Button>
          </p>}
        </div>
        <label className="flex items-start gap-2 text-[13px] text-text-2">
          <input className="mt-0.5" type="checkbox" checked={eligible} onChange={(event) => setEligible(event.target.checked)} />
          Include new rounds matching my current provider-verified eligibility
        </label>
        <label className="flex items-start gap-2 text-[13px] text-text-2">
          <input className="mt-0.5" type="checkbox" checked={digest} onChange={(event) => setDigest(event.target.checked)} />
          Allow Stock Tracker to send published updates for these companies to its AI provider for daily summaries
        </label>
      </>}
      {activeUntil && <p className="text-xs text-text-3">Web monitoring expires {dateLabel(activeUntil)} unless you save preferences again.</p>}
    </fieldset>
    <Button type="submit" variant="primary" disabled={saving}>{saving ? "Saving…" : "Save monitoring preferences"}</Button>
  </form>;
}

function UpdateRow({ title, company, date, revised, significance, url, label, kind }: {
  title: string; company: string; date: string; revised?: string | null; significance: string;
  url?: string | null; label?: string | null; kind?: string;
}) {
  return <li className="space-y-1 border-t border-border p-4 text-[13px] text-text-2">
    <div className="flex flex-wrap items-start justify-between gap-2">
      <h3 className="break-words font-medium text-text">{title}</h3>
      {kind && alertLabels[kind] && <Badge>{alertLabels[kind]}</Badge>}
    </div>
    <p className="text-xs text-text-3">{company} · {dateLabel(date, label === "Issuer financial disclosure" ? "day" : "time")}</p>
    {revised && <p className="text-xs text-text-3">Revised {dateLabel(revised, "time")}</p>}
    <p className="break-words">{significance}</p>
    {(url || label) && <p><SourceLink url={url}>{label ?? "Read source"}</SourceLink></p>}
  </li>;
}

export function Monitoring({ owner, deals, catalogueLoading, catalogueError, retryCatalogue, onReport }: {
  owner: string; deals: PrivateDeal[]; catalogueLoading: boolean; catalogueError?: Error | null;
  retryCatalogue: () => void; onReport: (id: string) => void;
}) {
  const cache = useQueryClient();
  const scope = keyFor(owner);
  const settings = useQuery({
    queryKey: [...scope, "preferences"], gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<SettingsResponse>("web_monitor_preferences", { owner, signal }),
  });
  const preferences = settings.data?.preferences ?? null;
  const save = useMutation({
    mutationFn: (options: Options) => privateMarkets<SettingsResponse>("save_web_monitor", { owner, ...options }),
    onMutate: () => cache.cancelQueries({ queryKey: [...scope, "preferences"] }),
    onSuccess: (value) => {
      cache.setQueryData([...scope, "preferences"], value);
      void cache.invalidateQueries({ queryKey: [...scope, "alerts"] });
    },
  });
  const alerts = useQuery({
    queryKey: [...scope, "alerts"], gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ alerts: MonitorAlert[] }>("monitor_inbox", { owner, signal }),
  });
  const digests = useQuery({
    queryKey: [...scope, "digests"], gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ items: SavedReport[] }>("monitor_digests", { owner, signal }),
  });
  const companyIDs = (preferences?.company_ids ?? []).slice().sort();
  const updates = useQuery({
    queryKey: [...scope, "updates", companyIDs], enabled: companyIDs.length > 0, gcTime: 0, retry: false,
    queryFn: async ({ signal }) => {
      const pages = await Promise.all(Array.from({ length: Math.ceil(companyIDs.length / groupSize) }, (_, index) =>
        privateMarkets<{ updates: CompanyUpdate[] }>("updates", {
          owner, signal, company_ids: companyIDs.slice(index * groupSize, (index + 1) * groupSize),
        })));
      return [...new Map(pages.flatMap((page) => page.updates.map((item) => [item.id, item]))).values()]
        .sort((first, second) => Date.parse(second.revised_at ?? second.published_at) - Date.parse(first.revised_at ?? first.published_at))
        .slice(0, 100);
    },
  });

  return <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,0.75fr)_minmax(0,1fr)]">
    <div className="min-w-0 space-y-4">
      <Card>
        <CardHeader title="Monitoring preferences" />
        {settings.isPending && <p className="border-t border-border p-4 text-sm text-text-2" role="status">Loading preferences…</p>}
        {settings.error && <div className="border-t border-border p-4"><Notice tone="down">{settings.error.message} <Button size="sm" onClick={() => void settings.refetch()}>Retry preferences</Button></Notice></div>}
        {catalogueError && <div className="border-t border-border p-4"><Notice tone="down">{catalogueError.message} <Button size="sm" onClick={retryCatalogue}>Retry catalogue</Button></Notice></div>}
        {catalogueLoading && <p className="border-t border-border p-4 text-sm text-text-2" role="status">Loading published companies…</p>}
        {settings.data && <MonitoringForm key={preferences?.refreshed_at ?? "disabled"} preferences={preferences}
          saving={save.isPending} deals={deals} onSave={(options) => save.mutate(options)} />}
        {save.error && <div className="px-4 pb-4"><Notice tone="down">{save.error.message}</Notice></div>}
        {save.isSuccess && <p className="px-4 pb-4 text-sm text-text-2" role="status">Monitoring preferences saved.</p>}
      </Card>
      <Card>
        <CardHeader title="Daily AI summaries" />
        {digests.isPending && <p className="border-t border-border p-4 text-sm text-text-2" role="status">Loading summaries…</p>}
        {digests.error && <div className="border-t border-border p-4"><Notice tone="down">{digests.error.message} <Button size="sm" onClick={() => void digests.refetch()}>Retry summaries</Button></Notice></div>}
        {digests.data && !digests.data.items.length && <EmptyState title="No saved monitoring summaries" className="border-t border-border" />}
        <ul>{digests.data?.items.map((item) => (
          <li key={item.id} className="border-t border-border p-4 text-sm">
            <button className="break-words text-left font-medium text-primary-fg hover:underline" onClick={() => onReport(item.id)} type="button">{item.title}</button>
            <p className="text-xs text-text-3">{dateLabel(item.created_at, "time")}</p>
          </li>
        ))}</ul>
      </Card>
    </div>
    <div className="min-w-0 space-y-4">
      <Card>
        <CardHeader title="Monitoring inbox" actions={<Button size="sm" disabled={alerts.isFetching} onClick={() => { void alerts.refetch(); void digests.refetch(); }}>Refresh inbox</Button>} />
        {alerts.isPending && <p className="border-t border-border p-4 text-sm text-text-2" role="status">Loading alerts…</p>}
        {alerts.error && <div className="border-t border-border p-4"><Notice tone="down">{alerts.error.message}</Notice></div>}
        {alerts.data && !alerts.data.alerts.length && <EmptyState title="No monitoring alerts" className="border-t border-border" />}
        <ul>{alerts.data?.alerts.map((item) => <UpdateRow key={item.id} title={item.title} company={item.company_name}
          significance={item.significance} date={item.occurred_at} revised={item.revised_at} url={item.source_url}
          label={item.source_label} kind={item.kind} />)}</ul>
      </Card>
      {companyIDs.length > 0 && <Card>
        <CardHeader title="Company updates" />
        {updates.isPending && <p className="border-t border-border p-4 text-sm text-text-2" role="status">Loading company updates…</p>}
        {updates.error && <div className="border-t border-border p-4"><Notice tone="down">{updates.error.message} <Button size="sm" onClick={() => void updates.refetch()}>Retry updates</Button></Notice></div>}
        {updates.data && !updates.data.length && <EmptyState title="No published updates for followed companies" className="border-t border-border" />}
        <ul>{updates.data?.map((item) => <UpdateRow key={item.id} title={item.title} company={item.company.name}
          significance={item.significance} date={item.published_at} revised={item.revised_at} url={item.source_url} label={item.source_label} />)}</ul>
      </Card>}
    </div>
  </div>;
}
