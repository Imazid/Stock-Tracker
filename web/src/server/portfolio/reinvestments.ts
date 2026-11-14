import type { serverSupabase } from "@/lib/supabase/server";
import { reinvestmentFields, type Reinvestment } from "../../lib/portfolio-reinvestments.ts";
import type { TransactionRow } from "./transactions.ts";

export function reinvestmentAcquisition(record: Reinvestment): TransactionRow {
  return {
    id: "reinvestment:" + record.id,
    holding_id: record.holding_id,
    // Only a Sydney calendar day is known. The lot calculator orders these
    // after timestamped trades on the same day and the CSV omits the time.
    transaction_date: record.acquired_on,
    type: "Buy",
    shares: record.shares,
    price_per_share: 0,
    fees: 0,
    portfolio_holdings: record.portfolio_holdings,
    reinvestment: record,
  };
}

export async function* reinvestmentPages(
  db: NonNullable<Awaited<ReturnType<typeof serverSupabase>>>, userId: string, signal: AbortSignal,
  range?: { field: "paid_on" | "acquired_on"; from?: string | null; through?: string | null },
) {
  const pageSize = 500;
  let lastId: string | undefined;
  do {
    let query = db.from("portfolio_dividend_reinvestments").select(reinvestmentFields).eq("user_id", userId)
      .order("id").limit(pageSize).abortSignal(signal);
    if (range?.from) query = query.gte(range.field, range.from);
    if (range?.through) query = query.lte(range.field, range.through);
    if (lastId) query = query.gt("id", lastId);
    const { data, error } = await query.overrideTypes<Reinvestment[], { merge: false }>();
    if (error) throw error;
    yield data;
    lastId = data.length === pageSize ? data[data.length - 1].id : undefined;
  } while (lastId);
}
