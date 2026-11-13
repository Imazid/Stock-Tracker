"use client";

import { UniverseCatalog } from "@engine/catalog.ts";
import { History, Loader2, Search, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { InstrumentRow } from "@/components/market/InstrumentRow";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Input } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { Segmented } from "@/components/ui/Segmented";
import { useSearch } from "@/hooks/market";
import { toView } from "@/lib/instrument-view";
import { clearRecent, readRecent, type RecentInstrument } from "@/lib/recent";

const GROUPS = {
  us: { label: "US", list: [...UniverseCatalog.technology.slice(0, 6), ...UniverseCatalog.otherUS.slice(0, 2)] },
  etf: { label: "ETFs", list: [...UniverseCatalog.broadETFs, ...UniverseCatalog.otherETFs.slice(0, 4)] },
  crypto: { label: "Crypto", list: [...UniverseCatalog.cryptoMajors, ...UniverseCatalog.otherCrypto.slice(0, 5)] },
  asx: { label: "ASX", list: UniverseCatalog.asxBlueChips },
  europe: { label: "Europe", list: [...UniverseCatalog.ukBlueChips.slice(0, 4), ...UniverseCatalog.germanBlueChips.slice(0, 2), ...UniverseCatalog.frenchBlueChips.slice(0, 2)] },
  asia: { label: "Asia", list: [...UniverseCatalog.japanBlueChips.slice(0, 3), ...UniverseCatalog.hongKongBlueChips.slice(0, 3), ...UniverseCatalog.indiaBlueChips.slice(0, 2)] },
} as const;
type GroupKey = keyof typeof GROUPS;

export function MarketsView() {
  const [query, setQuery] = useState("");
  const [group, setGroup] = useState<GroupKey>("us");
  const [recent, setRecent] = useState<RecentInstrument[]>([]);
  const search = useSearch(query);
  useEffect(() => {
    // Browser storage is only readable after hydration.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setRecent(readRecent());
  }, []);
  const groupItems = useMemo(() => GROUPS[group].list.map(toView), [group]);
  const searching = query.trim().length > 0;

  return (
    <div className="mx-auto max-w-5xl">
      <PageHeader title="Markets" description="US, ASX, UK, European and Asian listings and the crypto we can price. Every price shows its source, currency and age." />
      <div className="relative mb-5">
        <Search aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-text-3" />
        <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search by ticker or company — e.g. BHP, Vodafone, Toyota, ETH" aria-label="Search instruments" className="h-11 pl-9 pr-9 text-[15px]" />
        {search.isFetching ? <Loader2 aria-label="Searching" className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-text-3" />
          : query ? <button type="button" aria-label="Clear search" onClick={() => setQuery("")} className="absolute right-3 top-1/2 -translate-y-1/2 text-text-3 hover:text-text"><X className="h-4 w-4" /></button> : null}
      </div>

      {searching ? (
        <Card>
          <CardHeader title={`Results for “${query.trim()}”`} subtitle="Same ticker on two exchanges? They're separate listings with their own prices." />
          {search.data?.warning ? <div className="px-4 pb-3"><Notice tone="warn">{search.data.warning}</Notice></div> : null}
          {search.isError ? <EmptyState tone="down" title="Search isn't available" body="Try again in a moment." />
            : search.data && search.data.results.length === 0 && !search.isFetching ? <EmptyState title="No matches" body="Check the spelling, or try the company name." />
              : !search.data ? <div className="space-y-2 p-4">{[0, 1, 2, 3].map((i) => <div key={i} className="skeleton h-10" />)}</div>
                : <ul className="divide-y divide-border border-t border-border">{search.data.results.map((r) => <InstrumentRow key={r.id} instrument={r} spark={false} />)}</ul>}
        </Card>
      ) : (
        <div className="grid gap-5">
          {recent.length > 0 ? (
            <Card>
              <CardHeader title={<span className="inline-flex items-center gap-1.5"><History aria-hidden className="h-4 w-4 text-text-3" />Recently viewed</span>} subtitle="Kept in this browser only"
                actions={<Button size="sm" variant="ghost" onClick={() => { clearRecent(); setRecent([]); }}>Clear</Button>} />
              <ul className="divide-y divide-border border-t border-border">{recent.slice(0, 6).map((r) => <InstrumentRow key={r.id} instrument={r} spark={false} />)}</ul>
            </Card>
          ) : null}
          <Card>
            <CardHeader title="Browse" actions={
              <Segmented label="Market" value={group} onChange={setGroup} options={(Object.keys(GROUPS) as GroupKey[]).map((k) => ({ value: k, label: GROUPS[k].label }))} />
            } />
            <ul className="divide-y divide-border border-t border-border">{groupItems.map((i) => <InstrumentRow key={i.id} instrument={i} />)}</ul>
          </Card>
        </div>
      )}
    </div>
  );
}
