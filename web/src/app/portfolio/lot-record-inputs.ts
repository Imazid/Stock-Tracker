import {
  receivingSnapshotFields, transferHoldingFields, type ReceivingSnapshot, type TransferHolding,
} from "@/lib/portfolio-transfers";
import { browserSupabase } from "@/lib/supabase/client";

export function db() {
  const client = browserSupabase();
  if (!client) throw new Error("Accounts are unavailable.");
  return client;
}

export function holdingLabel(holding: TransferHolding) {
  return [holding.asset_symbol, holding.asset_exchange, holding.broker_account?.label, holding.date_added.slice(0, 10),
    holding.deleted_at ? "Archived" : null, holding.id.slice(0, 8)].filter(Boolean).join(" · ");
}

export async function loadHoldings(userId: string, signal: AbortSignal) {
  const all: TransferHolding[] = [];
  while (true) {
    const query = db().from("portfolio_holdings").select(transferHoldingFields).eq("user_id", userId)
      .eq("asset_kind", "Stock").order("id").limit(500).abortSignal(signal);
    if (all.length) query.gt("id", all[all.length - 1].id);
    const { data, error } = await query.overrideTypes<TransferHolding[], { merge: false }>();
    if (error) throw error;
    all.push(...data);
    if (data.length < 500) return all.sort((a, b) => holdingLabel(a).localeCompare(holdingLabel(b)));
  }
}

export async function loadSnapshots(userId: string, holdingId: string, signal: AbortSignal) {
  const all: ReceivingSnapshot[] = [];
  while (true) {
    const query = db().from("transactions").select(receivingSnapshotFields).eq("user_id", userId).eq("holding_id", holdingId)
      .eq("type", "Buy").in("trade_provenance->>source", ["csv_position", "broker_position"])
      .is("deleted_at", null).order("id").limit(500).abortSignal(signal);
    if (all.length) query.gt("id", all[all.length - 1].id);
    const { data, error } = await query.overrideTypes<ReceivingSnapshot[], { merge: false }>();
    if (error) throw error;
    all.push(...data);
    if (data.length < 500) return all.sort((a, b) => b.transaction_date.localeCompare(a.transaction_date));
  }
}
