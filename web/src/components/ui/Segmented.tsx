"use client";

import { cn } from "@/lib/cn";

/** A radio group drawn as a segmented control; arrow keys move between options. */
export function Segmented<T extends string>({ options, value, onChange, label, size = "sm", className }: {
  options: { value: T; label: string; disabled?: boolean }[]; value: T; onChange: (value: T) => void; label: string; size?: "sm" | "xs"; className?: string;
}) {
  return (
    <div role="radiogroup" aria-label={label} className={cn("inline-flex rounded-lg border border-border bg-surface-2 p-0.5", className)}
      onKeyDown={(e) => {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        const enabled = options.filter((o) => !o.disabled);
        const i = enabled.findIndex((o) => o.value === value);
        const next = enabled[(i + (e.key === "ArrowRight" ? 1 : enabled.length - 1)) % enabled.length];
        if (next) onChange(next.value);
        e.preventDefault();
      }}>
      {options.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={o.value === value} disabled={o.disabled}
          tabIndex={o.value === value ? 0 : -1}
          onClick={() => onChange(o.value)}
          className={cn("rounded-md font-medium transition-colors disabled:opacity-40",
            size === "sm" ? "h-7 px-2.5 text-xs" : "h-6 px-2 text-[11px]",
            o.value === value ? "bg-surface text-text shadow-sm" : "text-text-2 hover:text-text")}>
          {o.label}
        </button>
      ))}
    </div>
  );
}
