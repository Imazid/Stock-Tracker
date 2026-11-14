import type { Metadata } from "next";
import { AssistantChat } from "@/components/assistant/AssistantChat";
import { PageHeader } from "@/components/ui/PageHeader";
import { portfolioQuestion } from "@/lib/portfolio-question";
import { AGENT_ACTIVITY_QUESTION } from "@/lib/agent-activity-question";

export const metadata: Metadata = { title: "AI Workspace" };

export default async function AIWorkspacePage({ searchParams }: { searchParams: Promise<{ topic?: string }> }) {
  const { topic } = await searchParams;
  const initialQuestion = topic === "portfolio-movement" ? portfolioQuestion : topic === "agent-activity" ? AGENT_ACTIVITY_QUESTION : undefined;
  return (
    <div className="flex h-[calc(100dvh-8rem)] min-h-[32rem] flex-col gap-4">
      <PageHeader
        title="AI Workspace"
        description="Research markets, your watchlist and strategies with sources and timestamps. The assistant reads data and prepares drafts for you to review; it can't place, approve or send an order."
      />
      <AssistantChat key={initialQuestion ?? "general"} initialQuestion={initialQuestion} />
    </div>
  );
}
