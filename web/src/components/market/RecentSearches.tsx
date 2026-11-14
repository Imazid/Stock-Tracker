"use client";

import { Button } from "@/components/ui/Button";
import { useSearchHistory } from "@/hooks/search-history";
import { assetTypes, searchMarkets } from "@/lib/market-search";
import { clearSearchHistory, type RecentSearch } from "@/lib/recent-searches";

export function RecentSearches({ onChoose }: { onChoose: (entry: RecentSearch) => void }) {
  const entries = useSearchHistory();
  if (!entries.length) return null;
  return <section aria-label="Recent searches" className="min-w-0 border-t border-border px-3 py-2">
    <div className="mb-1 flex items-center justify-between gap-2">
      <h2 className="text-xs font-medium text-text-2">Recent searches</h2>
      <Button type="button" size="sm" variant="ghost" aria-label="Clear recent searches" onClick={clearSearchHistory}>Clear</Button>
    </div>
    <ul className="flex flex-wrap gap-2">
      {entries.map((entry) => {
        const tags = [entry.assetType === "all" ? "" : assetTypes.find(([key]) => key === entry.assetType)?.[1],
          searchMarkets.find(([key]) => key === entry.market)?.[1]].filter(Boolean);
        return <li key={JSON.stringify(entry)} className="min-w-0 max-w-full">
          <Button type="button" variant="secondary" size="sm" className="h-auto min-h-8 max-w-full whitespace-normal text-left"
            onClick={() => onChoose(entry)}>
            <span className="min-w-0 break-words">{entry.query}{tags.length > 0 && <span className="text-text-2"> · {tags.join(" · ")}</span>}</span>
          </Button>
        </li>;
      })}
    </ul>
  </section>;
}
