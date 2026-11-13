import type { Metadata } from "next";
import { AssistantChat } from "@/components/assistant/AssistantChat";
import { PageHeader } from "@/components/ui/PageHeader";

export const metadata: Metadata = { title: "AI Workspace" };

export default function AIWorkspacePage() {
  return (
    <div className="flex h-[calc(100dvh-8rem)] min-h-[32rem] flex-col gap-4">
      <PageHeader
        title="AI Workspace"
        description="Research markets, your watchlist and strategies with sources and timestamps. The assistant reads data and prepares drafts for you to review; it can't place, approve or send an order."
      />
      <AssistantChat />
    </div>
  );
}
