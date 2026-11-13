"use client";

import { useQueries } from "@tanstack/react-query";
import { ListChecks, Loader2, Plus, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { InstrumentRow } from "@/components/market/InstrumentRow";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Input } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { Segmented } from "@/components/ui/Segmented";
import { useSearch } from "@/hooks/market";
import { useWatchlist, useWatchlistMutations } from "@/hooks/watchlist";
import { getJSON } from "@/lib/api";
import type { QuoteResponse } from "@/lib/market-types";
import { useSession } from "@/lib/session";

type SortKey = "added" | "symbol" | "change" | "venue";

function AddPanel({ existing }: { existing: Set<string> }) {
  const [query, setQuery] = useState("");
  const search = useSearch(query);
  const { add } = useWatchlistMutations();
  return (
    <Card>
      <CardHeader title="Add to watchlist" />
      <div className="relative px-4 pb-3">
        <Search aria-hidden className="pointer-events-none absolute left-7 top-1/2 h-4 w-4 -translate-y-[60%] text-text-3" />
        <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Ticker or company" aria-label="Search to add" className="pl-9 pr-3" />
      </div>
      {add.isError ? <div className="px-4 pb-3"><Notice tone="down">{(add.error as Error).message}</Notice></div> : null}
      {query.trim() ? (
        <ul className="max-h-80 divide-y divide-border overflow-y-auto border-t border-border">
          {search.isFetching && !search.data ? <li className="flex items-center gap-2 px-4 py-3 text-xs text-text-3"><Loader2 className="h-3.5 w-3.5 animate-spin" />Searching…</li> : null}
          {search.data?.results.length === 0 ? <li className="px-4 py-3 text-xs text-text-3">No matches</li> : null}
          {search.data?.results.map((r) => {
            const has = existing.has(r.id);
            return (
              <li key={r.id} className="flex items-center justify-between gap-2 px-4 py-2">
                <span className="min-w-0"><span className="flex items-center gap-1.5 text-sm font-medium">{r.symbol}<Badge>{r.venueShort}</Badge></span><span className="block truncate text-xs text-text-3">{r.name}</span></span>
                <Button size="sm" variant={has ? "ghost" : "secondary"} disabled={has || add.isPending} onClick={() => add.mutate(r)} aria-label={has ? `${r.symbol} is on your watchlist` : `Add ${r.symbol}`}>
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
  const list = useWatchlist();
  const { remove } = useWatchlistMutations();
  const [sort, setSort] = useState<SortKey>("added");
  const items = useMemo(() => list.data ?? [], [list.data]);
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

  if (session.status === "unconfigured") {
    return <div className="mx-auto max-w-5xl"><PageHeader title="Watchlists" /><Card><EmptyState title="Accounts aren't configured" body="Watchlists are saved to your account. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY to enable sign-in." /></Card></div>;
  }
  if (session.status === "signedOut") {
    return <div className="mx-auto max-w-5xl"><PageHeader title="Watchlists" /><Card><EmptyState icon={<ListChecks className="h-5 w-5" />} title="Sign in to see your watchlist" body="It syncs with the Stock Tracker iPhone app." actions={<ButtonLink href="/login" variant="primary" size="sm">Sign in</ButtonLink>} /></Card></div>;
  }

  return (
    <div className="mx-auto max-w-6xl">
      <PageHeader title="Watchlists" description="One list, shared with the iPhone app. Prices refresh every 30 seconds." />
      <div className="grid gap-5 lg:grid-cols-[1fr_340px]">
        <Card className="min-w-0">
          <CardHeader title={`My watchlist${items.length ? ` · ${items.length}` : ""}`} actions={
            <Segmented label="Sort" value={sort} onChange={setSort} options={[{ value: "added", label: "Added" }, { value: "symbol", label: "A–Z" }, { value: "change", label: "Change" }, { value: "venue", label: "Market" }]} />
          } />
          {remove.isError ? <div className="px-4 pb-3"><Notice tone="down">{(remove.error as Error).message}</Notice></div> : null}
          {session.status === "loading" || list.isLoading ? <div className="space-y-2 p-4">{[0, 1, 2, 3].map((i) => <div key={i} className="skeleton h-11" />)}</div>
            : list.isError ? <EmptyState tone="down" title="Couldn't load your watchlist" body={(list.error as Error).message} actions={<Button size="sm" onClick={() => list.refetch()}>Try again</Button>} />
              : items.length === 0 ? <EmptyState icon={<ListChecks className="h-5 w-5" />} title="Nothing here yet" body="Search on the right to add stocks, ETFs or crypto." />
                : (
                  <ul className="divide-y divide-border border-t border-border">
                    {sorted.map((w) => (
                      <InstrumentRow key={w.rowId} instrument={w.instrument} trailing={
                        <Button size="sm" variant="ghost" aria-label={`Remove ${w.instrument.symbol}`} title="Remove" disabled={remove.isPending}
                          onClick={() => remove.mutate(w.rowId)}><Trash2 className="h-4 w-4" /></Button>
                      } />
                    ))}
                  </ul>
                )}
        </Card>
        <div className="flex flex-col gap-4">
          <AddPanel existing={new Set(items.map((w) => w.instrument.id))} />
          <p className="px-1 text-[11px] leading-relaxed text-text-3">Named lists (several watchlists, grouped by theme) need a schema change the iPhone app hasn&apos;t made yet, so there&apos;s one list for now.</p>
        </div>
      </div>
    </div>
  );
}
