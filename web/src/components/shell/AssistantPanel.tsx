"use client";

import { BrainCircuit, Maximize2, X } from "lucide-react";
import { AssistantChat } from "@/components/assistant/AssistantChat";
import { Button, ButtonLink } from "@/components/ui/Button";

/** The research assistant beside every page. The full-size version is the AI Workspace (/ai). */
export function AssistantPanel({ open, onClose }: { open: boolean; onClose: () => void }) {
  if (!open) return null;
  return (
    <aside aria-label="Assistant" className="fixed inset-y-0 right-0 z-40 flex w-full max-w-sm flex-col border-l border-border bg-surface shadow-2xl lg:static lg:z-auto lg:w-96 lg:shadow-none">
      <div className="flex h-14 items-center justify-between border-b border-border px-4">
        <div className="flex items-center gap-2 text-sm font-semibold"><BrainCircuit aria-hidden className="h-4 w-4 text-primary-fg" />Assistant</div>
        <div className="flex items-center gap-1">
          <ButtonLink href="/ai" variant="ghost" size="sm"><Maximize2 aria-label="Open the AI Workspace" className="h-4 w-4" /></ButtonLink>
          <Button variant="ghost" size="sm" onClick={onClose} aria-label="Close assistant"><X className="h-4 w-4" /></Button>
        </div>
      </div>
      <AssistantChat compact />
    </aside>
  );
}
