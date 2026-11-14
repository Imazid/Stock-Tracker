"use client";

import { useQueries } from "@tanstack/react-query";
import { ListChecks, Loader2, Plus, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { InstrumentRow } from "@/components/market/InstrumentRow";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { Segmented } from "@/components/ui/Segmented";
import { useSearch } from "@/hooks/market";
import { defaultWatchlistId, useAccountWatchlistChange, useAccountWatchlists } from "@/hooks/watchlist";
import { getJSON } from "@/lib/api";
import type { InstrumentView, QuoteResponse } from "@/lib/market-types";
import { useSession } from "@/lib/session";

type SortKey = "manual" | "symbol" | "change" | "venue";

function AddPanel({ existing, onAdd, pending }: {
  existing: Set<string>;
  onAdd: (instrument: InstrumentView) => void;
  pending: boolean;
}) {
  const [query, setQuery] = useState("");
  const search = useSearch(query);
  return (
    <Card>
      <CardHeader title="Add to watchlist" />
      <div className="relative px-4 pb-3">
        <Search aria-hidden className="pointer-events-none absolute left-7 top-1/2 h-4 w-4 -translate-y-[60%] text-text-3" />
        <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Ticker or company" aria-label="Search to add" className="pl-9 pr-3" />
      </div>
      {query.trim() ? (
        <ul className="max-h-80 divide-y divide-border overflow-y-auto border-t border-border">
          {search.isFetching && !search.data ? <li className="flex items-center gap-2 px-4 py-3 text-xs text-text-3"><Loader2 className="h-3.5 w-3.5 animate-spin" />Searching…</li> : null}
          {search.data?.results.length === 0 ? <li className="px-4 py-3 text-xs text-text-3">No matches</li> : null}
          {search.data?.results.map((r) => {
            const has = existing.has(r.id);
            return (
              <li key={r.id} className="flex items-center justify-between gap-2 px-4 py-2">
                <span className="min-w-0"><span className="flex items-center gap-1.5 text-sm font-medium">{r.symbol}<Badge>{r.venueShort}</Badge></span><span className="block truncate text-xs text-text-3">{r.name}</span></span>
                <Button size="sm" variant={has ? "ghost" : "secondary"} disabled={has || pending} onClick={() => onAdd(r)} aria-label={has ? `${r.symbol} (${r.venueShort}) is on this list` : `Add ${r.symbol} (${r.venueShort})`}>
                  {has ? "Added" : <><Plus className="h-3.5 w-3.5" />Add</>}
                </Button>
              </li>
            );
          })}
        </ul>
      ) : <p className="border-t border-border px-4 py-3 text-xs text-text-3">Stocks and ETFs on 13 exchanges, plus the crypto we can price.</p>}
    </Card>
  );
}

export function WatchlistsView() {
  const session = useSession();
  if (session.status === "unconfigured") {
    return <div className="mx-auto max-w-5xl"><PageHeader title="Watchlists" /><Card><EmptyState title="Accounts aren't configured" body="Watchlists are saved to your account. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY to enable sign-in." /></Card></div>;
  }
  if (session.status === "signedOut") {
    return <div className="mx-auto max-w-5xl"><PageHeader title="Watchlists" /><Card><EmptyState icon={<ListChecks className="h-5 w-5" />} title="Sign in to see your watchlists" body="Your lists sync with the Stock Tracker iPhone app." actions={<ButtonLink href="/login" variant="primary" size="sm">Sign in</ButtonLink>} /></Card></div>;
  }
  if (session.status === "loading") {
    return <div className="mx-auto max-w-6xl"><PageHeader title="Watchlists" /><Card><div className="skeleton m-4 h-40" /></Card></div>;
  }
  return <AccountWatchlists key={session.user.id} userId={session.user.id} />;
}

function AccountWatchlists({ userId }: { userId: string }) {
  const lists = useAccountWatchlists(userId);
  const change = useAccountWatchlistChange(userId);
  const [selected, setSelected] = useState(defaultWatchlistId);
  const [editing, setEditing] = useState<{ mode: "create" | "rename" | "delete"; groupId: string; listName: string } | null>(null);
  const [name, setName] = useState("");
  const [sort, setSort] = useState<SortKey>("manual");
  const active = lists.data?.find((list) => list.id === selected) ?? lists.data?.[0];
  const items = useMemo(() => active?.assets ?? [], [active]);
  const quotes = useQueries({
    queries: items.map((w) => ({
      queryKey: ["quote", w.instrument.id],
      queryFn: ({ signal }: { signal: AbortSignal }) => getJSON<QuoteResponse>(`/api/markets/instruments/${encodeURIComponent(w.instrument.id)}/quote`, signal),
      refetchInterval: 30_000,
      staleTime: 10_000,
    })),
  });
  const changeById = new Map(items.map((w, i) => [w.instrument.id, quotes[i]?.data?.quote.changePct]));
  const sorted = [...items].sort((a, b) => {
    if (sort === "symbol") return a.instrument.symbol.localeCompare(b.instrument.symbol);
    if (sort === "venue") return a.instrument.venueShort.localeCompare(b.instrument.venueShort) || a.instrument.symbol.localeCompare(b.instrument.symbol);
    if (sort === "change") return (changeById.get(b.instrument.id) ?? -Infinity) - (changeById.get(a.instrument.id) ?? -Infinity);
    return 0;
  });

  function edit(mode: NonNullable<typeof editing>["mode"] | null, initialName = "") {
    change.reset();
    setEditing(mode && active ? { mode, groupId: active.id, listName: active.name } : null);
    setName(initialName);
  }

  function saveList() {
    if (!editing) return;
    if (editing.mode === "delete") {
      change.mutate({ action: "delete", groupId: editing.groupId }, {
        onSuccess: () => { setSelected(defaultWatchlistId); setEditing(null); },
      });
      return;
    }
    const trimmed = name.trim();
    if (!trimmed || Array.from(trimmed).length > 80) return;
    const groupId = editing.mode === "create" ? crypto.randomUUID() : editing.groupId;
    change.mutate({ action: editing.mode, groupId, name: trimmed }, {
      onSuccess: () => { setSelected(groupId); setEditing(null); },
    });
  }

  return (
    <div className="mx-auto max-w-6xl">
      <PageHeader title="Watchlists" description="Your lists sync with the iPhone app." />
      {lists.isLoading ? <Card><div className="skeleton m-4 h-40" /></Card>
        : lists.isError || !active ? <Card><EmptyState tone="down" title="Couldn't load your watchlists" body={lists.error?.message} actions={<Button size="sm" onClick={() => lists.refetch()}>Try again</Button>} /></Card>
          : <>
            <Card className="mb-5 space-y-3 p-4">
              <div className="flex flex-wrap items-end gap-2">
                <Field label="Watchlist" htmlFor="active-watchlist" className="w-full min-w-0 sm:w-64">
                  <Select id="active-watchlist" value={active.id} disabled={change.isPending} onChange={(e) => { setSelected(e.target.value); edit(null); }}>
                    {lists.data?.map((list) => <option key={list.id} value={list.id}>{list.name}</option>)}
                  </Select>
                </Field>
                <Button disabled={change.isPending} onClick={() => edit("create")}><Plus aria-hidden className="h-4 w-4" />New list</Button>
                <Button disabled={change.isPending} onClick={() => edit("rename", active.name)}>Rename</Button>
                {active.id !== defaultWatchlistId ? <Button variant="ghost" disabled={change.isPending} onClick={() => edit("delete")}>Delete list</Button> : null}
              </div>
              {editing ? <form className="flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); saveList(); }}>
                {editing.mode === "delete" ? <p className="w-full break-words text-sm text-text-2">Delete “{editing.listName}” and its saved symbols?</p>
                  : <Field label={editing.mode === "create" ? "New list name" : "List name"} htmlFor="watchlist-name" error={Array.from(name.trim()).length > 80 ? "Use 80 characters or fewer." : undefined} className="w-full min-w-0 sm:w-64">
                    <Input id="watchlist-name" value={name} onChange={(e) => setName(e.target.value)} autoFocus required disabled={change.isPending} />
                  </Field>}
                <Button type="submit" variant={editing.mode === "delete" ? "danger" : "primary"} disabled={change.isPending || (editing.mode !== "delete" && (!name.trim() || Array.from(name.trim()).length > 80))}>
                  {editing.mode === "delete" ? "Confirm deletion" : editing.mode === "create" ? "Create list" : "Save name"}
                </Button>
                <Button variant="ghost" disabled={change.isPending} onClick={() => edit(null)}>Cancel</Button>
              </form> : null}
              {change.isError ? <Notice tone="down">{change.error.message}</Notice> : null}
            </Card>
            <div className="grid gap-5 lg:grid-cols-[1fr_340px]">
              <Card className="min-w-0">
                <CardHeader className="flex-wrap break-words" title={`${active.name}${items.length ? ` · ${items.length}` : ""}`} actions={
                  <Segmented label="Sort" value={sort} onChange={setSort} options={[{ value: "manual", label: "List order" }, { value: "symbol", label: "A–Z" }, { value: "change", label: "Change" }, { value: "venue", label: "Market" }]} />
                } />
                {items.length === 0 ? <EmptyState icon={<ListChecks className="h-5 w-5" />} title="Nothing here yet" body="Search to add stocks, ETFs or crypto." />
                  : <ul className="divide-y divide-border border-t border-border">
                    {sorted.map((w) => (
                      <InstrumentRow key={w.rowId} instrument={w.instrument} trailing={
                        <Button size="sm" variant="ghost" aria-label={`Remove ${w.instrument.symbol} (${w.instrument.venueShort})`} title="Remove" disabled={change.isPending}
                          onClick={() => change.mutate({ action: "remove", groupId: active.id, key: w.key })}><Trash2 className="h-4 w-4" /></Button>
                      } />
                    ))}
                  </ul>}
              </Card>
              <AddPanel key={active.id} existing={new Set(items.map((w) => w.instrument.id))} pending={change.isPending}
                onAdd={(instrument) => change.mutate({ action: "add", groupId: active.id, instrument })} />
            </div>
          </>}
    </div>
  );
}
