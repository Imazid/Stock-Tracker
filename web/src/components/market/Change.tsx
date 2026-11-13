import { cn } from "@/lib/cn";
import { direction, percent, signedMoney } from "@/lib/format";

export function ChangeText({ change, changePct, currency, className }: { change?: number; changePct?: number; currency?: string; className?: string }) {
  const dir = direction(changePct ?? change);
  return (
    <span className={cn("tabular", dir === "up" ? "text-up" : dir === "down" ? "text-down" : "text-text-2", className)}>
      {change !== undefined && currency ? `${signedMoney(change, currency)} ` : ""}
      {changePct !== undefined ? (change !== undefined && currency ? `(${percent(changePct)})` : percent(changePct)) : change === undefined ? "—" : ""}
      <span className="sr-only">{dir === "up" ? " up" : dir === "down" ? " down" : ""}</span>
    </span>
  );
}

export function ChangePill({ changePct }: { changePct?: number }) {
  const dir = direction(changePct);
  return (
    <span className={cn("tabular inline-flex min-w-[64px] justify-end rounded-md px-1.5 py-0.5 text-xs font-medium",
      dir === "up" ? "bg-up-soft text-up" : dir === "down" ? "bg-down-soft text-down" : "bg-surface-2 text-text-2")}>
      {percent(changePct)}
    </span>
  );
}
