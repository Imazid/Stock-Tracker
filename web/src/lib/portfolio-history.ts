import type { Point } from "../workspace/lib/models.ts";
import { parse } from "../../../supabase/functions/_shared/decimal.ts";

export const historyRanges = { "1D": 1, "1W": 7, "1M": 30, "3M": 90, "1Y": 365, ALL: null } as const;
export type HistoryRange = keyof typeof historyRanges;
export type HistoryKind = "values" | "returns";
export type StatementPeriod = {
  starts_on: string;
  ends_on: string;
  opening_value_usd: string;
  closing_value_usd: string;
  deposits_usd: string;
  withdrawals_usd: string;
  investment_change_usd: string;
  twr_factor: number | null;
  twr_invested: boolean | null;
};

const dayMs = 86_400_000;

export function snapshotHistory(rows: readonly { snapshot_date: string; total_value: number }[], today: number, range: HistoryRange): Point[] {
  const days = historyRanges[range];
  const since = days === null ? -Infinity : today - days * dayMs;
  return rows.flatMap(({ snapshot_date, total_value }) => {
    const time = Date.parse(snapshot_date);
    return time >= since && time <= today && Number.isFinite(total_value) && total_value >= 0
      ? [{ time, value: total_value }] : [];
  });
}

/** Periods arrive newest first. A shared date and valuation are required to link two statements. */
export function statementHistory(rows: readonly StatementPeriod[], today: number, range: HistoryRange) {
  const days = historyRanges[range];
  const since = days === null ? -Infinity : today - days * dayMs;
  const chain: StatementPeriod[] = [];
  let previous: StatementPeriod | undefined;
  for (const period of rows) {
    if (!(Date.parse(period.ends_on) <= today)) continue;
    if (!(Date.parse(period.starts_on) >= since)) break;
    if (previous && (previous.starts_on !== period.ends_on || cents(previous.opening_value_usd) !== cents(period.closing_value_usd))) break;
    chain.push(period);
    previous = period;
  }
  if (!previous) return { investment: [], transfers: [], timeWeighted: null, periods: 0 };
  const base = { time: Date.parse(previous.starts_on), value: 0 };
  const investment: Point[] = [base];
  const transfers: Point[] = [base];
  let gain = 0n;
  let net = 0n;
  let logGrowth = 0;
  let unavailable = false;
  let depleted = false;
  let invested = false;
  for (const period of chain.reverse()) {
    const time = Date.parse(period.ends_on);
    gain += cents(period.investment_change_usd);
    net += cents(period.deposits_usd) - cents(period.withdrawals_usd);
    investment.push({ time, value: Number(gain) / 100 });
    transfers.push({ time, value: Number(net) / 100 });
    const factor = period.twr_factor;
    if (factor === null) unavailable = true;
    else if (factor === 0) depleted = true;
    else logGrowth += Math.log(factor);
    invested ||= period.twr_invested === true;
  }
  const timeWeighted = depleted ? -100 : 100 * Math.expm1(logGrowth);
  return { investment, transfers, timeWeighted: invested && !unavailable && Number.isFinite(timeWeighted) ? timeWeighted : null, periods: chain.length };
}

function cents(value: string) {
  const negative = value.startsWith("-");
  const { units, scale } = parse(negative ? value.slice(1) : value);
  return (negative ? -units : units) * 100n / 10n ** BigInt(scale);
}
