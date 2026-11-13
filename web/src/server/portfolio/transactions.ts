import type { serverSupabase } from "@/lib/supabase/server";

export type TradeProvenance = {
  source: "manual_trade" | "opening_position" | "csv_position" | "broker_position";
  currency?: string;
  unitPrice?: number;
  fees?: number;
  usdPerUnit?: number;
  conversion?: "usd" | "app_reference" | "app_fallback";
  conversionRecordedAt?: string;
};

export type TransactionRow = {
  id: string;
  holding_id: string;
  transaction_date: string;
  type: string;
  shares: number;
  price_per_share: number;
  fees: number;
  trade_provenance?: TradeProvenance | null;
  portfolio_holdings: {
    asset_symbol: string;
    asset_exchange: string | null;
    asset_kind: string;
    deleted_at: string | null;
  } | null;
};

export function tradeSource(provenance: TradeProvenance | null | undefined) {
  switch (provenance?.source) {
    case "manual_trade": return "Manual trade";
    case "opening_position": return "Opening position";
    case "csv_position": return "CSV position snapshot";
    case "broker_position": return "Broker position snapshot";
    default: return "Unrecorded";
  }
}

export function tradeConversion(provenance: TradeProvenance | null | undefined) {
  switch (provenance?.conversion) {
    case "usd": return "USD input";
    case "app_reference": return "App reference rate";
    case "app_fallback": return "App fallback rate";
    default: return null;
  }
}

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
      .select("id,holding_id,transaction_date,type,shares,price_per_share,fees,trade_provenance,portfolio_holdings(asset_symbol,asset_exchange,asset_kind,deleted_at)")
      .eq("user_id", userId).is("deleted_at", null).order("id").limit(pageSize).abortSignal(signal);
    if (lastId) query = query.gt("id", lastId);
    if (before) query = query.lt("transaction_date", before);
    const { data, error } = await query.overrideTypes<TransactionRow[], { merge: false }>();
    if (error) throw error;
    yield data;
    lastId = data.length === pageSize ? data[data.length - 1].id : undefined;
  } while (lastId);
}
