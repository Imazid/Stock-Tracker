import type { serverSupabase } from "@/lib/supabase/server";
import { stockTransferFields, type StockTransfer } from "../../lib/portfolio-transfers.ts";
import { splitFields, type StockSplit } from "../../lib/portfolio-splits.ts";
import { reinvestmentAcquisition, reinvestmentPages } from "./reinvestments.ts";
import { transactionPages, type TransactionRow } from "./transactions.ts";

export async function readLotLedger(
  db: NonNullable<Awaited<ReturnType<typeof serverSupabase>>>, userId: string, signal: AbortSignal,
  end?: string, beforeTime?: string,
) {
  const transactions: TransactionRow[] = [];
  const acquisitions: TransactionRow[] = [];
  const splits: StockSplit[] = [];
  const transfers: StockTransfer[] = [];
  // Sydney midnight is earlier than UTC midnight. The query uses a broad UTC
  // cutoff and the calculation applies the exact Sydney day.
  const before = beforeTime ?? (end ? new Date(Date.parse(end + "T00:00:00Z") + 86_400_000).toISOString() : undefined);
  await Promise.all([
    (async () => {
      for await (const page of transactionPages(db, userId, signal, before)) transactions.push(...page);
    })(),
    (async () => {
      for await (const page of reinvestmentPages(db, userId, signal, { field: "acquired_on", through: end })) {
        for (const entry of page) acquisitions.push(reinvestmentAcquisition(entry));
      }
    })(),
    (async () => {
      const pageSize = 500;
      let lastId: string | undefined;
      do {
        let query = db.from("portfolio_stock_splits").select(splitFields).eq("user_id", userId)
          .order("id").limit(pageSize).abortSignal(signal);
        if (end) query = query.lte("effective_date", end);
        if (lastId) query = query.gt("id", lastId);
        const { data, error } = await query.overrideTypes<StockSplit[], { merge: false }>();
        if (error) throw error;
        splits.push(...data);
        lastId = data.length === pageSize ? data[data.length - 1].id : undefined;
      } while (lastId);
    })(),
    (async () => {
      const pageSize = 500;
      let lastId: string | undefined;
      do {
        let query = db.from("portfolio_stock_transfers").select(stockTransferFields).eq("user_id", userId)
          .order("id").limit(pageSize).abortSignal(signal);
        if (end) query = query.lte("sent_on", end);
        if (lastId) query = query.gt("id", lastId);
        const { data, error } = await query.overrideTypes<StockTransfer[], { merge: false }>();
        if (error) throw error;
        transfers.push(...data);
        lastId = data.length === pageSize ? data[data.length - 1].id : undefined;
      } while (lastId);
    })(),
  ]);

  return { transactions: transactions.concat(acquisitions), acquisitions, splits, transfers };
}
