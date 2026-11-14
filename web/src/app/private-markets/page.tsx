import type { Metadata } from "next";
import { PrivateMarketsView } from "./private-markets-view";

export const metadata: Metadata = { title: "Private Markets" };

export default async function PrivateMarketsPage({
  searchParams,
}: {
  searchParams: Promise<{ view?: string | string[] }>;
}) {
  const { view } = await searchParams;
  return <PrivateMarketsView aiEnabled={process.env.ENABLE_AI === "true"}
    initialTab={view === "portfolio" || view === "updates" || view === "research" || view === "deal-room" ? view : "catalogue"} />;
}
