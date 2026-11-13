import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

export type Tone = "neutral" | "primary" | "up" | "down" | "warn" | "live";

const TONES: Record<Tone, string> = {
  neutral: "bg-surface-2 text-text-2 border-border",
  primary: "bg-primary-soft text-primary-fg border-transparent",
  up: "bg-up-soft text-up border-transparent",
  down: "bg-down-soft text-down border-transparent",
  warn: "bg-warn-soft text-warn border-transparent",
  live: "bg-live-soft text-live border-live/40",
};

export function Badge({ tone = "neutral", children, className, title }: { tone?: Tone; children: ReactNode; className?: string; title?: string }) {
  return (
    <span title={title} className={cn("inline-flex items-center gap-1 rounded-md border px-1.5 py-0.5 text-[11px] font-medium leading-4 whitespace-nowrap", TONES[tone], className)}>
      {children}
    </span>
  );
}
