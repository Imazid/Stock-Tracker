import { useQuery } from "@tanstack/react-query";
import type { HistoryKind, StatementPeriod } from "@/lib/portfolio-history";
import { browserSupabase } from "@/lib/supabase/client";

type Snapshot = { snapshot_date: string; total_value: number };

async function readHistory<T>(page: (offset: number, end: number) => PromiseLike<{ data: T[] | null; error: unknown }>) {
  const rows: T[] = [];
  for (let offset = 0; ; offset += 500) {
    const result = await page(offset, offset + 499);
    if (result.error || !result.data) throw new Error("Couldn’t load portfolio history.");
    rows.push(...result.data);
    if (result.data.length < 500) return rows;
  }
}

export function usePortfolioHistory(userId: string, kind: HistoryKind) {
  return useQuery({
    queryKey: ["portfolio-history", userId, kind],
    queryFn: async ({ signal }) => {
      const db = browserSupabase();
      if (!db) throw new Error("Accounts are unavailable.");
      if (kind === "values") {
        const rows = await readHistory<Snapshot>((from, to) => db.from("portfolio_snapshots")
          .select("snapshot_date,total_value").eq("user_id", userId).order("snapshot_date").range(from, to).abortSignal(signal));
        return { kind, rows } as const;
      }
      const rows = await readHistory<StatementPeriod>((from, to) => db.from("portfolio_performance_results")
        .select("starts_on,ends_on,opening_value_usd::text,closing_value_usd::text,deposits_usd::text,withdrawals_usd::text,investment_change_usd::text,twr_factor,twr_invested")
        .eq("user_id", userId).order("ends_on", { ascending: false }).range(from, to).abortSignal(signal));
      return { kind, rows } as const;
    },
    refetchInterval: kind === "values" ? 90_000 : false,
  });
}
