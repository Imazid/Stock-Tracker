import type { ReactNode } from "react";
import { AlertTriangle, Info, OctagonAlert } from "lucide-react";
import { cn } from "@/lib/cn";

export function Notice({ tone = "info", title, children, className }: { tone?: "info" | "warn" | "down"; title?: string; children?: ReactNode; className?: string }) {
  const Icon = tone === "warn" ? AlertTriangle : tone === "down" ? OctagonAlert : Info;
  return (
    <div role={tone === "info" ? "note" : "status"} className={cn("flex gap-2.5 rounded-lg border px-3 py-2.5 text-[13px] leading-relaxed",
      tone === "warn" ? "border-warn/30 bg-warn-soft" : tone === "down" ? "border-down/30 bg-down-soft" : "border-border bg-surface-2", className)}>
      <Icon aria-hidden className={cn("mt-0.5 h-4 w-4 shrink-0", tone === "warn" ? "text-warn" : tone === "down" ? "text-down" : "text-text-2")} />
      <div className="min-w-0 text-text-2">
        {title ? <p className="font-medium text-text">{title}</p> : null}
        {children}
      </div>
    </div>
  );
}
