import type { Metadata } from "next";
import { PrivateMarketsView } from "./private-markets-view";

export const metadata: Metadata = { title: "Private Markets" };

export default async function PrivateMarketsPage({
  searchParams,
}: {
  searchParams: Promise<{ view?: string | string[]; company?: string | string[] }>;
}) {
  const { view, company } = await searchParams;
  return <PrivateMarketsView aiEnabled={process.env.ENABLE_AI === "true"}
    initialCompany={view === "explorer" && typeof company === "string" ? company : null}
    initialTab={view === "portfolio" || view === "updates" || view === "research" || view === "deal-room" ||
      view === "capital" || view === "explorer" || view === "rounds" ? view : "catalogue"} />;
}
