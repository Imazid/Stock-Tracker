"use client";

import { useRouter } from "next/navigation";
import { ArrowRight, Loader2, Search, X } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";
import { RecentSearches } from "@/components/market/RecentSearches";
import { SearchFilters } from "@/components/market/SearchFilters";
import { Badge } from "@/components/ui/Badge";
import { Select } from "@/components/ui/Field";
import { Button } from "@/components/ui/Button";
import { useSearch } from "@/hooks/market";
import { cn } from "@/lib/cn";
import { allSearchFilters, marketSearchParams, maxSearchLength, searchMarkets, type SearchFilters as Filters, type SearchMarket } from "@/lib/market-search";
import type { SearchResult } from "@/lib/market-types";
import { recordSearch, type RecentSearch } from "@/lib/recent-searches";
import { NAV } from "./nav";

type Page = { label: string; href: string; select?: () => void };
type Item = { key: string; label: string; hint: string; href: string; select?: () => void; result?: SearchResult };

const pages = NAV.filter((item) => !item.soon);

export function CommandPalette({ open, onClose, destinations = pages, onInstrument, onCustomTicker }: {
  open: boolean;
  onClose: () => void;
  destinations?: readonly Page[];
  onInstrument?: (result: SearchResult) => void;
  onCustomTicker?: (ticker: string, venue: SearchMarket | "crypto") => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const title = useId();
  const list = useId();
  const [query, setQuery] = useState("");
  const [filters, setFilters] = useState<Filters>(allSearchFilters);
  const [cursor, setCursor] = useState(0);
  const [manual, setManual] = useState(false);
  const [venue, setVenue] = useState<SearchMarket | "crypto">("us");
  const router = useRouter();
  const search = useSearch(open && !manual ? query : "", { includeIndexes: true, filters, useCurrentResults: true });

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      dialog.showModal();
      inputRef.current?.focus();
    } else if (!open && dialog.open) dialog.close();
  }, [open]);

  const term = query.trim();
  const results: Item[] = (term ? search.data?.results ?? [] : []).slice(0, 8).map((result) => ({
    key: result.id, label: `${result.symbol} · ${result.name}`, hint: result.venueShort,
    href: `/markets/${encodeURIComponent(result.id)}`, result,
  }));
  const destinationsForQuery = destinations.filter((page) => !term || page.label.toLowerCase().includes(term.toLowerCase()))
    .map((page) => ({ ...page, key: `page:${page.href}`, hint: "Go to" }));
  const items = [...results, ...destinationsForQuery];
  const selected = Math.min(cursor, items.length - 1);
  const validTicker = /^[A-Za-z0-9][A-Za-z0-9.-]{0,15}$/.test(term);

  function close() {
    setQuery("");
    setFilters(allSearchFilters);
    setCursor(0);
    setManual(false);
    onClose();
  }

  function go(item: Item) {
    if (item.result && term) recordSearch(term, filters);
    close();
    if (item.result && onInstrument && !item.result.symbol.startsWith("^")) onInstrument(item.result);
    else if (item.select) item.select();
    else router.push(item.href);
  }

  function fullSearch() {
    if (!term) return;
    recordSearch(term, filters);
    close();
    router.push(`/markets?${marketSearchParams(term, filters)}`);
  }

  function chooseRecent(entry: RecentSearch) {
    setQuery(entry.query);
    changeFilters({ assetType: entry.assetType, market: entry.market });
    inputRef.current?.focus();
  }

  function changeFilters(next: Filters) {
    setFilters(next);
    setCursor(0);
  }

  useEffect(() => {
    if (open && !manual && selected >= 0 && document.activeElement === inputRef.current) {
      document.getElementById(`${list}-${selected}`)?.scrollIntoView({ block: "nearest" });
    }
  }, [open, manual, selected, list]);

  return (
    <dialog ref={ref} aria-labelledby={title}
      onCancel={(event) => { event.preventDefault(); close(); }}
      onClick={(event) => { if (event.target === ref.current) close(); }}
      className="m-0 mx-auto mt-[8vh] max-h-[84dvh] w-[min(640px,calc(100vw-28px))] overflow-y-auto rounded-xl border border-border-strong bg-surface p-0 text-text shadow-2xl backdrop:bg-black/50">
      <div className="flex items-center gap-2 px-3 py-2">
        <h2 id={title} className="flex-1 text-sm font-semibold">Search workspace</h2>
        <Button type="button" variant="ghost" size="sm" aria-label="Close search" onClick={close}><X aria-hidden className="h-4 w-4" /></Button>
      </div>
      <form onSubmit={(event) => {
        event.preventDefault();
        if (manual) {
          if (!validTicker || !onCustomTicker) return;
          close();
          onCustomTicker(term, venue);
        } else if (items[selected]) go(items[selected]);
        else fullSearch();
      }}>
        <div className="flex items-center gap-2 border-y border-border px-3">
          <Search aria-hidden className="h-4 w-4 shrink-0 text-text-3" />
          <input ref={inputRef} value={query} maxLength={maxSearchLength}
            onChange={(event) => { setQuery(event.target.value); setCursor(0); }}
            onKeyDown={(event) => {
              if (manual || (event.key !== "ArrowDown" && event.key !== "ArrowUp")) return;
              event.preventDefault();
              const next = selected + (event.key === "ArrowDown" ? 1 : -1);
              if (items.length) setCursor((next + items.length) % items.length);
            }}
            aria-label={manual ? "Enter a ticker" : "Search assets or jump to a page"}
            role={manual ? undefined : "combobox"} aria-autocomplete={manual ? undefined : "list"} aria-expanded={manual ? undefined : items.length > 0}
            aria-controls={manual ? undefined : list} aria-activedescendant={!manual && items[selected] ? `${list}-${selected}` : undefined}
            placeholder={manual ? "Enter a ticker" : "Search stocks, ETFs, crypto or pages…"} className="h-11 min-w-0 flex-1 bg-transparent text-[15px] outline-none placeholder:text-text-3" />
          {search.isFetching && <Loader2 aria-hidden className="h-4 w-4 shrink-0 animate-spin text-text-3" />}
        </div>
        {manual ? <div className="flex flex-wrap items-center gap-2 px-3 py-3">
          <Select className="max-w-full w-auto" aria-label="Exchange" value={venue} onChange={(event) => setVenue(event.target.value as typeof venue)}>
            {searchMarkets.map(([key, label]) => <option key={key} value={key}>{label}</option>)}
            <option value="crypto">Crypto</option>
          </Select>
          <Button size="sm" type="submit" disabled={!validTicker}>Open ticker</Button>
          <Button size="sm" type="button" variant="ghost" onClick={() => { setManual(false); inputRef.current?.focus(); }}>Back to search</Button>
        </div> : <>
          <div className="px-3 py-2"><SearchFilters filters={filters} onChange={changeFilters} /></div>
          {!term && <RecentSearches onChoose={chooseRecent} />}
          <p role="status" className="sr-only">{search.isFetching ? "Searching…" : search.isError ? "Search unavailable" : items[selected]?.label ?? "No matching results"}</p>
          <ul id={list} role="listbox" aria-label="Search results" hidden={!items.length}
            className="max-h-[min(40dvh,20rem)] overflow-y-auto border-t border-border p-1.5">
            {items.map((item, index) => (
              <li key={item.key} id={`${list}-${index}`} role="option" aria-selected={index === selected}
                onMouseEnter={() => setCursor(index)} onClick={() => go(item)}
                className={cn("flex min-h-9 cursor-pointer items-center justify-between gap-2 rounded-lg px-3 py-2 text-sm", index === selected && "bg-surface-2")}>
                <span className="truncate">{item.label}</span>
                <span className="flex shrink-0 items-center gap-2">
                  <Badge>{item.hint}</Badge>
                  {index === selected && <ArrowRight aria-hidden className="h-3.5 w-3.5 text-text-3" />}
                </span>
              </li>
            ))}
          </ul>
          {term && !items.length && !search.isFetching && !search.isError &&
            <p className="border-t border-border px-3 py-3 text-sm text-text-2">No matches</p>}
          {search.isError && <div className="flex flex-wrap items-center gap-2 border-t border-border px-3 py-2 text-sm text-text-2">
            Search unavailable. <Button size="sm" type="button" onClick={() => void search.refetch()}>Retry search</Button>
          </div>}
          {search.data?.warning && <p className="border-t border-border px-3 py-2 text-xs text-warn">{search.data.warning}</p>}
          {(term || onCustomTicker) && <div className="flex flex-wrap gap-2 border-t border-border px-3 py-2">
            {term && <Button type="button" size="sm" variant="ghost" onClick={fullSearch}>Open results in Markets <ArrowRight aria-hidden className="h-4 w-4" /></Button>}
            {onCustomTicker && <Button type="button" size="sm" variant="ghost" onClick={() => {
              setVenue(filters.assetType === "crypto" ? "crypto" : filters.market || "us");
              setManual(true);
              inputRef.current?.focus();
            }}>Enter any ticker</Button>}
          </div>}
        </>}
      </form>
    </dialog>
  );
}
