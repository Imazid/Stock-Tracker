import type { ExposureCurrency, PortfolioReferenceRates, portfolioExposure } from "./portfolio-exposure.ts";

export type PrivateAllocationBucket = {
  asset_class: string;
  currency: string;
  position_count: number;
  valued_count: number;
  stale_count: number;
  carrying_value: string | null;
  oldest_valuation: string | null;
};

type Row = { id: string; label: string; value: number; privateAsset?: boolean };

export function unifiedAllocation(
  listed: Pick<ReturnType<typeof portfolioExposure>, "assets" | "total" | "fxDates">,
  buckets: readonly PrivateAllocationBucket[],
  currency: ExposureCurrency,
  rates: PortfolioReferenceRates | undefined,
) {
  const rows = new Map<string, Row>();
  for (const { id, label, value } of listed.assets) rows.set(id, { id, label, value });
  const fxDates = new Set(listed.fxDates);
  let total = listed.total;
  let positions = 0;
  let valued = 0;
  let stale = 0;
  let missingRates = 0;
  let missingMarks = 0;
  let oldestValuation: string | undefined;
  for (const bucket of buckets) {
    positions += bucket.position_count;
    missingMarks += bucket.position_count - bucket.valued_count;
    if (bucket.valued_count === 0 || bucket.carrying_value === null) continue;
    const fx = bucket.currency === currency ? undefined : rates?.[currency]?.[bucket.currency];
    const value = Number(bucket.carrying_value);
    const rate = bucket.currency === currency ? 1 : Number(fx?.rate);
    if (value !== 0 && (!Number.isFinite(rate) || rate <= 0)) {
      missingRates += bucket.valued_count;
      continue;
    }
    const converted = value === 0 ? 0 : value * rate;
    if (!Number.isFinite(converted) || converted < 0 || !Number.isFinite(total + converted)) continue;
    const label = bucket.asset_class.trim() || "Other alternative";
    const id = `private:${label}`;
    rows.set(id, { id, label, value: (rows.get(id)?.value ?? 0) + converted, privateAsset: true });
    total += converted;
    valued += bucket.valued_count;
    stale += bucket.stale_count;
    if (fx && value !== 0) fxDates.add(fx.date);
    if (bucket.oldest_valuation && (!oldestValuation || bucket.oldest_valuation < oldestValuation)) {
      oldestValuation = bucket.oldest_valuation;
    }
  }
  return {
    rows: [...rows.values()].map((row) => ({ ...row, weight: total > 0 ? row.value / total * 100 : 0 }))
      .sort((a, b) => b.value - a.value || a.label.localeCompare(b.label)),
    total, positions, valued, stale, missingRates, missingMarks, oldestValuation, fxDates: [...fxDates].sort(),
  };
}
