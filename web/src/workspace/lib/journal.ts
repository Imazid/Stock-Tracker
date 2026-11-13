import { backend } from "./backend";
import type { Alert, Holding, Journal, Transaction, Watch } from "./models";

export async function readJournal(userID: string): Promise<Journal> {
  if (!backend) throw new Error("Backend unavailable.");
  // Paginate for histories that grow beyond the Data API response cap.
  async function all<T>(page: (from: number, to: number) => PromiseLike<{ data: unknown; error: unknown }>) {
    const rows: T[] = [];
    for (let offset = 0; ; offset += 500) {
      const result = await page(offset, offset + 499);
      if (result.error) throw result.error;
      const batch = result.data as T[];
      rows.push(...batch);
      if (batch.length < 500) return rows;
    }
  }
  const client = backend;
  const [holdings, watch, alerts, snapshots, transactions] = await Promise.all([
    all<Holding>((a,b) => client.from("portfolio_holdings").select("id,asset_symbol,asset_name,asset_kind,asset_exchange,shares,avg_cost").eq("user_id", userID).is("deleted_at", null).order("date_added").order("id").range(a,b)),
    all<Watch>((a,b) => client.from("watchlist_assets").select("id,symbol,name,kind,exchange").eq("user_id", userID).is("deleted_at", null).order("name").order("id").range(a,b)),
    all<Alert>((a,b) => client.from("price_alerts").select("id,symbol,target_price,condition,is_active,repeats").eq("user_id", userID).is("deleted_at", null).order("created_at", {ascending:false}).order("id").range(a,b)),
    all<{snapshot_date: string; total_value: number}>((a,b) => client.from("portfolio_snapshots").select("snapshot_date,total_value").eq("user_id", userID).order("snapshot_date").range(a,b)),
    all<Transaction>((a,b) => client.from("transactions").select("id,holding_id,transaction_date,type,shares,price_per_share").eq("user_id", userID).is("deleted_at", null).order("transaction_date", {ascending:false}).order("id").range(a,b)),
  ]);
  return { holdings, watch, alerts, transactions, snapshots: snapshots.map(row => ({ time: Date.parse(row.snapshot_date), value: row.total_value })) };
}
