import type { Metadata } from "next";
import { WatchlistsView } from "./watchlists-view";

export const metadata: Metadata = { title: "Watchlists" };

export default async function WatchlistsPage({ searchParams }: { searchParams: Promise<{ list?: string | string[] }> }) {
  const { list } = await searchParams;
  return <WatchlistsView initialList={typeof list === "string" ? list : undefined} />;
}
