import { Badge } from "@/components/ui/Badge";

/**
 * The trading environment, always on screen. This build has no live execution: the badge
 * reads PRACTICE (amber). If live ever exists it reads LIVE in red — the two must never
 * look alike.
 */
export function EnvironmentBadge({ live = false }: { live?: boolean }) {
  if (live) {
    return <Badge tone="live" className="px-2 py-1 text-[11px] font-bold tracking-wider" title="Orders here use real money.">LIVE</Badge>;
  }
  return (
    <Badge tone="warn" className="px-2 py-1 text-[11px] font-bold tracking-wider" title="No real-money trading is enabled in this build.">
      PRACTICE
    </Badge>
  );
}
