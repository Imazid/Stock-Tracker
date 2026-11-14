import type { Metadata } from "next";
import { AssistantChat } from "@/components/assistant/AssistantChat";
import { PageHeader } from "@/components/ui/PageHeader";
import { portfolioQuestion } from "@/lib/portfolio-question";

export const metadata: Metadata = { title: "AI Workspace" };

export default async function AIWorkspacePage({ searchParams }: { searchParams: Promise<{ topic?: string }> }) {
  const explainMovement = (await searchParams).topic === "portfolio-movement";
  return (
    <div className="flex h-[calc(100dvh-8rem)] min-h-[32rem] flex-col gap-4">
      <PageHeader
        title="AI Workspace"
        description="Research markets, your watchlist and strategies with sources and timestamps. The assistant reads data and prepares drafts for you to review; it can't place, approve or send an order."
      />
      <AssistantChat key={explainMovement ? "portfolio-movement" : "general"}
        initialQuestion={explainMovement ? portfolioQuestion : undefined} />
    </div>
  );
}
