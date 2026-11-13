import type { InputHTMLAttributes, ReactNode, SelectHTMLAttributes } from "react";
import { cn } from "@/lib/cn";

const CONTROL = "rounded-lg border border-border bg-surface-2 text-sm text-text placeholder:text-text-3 hover:border-border-strong focus:border-primary focus:outline-none disabled:opacity-60";

/** Default size h-9 / w-full unless the caller sets its own height or width. */
function sized(className: string | undefined): string {
  const c = className ?? "";
  return cn(/(^|\s)h-/.test(c) ? "" : "h-9", /(^|\s)w-/.test(c) ? "" : "w-full", /(^|\s)(px|pl|pr)-/.test(c) ? "" : "px-3");
}

export function Input({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return <input className={cn(CONTROL, sized(className), className)} {...props} />;
}

export function Select({ className, children, ...props }: SelectHTMLAttributes<HTMLSelectElement>) {
  return <select className={cn(CONTROL, sized(className), className)} {...props}>{children}</select>;
}

export function Field({ label, hint, error, children, htmlFor, className }: { label: string; hint?: ReactNode; error?: string; children: ReactNode; htmlFor?: string; className?: string }) {
  return (
    <div className={cn("flex flex-col gap-1.5", className)}>
      <label htmlFor={htmlFor} className="text-xs font-medium text-text-2">{label}</label>
      {children}
      {error ? <p className="text-xs text-down" role="alert">{error}</p> : hint ? <p className="text-xs text-text-3">{hint}</p> : null}
    </div>
  );
}
