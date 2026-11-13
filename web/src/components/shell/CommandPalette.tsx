"use client";

import { useRouter } from "next/navigation";
import { ArrowRight, Loader2, Search } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { useSearch } from "@/hooks/market";
import { cn } from "@/lib/cn";
import { NAV } from "./nav";

interface Item {
  key: string;
  label: string;
  hint: string;
  href: string;
  kind: "instrument" | "page";
}

/** ⌘K / Ctrl+K: jump to any instrument or section. A native <dialog> gives focus trapping and Esc. */
export function CommandPalette({ open, onClose }: { open: boolean; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const router = useRouter();
  const search = useSearch(query);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      dialog.showModal();
      setTimeout(() => inputRef.current?.focus(), 0);
    } else if (!open && dialog.open) dialog.close();
  }, [open]);

  const items = useMemo<Item[]>(() => {
    const q = query.trim().toLowerCase();
    const pages: Item[] = NAV.filter((n) => !n.soon && (q === "" || n.label.toLowerCase().includes(q)))
      .map((n) => ({ key: `page:${n.href}`, label: n.label, hint: "Go to", href: n.href, kind: "page" }));
    const instruments: Item[] = (q === "" ? [] : search.data?.results ?? []).slice(0, 10).map((r) => ({
      key: r.id, label: `${r.symbol} · ${r.name}`, hint: r.venueShort, href: `/markets/${encodeURIComponent(r.id)}`, kind: "instrument",
    }));
    return [...instruments, ...pages];
  }, [query, search.data]);

  const go = (item: Item | undefined) => {
    if (!item) return;
    onClose();
    setQuery("");
    router.push(item.href);
  };

  return (
    <dialog ref={ref} onClose={onClose} aria-label="Search instruments and pages"
      onClick={(e) => { if (e.target === ref.current) onClose(); }}
      className="m-0 mx-auto mt-[12vh] w-[min(640px,calc(100vw-32px))] rounded-xl border border-border-strong bg-surface p-0 text-text shadow-2xl backdrop:bg-black/50 backdrop:backdrop-blur-[2px]">
      <div className="flex items-center gap-2 border-b border-border px-3">
        <Search aria-hidden className="h-4 w-4 text-text-3" />
        <input ref={inputRef} value={query} onChange={(e) => { setQuery(e.target.value); setCursor(0); }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") { setCursor((c) => Math.min(c + 1, items.length - 1)); e.preventDefault(); }
            if (e.key === "ArrowUp") { setCursor((c) => Math.max(c - 1, 0)); e.preventDefault(); }
            if (e.key === "Enter") { go(items[cursor]); e.preventDefault(); }
          }}
          role="combobox" aria-expanded="true" aria-controls="palette-list" aria-activedescendant={items[cursor] ? `palette-${cursor}` : undefined}
          placeholder="Search stocks, ETFs, crypto or pages…" className="h-12 flex-1 bg-transparent text-[15px] outline-none placeholder:text-text-3 focus-visible:outline-none" />
        {search.isFetching ? <Loader2 aria-label="Searching" className="h-4 w-4 animate-spin text-text-3" /> : null}
        <kbd className="rounded border border-border px-1.5 text-[10px] text-text-3">Esc</kbd>
      </div>
      <ul id="palette-list" role="listbox" className="max-h-[50vh] overflow-y-auto p-1.5">
        {items.length === 0 ? (
          <li className="px-3 py-6 text-center text-sm text-text-3">{query.trim() && !search.isFetching ? "No matches" : "Type to search"}</li>
        ) : items.map((item, i) => (
          <li key={item.key} id={`palette-${i}`} role="option" aria-selected={i === cursor}
            onMouseEnter={() => setCursor(i)} onClick={() => go(item)}
            className={cn("flex cursor-pointer items-center justify-between gap-3 rounded-lg px-3 py-2 text-sm", i === cursor ? "bg-surface-2" : "")}>
            <span className="truncate">{item.label}</span>
            <span className="flex shrink-0 items-center gap-2">
              <Badge>{item.hint}</Badge>
              {i === cursor ? <ArrowRight aria-hidden className="h-3.5 w-3.5 text-text-3" /> : null}
            </span>
          </li>
        ))}
      </ul>
      {search.data?.warning ? <p className="border-t border-border px-3 py-2 text-xs text-warn">{search.data.warning}</p> : null}
    </dialog>
  );
}
