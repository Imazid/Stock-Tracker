"use client";

import type { ConnectionView } from "@oms/api.ts";
import type { ConnectionPermission, ProviderID, TradingEnvironment } from "@brokers/types.ts";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Cable, KeyRound, RefreshCw, ShieldCheck, Unplug } from "lucide-react";
import { useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { useConnections } from "@/hooks/oms";
import { ago } from "@/lib/format";
import { Connections, describeOmsError, newIdempotencyKey, OmsError } from "@/lib/oms-client";
import { useSession } from "@/lib/session";

const PROVIDERS: Record<ProviderID, { name: string; environments: { value: TradingEnvironment; label: string; disabled?: string }[]; keyHelp: string }> = {
  alpaca: {
    name: "Alpaca",
    environments: [{ value: "paper", label: "Paper (simulated money)" }, { value: "live", label: "Live", disabled: "Live trading is off in this build" }],
    keyHelp: "Alpaca dashboard → your paper account → API keys. Paper keys only work against the paper environment.",
  },
  coinbase: {
    name: "Coinbase Advanced Trade",
    environments: [{ value: "live", label: "Your Coinbase account (read-only here)" }],
    keyHelp: "Coinbase Developer Platform → API keys. Give it View permission only. Coinbase has no paper venue, so trading through Coinbase stays off in this build.",
  },
};

function EnvBadge({ environment }: { environment: TradingEnvironment }) {
  return environment === "live" ? <Badge tone="live">LIVE ACCOUNT</Badge> : <Badge tone="warn">{environment.toUpperCase()}</Badge>;
}

function ConnectForm({ onDone }: { onDone: () => void }) {
  const [provider, setProvider] = useState<ProviderID>("alpaca");
  const [environment, setEnvironment] = useState<TradingEnvironment>("paper");
  const [trade, setTrade] = useState(false);
  const [label, setLabel] = useState("");
  const [creds, setCreds] = useState<Record<string, string>>({});
  const [key] = useState(newIdempotencyKey);
  const client = useQueryClient();
  const connect = useMutation({
    mutationFn: () => {
      const permissions: ConnectionPermission[] = trade ? ["read", "trade"] : ["read"];
      const credentials = { ...creds };
      // Keys never stay in browser state once sent.
      setCreds({});
      return Connections.connect({ action: "connect", provider, environment, label: label || undefined, permissions, credentials }, key);
    },
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["connections"] });
      onDone();
    },
  });
  const p = PROVIDERS[provider];
  const canTrade = provider === "alpaca" && environment === "paper";
  const fields = provider === "alpaca"
    ? [{ k: "keyID", label: "API key ID", textarea: false }, { k: "secretKey", label: "Secret key", textarea: false }]
    : [{ k: "keyName", label: "API key name (organizations/…/apiKeys/…)", textarea: false }, { k: "privateKeyPEM", label: "Private key (PEM)", textarea: true }, { k: "portfolioID", label: "Portfolio ID (optional, for a portfolio-scoped key)", textarea: false }];
  const missing = fields.filter((f) => f.k !== "portfolioID").some((f) => !creds[f.k]);
  const err = connect.isError ? describeOmsError(connect.error) : null;

  return (
    <Card>
      <CardHeader title="Connect an account" subtitle="Keys are sent once over TLS, encrypted on the server, and never shown again." />
      <form className="grid gap-3 border-t border-border px-4 py-4" onSubmit={(e) => { e.preventDefault(); connect.mutate(); }} autoComplete="off">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Provider" htmlFor="c-provider"><Select id="c-provider" value={provider} onChange={(e) => { const v = e.target.value as ProviderID; setProvider(v); setEnvironment(PROVIDERS[v].environments[0].value); setTrade(false); setCreds({}); }}>
            <option value="alpaca">Alpaca — US stocks, ETFs, crypto</option><option value="coinbase">Coinbase Advanced Trade — crypto</option></Select></Field>
          <Field label="Environment" htmlFor="c-env"><Select id="c-env" value={environment} onChange={(e) => { setEnvironment(e.target.value as TradingEnvironment); setTrade(false); }}>
            {p.environments.map((env) => <option key={env.value} value={env.value} disabled={Boolean(env.disabled)}>{env.label}{env.disabled ? ` — ${env.disabled}` : ""}</option>)}</Select></Field>
        </div>
        <Field label="Label (optional)" htmlFor="c-label"><Input id="c-label" value={label} maxLength={60} onChange={(e) => setLabel(e.target.value)} placeholder={`${p.name} ${environment}`} /></Field>
        <fieldset className="grid gap-2">
          <legend className="mb-1 text-xs font-medium text-text-2">Permission</legend>
          <label className="flex items-start gap-2 rounded-lg border border-border p-2.5 text-[13px]">
            <input type="radio" name="perm" checked={!trade} onChange={() => setTrade(false)} className="mt-0.5" />
            <span><span className="font-medium text-text">Read only</span><span className="block text-xs text-text-3">Balances, positions and order history. Nothing can be traded.</span></span>
          </label>
          <label className={`flex items-start gap-2 rounded-lg border border-border p-2.5 text-[13px] ${canTrade ? "" : "opacity-50"}`}>
            <input type="radio" name="perm" checked={trade} disabled={!canTrade} onChange={() => setTrade(true)} className="mt-0.5" />
            <span><span className="font-medium text-text">Read and place practice orders</span><span className="block text-xs text-text-3">{canTrade ? "Orders still need a risk check and your approval each time." : "Only available for Alpaca paper accounts in this build."}</span></span>
          </label>
          <p className="flex items-center gap-1.5 text-xs text-text-3"><ShieldCheck aria-hidden className="h-3.5 w-3.5" />Never give a key transfer or withdrawal permission. Nothing here needs it.</p>
        </fieldset>
        {fields.map((f) => (
          <Field key={f.k} label={f.label} htmlFor={`c-${f.k}`}>
            {f.textarea ? (
              <textarea id={`c-${f.k}`} rows={4} spellCheck={false} value={creds[f.k] ?? ""} onChange={(e) => setCreds((c) => ({ ...c, [f.k]: e.target.value }))}
                className="rounded-lg border border-border bg-surface-2 px-3 py-2 font-mono text-xs text-text focus:border-primary focus:outline-none" />
            ) : (
              <Input id={`c-${f.k}`} type={f.k === "secretKey" ? "password" : "text"} spellCheck={false} autoComplete="off" value={creds[f.k] ?? ""} onChange={(e) => setCreds((c) => ({ ...c, [f.k]: e.target.value }))} />
            )}
          </Field>
        ))}
        <p className="flex items-start gap-1.5 text-xs text-text-3"><KeyRound aria-hidden className="mt-0.5 h-3.5 w-3.5 shrink-0" />{p.keyHelp}</p>
        {err ? <Notice tone={err.code === "not_deployed" ? "warn" : "down"} title={err.title}>{err.body}</Notice> : null}
        <div className="flex gap-2"><Button type="submit" variant="primary" disabled={missing || connect.isPending}>{connect.isPending ? "Checking the key…" : "Connect"}</Button></div>
      </form>
    </Card>
  );
}

function ConnectionCard({ c }: { c: ConnectionView }) {
  const client = useQueryClient();
  const [confirmRevoke, setConfirmRevoke] = useState(false);
  const sync = useMutation({ mutationFn: () => Connections.sync(c.id), onSettled: () => client.invalidateQueries({ queryKey: ["connections"] }) });
  const revoke = useMutation({ mutationFn: () => Connections.revoke(c.id), onSettled: () => client.invalidateQueries({ queryKey: ["connections"] }) });
  const err = sync.isError ? describeOmsError(sync.error) : revoke.isError ? describeOmsError(revoke.error) : null;
  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-3 px-4 pt-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2"><h3 className="text-sm font-semibold">{c.label}</h3><EnvBadge environment={c.environment} />
            <Badge tone={c.status === "active" ? "up" : c.status === "needs_attention" ? "warn" : "neutral"}>{c.status.replace("_", " ")}</Badge></div>
          <p className="mt-0.5 text-xs text-text-3">{PROVIDERS[c.provider].name} · key …{c.keyHint} · connected {ago(c.createdAt)}</p>
        </div>
        <div className="flex gap-2">
          <Button size="sm" onClick={() => sync.mutate()} disabled={sync.isPending || c.status === "revoked"}><RefreshCw className={`h-3.5 w-3.5 ${sync.isPending ? "animate-spin" : ""}`} />Sync</Button>
          {confirmRevoke ? (
            <>
              <Button size="sm" variant="danger" onClick={() => revoke.mutate()} disabled={revoke.isPending}>Yes, revoke</Button>
              <Button size="sm" variant="ghost" onClick={() => setConfirmRevoke(false)}>Keep</Button>
            </>
          ) : <Button size="sm" variant="ghost" onClick={() => setConfirmRevoke(true)} disabled={c.status === "revoked"}><Unplug className="h-3.5 w-3.5" />Revoke</Button>}
        </div>
      </div>
      {confirmRevoke ? <p className="px-4 pt-2 text-xs text-warn">Revoking deletes the stored key. Open orders at {PROVIDERS[c.provider].name} are not cancelled by this.</p> : null}
      <div className="grid gap-3 px-4 py-3 text-xs sm:grid-cols-3">
        <div><p className="text-text-3">Permissions</p><p className="mt-0.5 flex gap-1">{c.permissions.map((p) => <Badge key={p} tone={p === "trade" ? "warn" : "neutral"}>{p}</Badge>)}</p></div>
        <div><p className="text-text-3">Last sync</p><p className="mt-0.5 text-text">{c.sync.state === "never" ? "Never" : c.sync.state === "running" ? "Syncing…" : c.sync.lastSuccessAt ? ago(c.sync.lastSuccessAt) : "—"}{c.sync.state === "failed" ? <Badge tone="down" className="ml-1">failed</Badge> : null}</p></div>
        <div><p className="text-text-3">Can trade here</p><p className="mt-0.5 text-text">{c.capabilities.executionAvailable && c.permissions.includes("trade") ? c.capabilities.orders.map((o) => `${o.assetClass === "crypto" ? "Crypto" : "US stocks"}: ${o.orderTypes.join(", ")}`).join(" · ") : "No"}</p></div>
      </div>
      {c.sync.lastError ? <div className="px-4 pb-3"><Notice tone="down" title="Last sync failed">{c.sync.lastError}{c.sync.repair ? <span className="mt-1 block">{c.sync.repair}</span> : null}</Notice></div> : null}
      {c.capabilities.notes.length ? <ul className="list-disc space-y-0.5 border-t border-border px-8 py-3 text-[11px] text-text-3">{c.capabilities.notes.map((n) => <li key={n}>{n}</li>)}</ul> : null}
      {sync.data ? <p className="px-4 pb-3 text-xs text-up" role="status">Synced {sync.data.synced.accounts} accounts, {sync.data.synced.positions} positions, {sync.data.synced.orders} orders, {sync.data.synced.fills} fills.</p> : null}
      {err ? <div className="px-4 pb-3"><Notice tone="down" title={err.title}>{err.body}</Notice></div> : null}
    </Card>
  );
}

export function ConnectionsView() {
  const session = useSession();
  const list = useConnections();
  const [showForm, setShowForm] = useState(false);
  const header = <PageHeader title="Connections" description="Link a brokerage or exchange account. Read-only by default; trading permission only for practice (paper) accounts in this build." actions={session.status === "signedIn" && list.isSuccess ? <Button variant="primary" size="sm" onClick={() => setShowForm((s) => !s)}><Cable className="h-3.5 w-3.5" />{showForm ? "Close" : "Connect account"}</Button> : null} />;

  if (session.status === "unconfigured") return <div className="mx-auto max-w-4xl">{header}<Card><EmptyState title="Accounts aren't configured" body="Connections are stored against your account. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY." /></Card></div>;
  if (session.status === "signedOut") return <div className="mx-auto max-w-4xl">{header}<Card><EmptyState icon={<Cable className="h-5 w-5" />} title="Sign in to connect accounts" actions={<ButtonLink href="/login" variant="primary" size="sm">Sign in</ButtonLink>} /></Card></div>;

  const notDeployed = list.error instanceof OmsError && list.error.code === "not_deployed";
  return (
    <div className="mx-auto max-w-4xl">
      {header}
      {list.isLoading || session.status === "loading" ? <div className="space-y-3">{[0, 1].map((i) => <div key={i} className="skeleton h-28" />)}</div>
        : notDeployed ? (
          <Card><EmptyState icon={<Cable className="h-5 w-5" />} tone="warn" title="Order routing isn't deployed yet"
            body="The broker-connections function isn't running on this backend, so accounts can't be linked from here yet. Nothing is broken on your side." /></Card>
        ) : list.isError ? (() => { const e = describeOmsError(list.error); return <Card><EmptyState tone="down" title={e.title} body={e.body} actions={<Button size="sm" onClick={() => list.refetch()}>Try again</Button>} /></Card>; })()
          : (
            <div className="flex flex-col gap-4">
              {showForm || list.data?.connections.length === 0 ? <ConnectForm onDone={() => setShowForm(false)} /> : null}
              {list.data?.connections.map((c) => <ConnectionCard key={c.id} c={c} />)}
            </div>
          )}
    </div>
  );
}
