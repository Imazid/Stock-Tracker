import { Badge } from "@/components/ui/Badge";
import { ago, dateTime } from "@/lib/format";
import type { DataStatus, MarketStateView } from "@/lib/market-types";

const STATUS: Record<DataStatus, { label: string; tone: "up" | "warn" | "neutral" }> = {
  real_time: { label: "Real-time", tone: "up" },
  delayed: { label: "Delayed", tone: "warn" },
  indicative: { label: "Indicative", tone: "neutral" },
};

export function StatusChip({ status, delayMinutes }: { status: DataStatus; delayMinutes?: number }) {
  const s = STATUS[status];
  const label = status === "delayed" && delayMinutes ? `Delayed ${delayMinutes} min` : s.label;
  const title = status === "indicative"
    ? "An aggregate or unofficial price — not one any single venue would fill at."
    : status === "delayed" ? "Prices lag the exchange." : "As reported by the source, without a stated delay.";
  return <Badge tone={s.tone} title={title}>{label}</Badge>;
}

export function MarketChip({ market }: { market: MarketStateView }) {
  return <Badge tone={market.isOpen ? "up" : "neutral"} title={market.calendarCovered ? undefined : "Holiday calendar not loaded for this market: hours assume a normal day."}>
    <span aria-hidden className={`h-1.5 w-1.5 rounded-full ${market.isOpen ? "bg-up" : "bg-text-3"}`} />{market.label}
  </Badge>;
}

export function SourceLine({ source, currency, observedAt, stale, staleReason }: { source: string; currency: string; observedAt?: string; stale?: boolean; staleReason?: string }) {
  return (
    <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-text-3">
      <span>{source}</span><span aria-hidden>·</span><span>{currency}</span>
      {observedAt ? (<><span aria-hidden>·</span><time dateTime={observedAt} title={dateTime(observedAt)}>as of {ago(observedAt)}</time></>) : null}
      {stale ? <Badge tone="warn" title={staleReason}>Stale</Badge> : null}
    </p>
  );
}
