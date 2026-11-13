import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

export function EmptyState({ icon, title, body, actions, className, tone = "neutral" }: {
  icon?: ReactNode; title: string; body?: ReactNode; actions?: ReactNode; className?: string; tone?: "neutral" | "warn" | "down";
}) {
  return (
    <div className={cn("flex flex-col items-center justify-center gap-2 px-6 py-10 text-center", className)} role={tone === "neutral" ? undefined : "status"}>
      {icon ? (
        <div className={cn("mb-1 flex h-10 w-10 items-center justify-center rounded-full",
          tone === "warn" ? "bg-warn-soft text-warn" : tone === "down" ? "bg-down-soft text-down" : "bg-surface-2 text-text-2")}>{icon}</div>
      ) : null}
      <p className="text-sm font-semibold text-text">{title}</p>
      {body ? <div className="max-w-md text-[13px] leading-relaxed text-text-2">{body}</div> : null}
      {actions ? <div className="mt-2 flex flex-wrap justify-center gap-2">{actions}</div> : null}
    </div>
  );
}
