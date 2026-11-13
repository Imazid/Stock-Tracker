import type { serverSupabase } from "@/lib/supabase/server";

export type TransactionRow = {
  id: string;
  holding_id: string;
  transaction_date: string;
  type: string;
  shares: number;
  price_per_share: number;
  fees: number;
  portfolio_holdings: {
    asset_symbol: string;
    asset_exchange: string | null;
    asset_kind: string;
    deleted_at: string | null;
  } | null;
};

export async function* transactionPages(
  db: NonNullable<Awaited<ReturnType<typeof serverSupabase>>>,
  userId: string,
  signal: AbortSignal,
  before?: string,
) {
  const pageSize = 500;
  let lastId: string | undefined;
  do {
    let query = db.from("transactions")
      .select("id,holding_id,transaction_date,type,shares,price_per_share,fees,portfolio_holdings(asset_symbol,asset_exchange,asset_kind,deleted_at)")
      .eq("user_id", userId).is("deleted_at", null).order("id").limit(pageSize).abortSignal(signal);
    if (lastId) query = query.gt("id", lastId);
    if (before) query = query.lt("transaction_date", before);
    const { data, error } = await query.overrideTypes<TransactionRow[], { merge: false }>();
    if (error) throw error;
    yield data;
    lastId = data.length === pageSize ? data[data.length - 1].id : undefined;
  } while (lastId);
}
