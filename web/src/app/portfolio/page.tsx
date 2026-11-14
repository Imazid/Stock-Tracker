import type { Metadata } from "next";
import { PortfolioView } from "./portfolio-view";

export const metadata: Metadata = { title: "Portfolio" };

export default async function PortfolioPage({ searchParams }: { searchParams: Promise<{ recordTransfer?: string }> }) {
  return <PortfolioView recordTransfer={(await searchParams).recordTransfer === "1"} />;
}
