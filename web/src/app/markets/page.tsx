import { maxSearchLength, parseSearchFilters } from "@/lib/market-search";
import type { Metadata } from "next";
import { MarketsView } from "./markets-view";

export const metadata: Metadata = { title: "Markets" };

export default async function MarketsPage({ searchParams }: {
  searchParams: Promise<{ q?: string | string[]; assetType?: string | string[]; market?: string | string[] }>;
}) {
  const params = await searchParams;
  const query = typeof params.q === "string" ? params.q.trim().slice(0, maxSearchLength) : "";
  const filters = parseSearchFilters(params.assetType, params.market);
  return <MarketsView key={JSON.stringify([query, filters])} initialQuery={query} initialFilters={filters} />;
}
