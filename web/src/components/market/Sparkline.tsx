"use client";

import { useCandles } from "@/hooks/market";
import { cn } from "@/lib/cn";

/** A tiny intraday line from real 1D candles. Nothing is drawn when there's no data. */
export function Sparkline({ id, className, baseline }: { id: string; className?: string; baseline?: number }) {
  const { data, isLoading, isError } = useCandles(id, "1D");
  if (isLoading) return <div aria-hidden className={cn("skeleton h-8 w-24", className)} />;
  const closes = data?.candles.map((c) => c.close) ?? [];
  if (isError || closes.length < 2) return <div aria-hidden className={cn("h-8 w-24", className)} />;
  const ref = baseline ?? closes[0];
  const min = Math.min(...closes, ref), max = Math.max(...closes, ref);
  const span = max - min || 1;
  const w = 96, h = 32;
  const pts = closes.map((c, i) => `${(i / (closes.length - 1)) * w},${h - ((c - min) / span) * (h - 4) - 2}`).join(" ");
  const up = closes[closes.length - 1] >= ref;
  const by = h - ((ref - min) / span) * (h - 4) - 2;
  return (
    <svg viewBox={`0 0 ${w} ${h}`} className={cn("h-8 w-24", className)} role="img" aria-label={`Intraday trend ${up ? "up" : "down"}`}>
      <line x1="0" x2={w} y1={by} y2={by} stroke="var(--border-strong)" strokeDasharray="2 3" strokeWidth="1" />
      <polyline points={pts} fill="none" stroke={up ? "var(--up)" : "var(--down)"} strokeWidth="1.5" strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}
