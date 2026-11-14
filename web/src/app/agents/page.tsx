import type { Metadata } from "next";
import { AgentsView } from "./agents-view";

export const metadata: Metadata = { title: "Agent Studio" };

export default async function AgentsPage({ searchParams }: { searchParams: Promise<{ run?: string | string[] }> }) {
  const { run } = await searchParams;
  const selectedRun = typeof run === "string" && /^[0-9a-f-]{36}$/i.test(run) ? run : undefined;
  return <AgentsView selectedRun={selectedRun} />;
}
