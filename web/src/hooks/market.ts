"use client";

import { useQuery } from "@tanstack/react-query";
import { getJSON } from "@/lib/api";
import type { CandlesView, ChartRange, InstrumentResponse, QuoteResponse, SearchResponse } from "@/lib/market-types";
import { allSearchFilters, marketSearchParams, type SearchFilters } from "@/lib/market-search";
import { useDebounced } from "./useDebounced";

export function useSearch(query: string, options: { includeIndexes?: boolean; filters?: SearchFilters; useCurrentResults?: boolean } = {}) {
  const term = query.trim();
  const q = useDebounced(term, 220);
  const filters = options.filters ?? allSearchFilters;
  const params = marketSearchParams(q, filters);
  if (options.includeIndexes) params.set("indexes", "1");
  const search = useQuery({
    queryKey: ["search", q, options.includeIndexes === true, filters.assetType, filters.market],
    queryFn: ({ signal }) => getJSON<SearchResponse>(`/api/markets/search?${params}`, signal),
    enabled: q.length > 0 && (!options.useCurrentResults || q === term),
    staleTime: 60_000,
    placeholderData: options.useCurrentResults ? undefined : (previous) => previous,
  });
  return options.useCurrentResults ? { ...search, data: q === term ? search.data : undefined,
    isError: q === term && search.isError, isFetching: Boolean(term) && (q !== term || search.isFetching) } : search;
}

export function useQuote(id: string | undefined, options: { refetchMs?: number } = {}) {
  return useQuery({
    queryKey: ["quote", id],
    queryFn: ({ signal }) => getJSON<QuoteResponse>(`/api/markets/instruments/${encodeURIComponent(id!)}/quote`, signal),
    enabled: Boolean(id),
    refetchInterval: options.refetchMs ?? 30_000,
    staleTime: 10_000,
  });
}

export function useCandles(id: string | undefined, range: ChartRange) {
  return useQuery({
    queryKey: ["candles", id, range],
    queryFn: ({ signal }) => getJSON<CandlesView>(`/api/markets/instruments/${encodeURIComponent(id!)}/candles?range=${range}`, signal),
    enabled: Boolean(id),
    staleTime: range === "1D" ? 30_000 : 120_000,
    refetchInterval: range === "1D" ? 60_000 : false,
    placeholderData: (previous) => (previous && previous.instrument.id === id ? previous : undefined),
  });
}

export function useInstrument(id: string | undefined) {
  return useQuery({
    queryKey: ["instrument", id],
    queryFn: ({ signal }) => getJSON<InstrumentResponse>(`/api/markets/instruments/${encodeURIComponent(id!)}`, signal),
    enabled: Boolean(id),
    staleTime: 60_000,
  });
}
