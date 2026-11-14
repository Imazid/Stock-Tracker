"use client";

import { UniverseCatalog } from "@engine/catalog.ts";
import { makeInstrument } from "@engine/market.ts";
import { History, Loader2, Search, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { RecentSearches } from "@/components/market/RecentSearches";
import { SearchFilters } from "@/components/market/SearchFilters";
import { maxSearchLength, type SearchFilters as Filters } from "@/lib/market-search";
import { recordSearch, type RecentSearch } from "@/lib/recent-searches";
import { InstrumentRow } from "@/components/market/InstrumentRow";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { Segmented } from "@/components/ui/Segmented";
import { useSearch } from "@/hooks/market";
import { marketIndexes } from "@/lib/market-indexes";
import { ExploreWatchlists, MarketRankings } from "./explore-panels";
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

const THEMES = {
  tech: { label: "AI & semiconductors", list: UniverseCatalog.semiconductors },
  finance: { label: "Financials", list: UniverseCatalog.financials },
  health: { label: "Healthcare", list: UniverseCatalog.healthcare },
  energy: { label: "Energy", list: UniverseCatalog.energy },
  dividend: { label: "Dividend ETFs", list: [
    makeInstrument("VYM", "etf", "us", "Vanguard High Dividend Yield ETF"),
    makeInstrument("SCHD", "etf", "us", "Schwab U.S. Dividend Equity ETF"),
    makeInstrument("VHY", "etf", "asx", "Vanguard Australian Shares High Yield ETF"),
  ] },
  networks: { label: "Blockchain networks", list: UniverseCatalog.cryptoMajors },
  defi: { label: "DeFi protocols", list: UniverseCatalog.otherCrypto.filter((coin) => ["LINK", "UNI"].includes(coin.symbol)) },
} as const;
type ThemeKey = keyof typeof THEMES;

export function MarketsView({ initialQuery, initialFilters }: { initialQuery: string; initialFilters: Filters }) {
  const [query, setQuery] = useState(initialQuery);
  const [group, setGroup] = useState<GroupKey>("us");
  const [theme, setTheme] = useState<ThemeKey>("tech");
  const [filters, setFilters] = useState(initialFilters);
  const [recent, setRecent] = useState<RecentInstrument[]>([]);
  const search = useSearch(query, { includeIndexes: true, filters, useCurrentResults: true });
  useEffect(() => {
    // Browser storage is only readable after hydration.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setRecent(readRecent());
  }, []);
  const groupItems = useMemo(() => GROUPS[group].list.map(toView), [group]);
  const searching = query.trim().length > 0;
  function focusSearch() {
    document.getElementById("markets-search")?.focus();
  }

  function chooseRecent(entry: RecentSearch) {
    setQuery(entry.query);
    setFilters({ assetType: entry.assetType, market: entry.market });
    focusSearch();
  }

  return (
    <div className="mx-auto max-w-5xl">
      <PageHeader title="Markets" description="US, ASX, UK, European and Asian listings and the crypto we can price. Every price shows its source, currency and age." />
      <form className="mb-5 space-y-2" onSubmit={(event) => { event.preventDefault(); recordSearch(query, filters); }}>
        <div className="relative">
          <Search aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-text-3" />
          <Input id="markets-search" value={query} maxLength={maxSearchLength} onChange={(event) => setQuery(event.target.value)}
            placeholder="Search ticker, name, exchange or identifier" aria-label="Search instruments" className="h-11 pl-9 pr-16 text-[15px]" />
          {search.isFetching && <Loader2 aria-hidden className="absolute right-10 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-text-3" />}
          {query && <button type="button" aria-label="Clear search" onClick={() => { setQuery(""); focusSearch(); }}
            className="absolute right-1 top-1/2 grid h-9 w-9 -translate-y-1/2 place-items-center rounded-md text-text-3 hover:text-text"><X className="h-4 w-4" /></button>}
        </div>
        <SearchFilters filters={filters} onChange={setFilters} />
      </form>

      {searching ? (
        <Card>
          <CardHeader title={`Results for “${query.trim()}”`} />
          {search.data?.warning ? <div className="px-4 pb-3"><Notice tone="warn">{search.data.warning}</Notice></div> : null}
          <p role="status" className="sr-only">{search.isFetching ? "Searching…" : search.data ? `${search.data.results.length} results` : ""}</p>
          {search.isError ? <EmptyState tone="down" title="Search isn't available"
            actions={<Button size="sm" onClick={() => void search.refetch()}>Retry search</Button>} />
            : !search.data ? <div aria-hidden="true" className="space-y-2 p-4">{[0, 1, 2, 3].map((i) => <div key={i} className="skeleton h-10" />)}</div>
              : search.data.results.length === 0 ? <EmptyState title="No matches" body="Try another market, asset type, ticker or company name." />
                : <ul className="divide-y divide-border border-t border-border">{search.data.results.map((r) =>
                  <InstrumentRow key={r.id} instrument={r} showQuote={false} onNavigate={() => recordSearch(query, filters)} />)}</ul>}
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-5">
          <RecentSearches onChoose={chooseRecent} />
          <Card>
            <CardHeader title="Market indexes" />
            <ul className="grid grid-cols-1 divide-y divide-border border-t border-border sm:grid-cols-2 sm:divide-y-0">
              {marketIndexes.map((item) => toView(item)).map(item => <InstrumentRow key={item.id} instrument={item} spark={false} />)}
            </ul>
          </Card>
          <MarketRankings />
          <ExploreWatchlists />
          {recent.length > 0 ? (
            <Card>
              <CardHeader title={<span className="inline-flex items-center gap-1.5"><History aria-hidden className="h-4 w-4 text-text-3" />Recently viewed</span>} subtitle="Kept in this browser only"
                actions={<Button size="sm" variant="ghost" onClick={() => { clearRecent(); setRecent([]); }}>Clear</Button>} />
              <ul className="divide-y divide-border border-t border-border">{recent.slice(0, 6).map((r) => <InstrumentRow key={r.id} instrument={r} spark={false} />)}</ul>
            </Card>
          ) : null}
          <Card>
            <CardHeader title="Browse markets" className="flex-wrap [&>div:last-child]:min-w-0 [&>div:last-child]:shrink" actions={
              <Segmented className="max-w-full flex-wrap" label="Market" value={group} onChange={setGroup} options={(Object.keys(GROUPS) as GroupKey[]).map((k) => ({ value: k, label: GROUPS[k].label }))} />
            } />
            <ul className="divide-y divide-border border-t border-border">{groupItems.map((i) => <InstrumentRow key={i.id} instrument={i} />)}</ul>
          </Card>
          <Card>
            <CardHeader title="Sectors & themes" className="flex-wrap" actions={
              <Select aria-label="Market theme" value={theme} onChange={(event) => setTheme(event.target.value as ThemeKey)}>
                {(Object.keys(THEMES) as ThemeKey[]).map(key => <option key={key} value={key}>{THEMES[key].label}</option>)}
              </Select>
            } />
            <ul className="divide-y divide-border border-t border-border">
              {THEMES[theme].list.map(toView).map(item => <InstrumentRow key={item.id} instrument={item} spark={false} />)}
            </ul>
          </Card>
        </div>
      )}
    </div>
  );
}
