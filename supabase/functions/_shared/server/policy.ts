// When a change to an agent's limits counts as loosening them. Tightening is always
// allowed; loosening needs the stronger sign-in (see `requireStepUp` in auth.ts).

import type { RiskPolicy } from "../trading/risk.ts";

const HIGHER_IS_LOOSER: (keyof RiskPolicy)[] = ["maxOrderNotional", "maxPositionPct", "maxDailyNotional", "maxDailyLossPct",
  "maxDrawdownPct", "maxOpenPositions", "maxSpreadBps", "maxQuoteAgeSeconds", "maxDailyVolatilityPct", "maxPriceGapPct"];

/** Whether `next` lets an agent do more than `current` did. */
export function isLoosening(current: RiskPolicy, next: RiskPolicy): boolean {
  if (HIGHER_IS_LOOSER.some((key) => (next[key] as number) > (current[key] as number))) return true;
  if (next.minAverageDollarVolume < current.minAverageDollarVolume) return true;
  if (next.cooldownSeconds < current.cooldownSeconds) return true;
  return next.allowQueueOutsideHours && !current.allowQueueOutsideHours;
}
