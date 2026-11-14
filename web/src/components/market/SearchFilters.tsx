"use client";

import { Select } from "@/components/ui/Field";
import { assetTypes, parseSearchFilters, searchMarkets, type SearchFilters as Filters } from "@/lib/market-search";

export function SearchFilters({ filters, onChange }: { filters: Filters; onChange: (filters: Filters) => void }) {
  return <div className="flex min-w-0 flex-wrap gap-2">
    <Select className="max-w-full w-auto" aria-label="Asset type" value={filters.assetType}
      onChange={(event) => onChange(parseSearchFilters(event.target.value, filters.market))}>
      {assetTypes.map(([id, label]) => <option key={id} value={id}>{label}</option>)}
    </Select>
    <Select className="max-w-full w-auto" aria-label="Market" value={filters.market} disabled={filters.assetType === "crypto"}
      onChange={(event) => onChange(parseSearchFilters(filters.assetType, event.target.value))}>
      <option value="">All markets</option>
      {searchMarkets.map(([id, label]) => <option key={id} value={id}>{label}</option>)}
    </Select>
  </div>;
}
