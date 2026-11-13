"use client";

import { BrainCircuit, X } from "lucide-react";
import { Button } from "@/components/ui/Button";

/**
 * The slot the research assistant will live in. It isn't built yet, so the panel says so
 * plainly rather than offering a chat box that can't answer.
 */
export function AssistantPanel({ open, onClose }: { open: boolean; onClose: () => void }) {
  if (!open) return null;
  return (
    <aside aria-label="Assistant" className="fixed inset-y-0 right-0 z-40 flex w-full max-w-sm flex-col border-l border-border bg-surface shadow-2xl lg:static lg:z-auto lg:w-80 lg:shadow-none">
      <div className="flex h-14 items-center justify-between border-b border-border px-4">
        <div className="flex items-center gap-2 text-sm font-semibold"><BrainCircuit aria-hidden className="h-4 w-4 text-primary-fg" />Assistant</div>
        <Button variant="ghost" size="sm" onClick={onClose} aria-label="Close assistant"><X className="h-4 w-4" /></Button>
      </div>
      <div className="flex-1 space-y-3 overflow-y-auto p-4 text-[13px] leading-relaxed text-text-2">
        <p className="font-medium text-text">Not available in the web app yet</p>
        <p>The assistant will answer questions about your watchlists, charts and strategies with sources and timestamps, and can draft a strategy or an order for you to review. It will never place an order itself.</p>
        <p>Until it ships, nothing here answers — there&apos;s no chat box pretending to.</p>
        <p className="text-text-3">Needs: an <code className="rounded bg-surface-2 px-1">ANTHROPIC_API_KEY</code> on the server.</p>
      </div>
    </aside>
  );
}
