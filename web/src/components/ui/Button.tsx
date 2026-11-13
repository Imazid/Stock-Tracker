import Link from "next/link";
import type { ButtonHTMLAttributes, ReactNode } from "react";
import { cn } from "@/lib/cn";

type Variant = "primary" | "secondary" | "ghost" | "danger" | "buy" | "sell";
type Size = "sm" | "md";

const VARIANTS: Record<Variant, string> = {
  primary: "bg-primary text-primary-text hover:bg-primary-hover",
  secondary: "bg-surface-2 text-text border border-border hover:bg-surface-3 hover:border-border-strong",
  ghost: "text-text-2 hover:text-text hover:bg-surface-2",
  danger: "bg-down-soft text-down border border-transparent hover:border-down",
  buy: "bg-up text-[#04140b] hover:brightness-110",
  sell: "bg-down text-white hover:brightness-110",
};

const SIZES: Record<Size, string> = {
  sm: "h-8 px-3 text-[13px] gap-1.5",
  md: "h-9 px-4 text-sm gap-2",
};

const BASE = "inline-flex items-center justify-center rounded-lg font-medium transition-colors disabled:opacity-50 disabled:pointer-events-none whitespace-nowrap select-none";

export function Button({ variant = "secondary", size = "md", className, ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: Size }) {
  return <button type="button" className={cn(BASE, VARIANTS[variant], SIZES[size], className)} {...props} />;
}

export function ButtonLink({ href, variant = "secondary", size = "md", className, children }: { href: string; variant?: Variant; size?: Size; className?: string; children: ReactNode }) {
  return <Link href={href} className={cn(BASE, VARIANTS[variant], SIZES[size], className)}>{children}</Link>;
}
