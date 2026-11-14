import type { serviceClient } from "../_shared/secure/edge.ts";
import { exportOffset, exportSection, privateExportSections, privateExportPage } from "../_shared/private-markets/export.ts";
import { open, parseKeyring, type SealedSecret } from "../_shared/secure/envelope.ts";

type TableSection = { label: string; table: string; fields: string; order?: string; owner?: string };

// JSON fields containing credentials are omitted. Extract known members from
// client-writable nested records so an unexpected field is not exported.
const sections = {
  watchlists: { label: "Watchlists", table: "watchlist_assets",
    fields: "id,symbol,name,kind,exchange,sort_position::text,saved_at,updated_at,deleted_at" },
  watchlist_groups: { label: "Watchlist names", table: "watchlist_groups",
    fields: "id,name,created_at,deleted_at" },
  watchlist_group_assets: { label: "Named watchlist members", table: "watchlist_group_assets",
    fields: "id,group_id,listing_id,symbol,name,kind,exchange,added_at,sort_position::text",
    order: "group_id,listing_id" },
  portfolio_groups: { label: "Portfolio names", table: "portfolio_groups",
    fields: "id,name,emoji,created_at,deleted_at" },
  listed_holdings: { label: "Listed and crypto holdings", table: "portfolio_holdings",
    fields: "id,portfolio_group_id,asset_symbol,asset_name,asset_kind,asset_exchange,shares,avg_cost,date_added,updated_at,deleted_at,closed_at,broker_account_id:broker_account->>account_id,broker_account_label:broker_account->>label,broker_institution:broker_account->>institution,broker_observed_at:broker_account->>observed_at,broker_tracking:broker_account->>tracking" },
  listed_transactions: { label: "Listed and crypto transactions", table: "transactions",
    fields: "id,holding_id,transaction_date,shares,price_per_share,type,fees,avg_cost_at_sale,updated_at,deleted_at,trade_provenance" },
  price_alerts: { label: "Price alerts", table: "price_alerts",
    fields: "id,symbol,asset_name,target_price,condition,is_active,repeats,is_armed,last_triggered_at,asset_kind,asset_exchange,created_at,updated_at,deleted_at" },
  portfolio_snapshots: { label: "Main portfolio snapshots", table: "portfolio_snapshots",
    fields: "id,snapshot_date,total_value,observed_at,updated_at" },
  portfolio_group_snapshots: { label: "Named portfolio snapshots", table: "portfolio_group_snapshots",
    fields: "portfolio_group_id,snapshot_date,total_value,observed_at", order: "portfolio_group_id,snapshot_date" },
  performance_periods: { label: "Portfolio performance inputs", table: "portfolio_performance_periods",
    fields: "id,starts_on,ends_on,opening_value_usd::text,closing_value_usd::text,external_flows,transfer_values_usd,updated_at" },
  portfolio_cash_income: { label: "Portfolio cash income", table: "portfolio_cash_income",
    fields: "id,paid_on,kind,payer,account_label,currency,cash_received::text,gross_amount::text,withholding::text,franking_credit_aud::text,statement_reference,snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_currency,snaptrade_reported_amount::text,created_at,updated_at" },
  reinvestments: { label: "Dividend reinvestments", table: "portfolio_dividend_reinvestments",
    fields: "id,holding_id,paid_on,acquired_on,currency,dividend_amount::text,reinvested_amount::text,shares::text,basis_usd::text,franking_credit_aud::text,statement_reference,snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_symbol,snaptrade_reported_currency,snaptrade_reported_amount::text,snaptrade_reported_units::text,created_at,updated_at" },
  stock_splits: { label: "Stock splits", table: "portfolio_stock_splits",
    fields: "id,holding_id,effective_date,new_shares,old_shares,statement_reference,snaptrade_activity_id,snaptrade_activity_date,snaptrade_activity_label,snaptrade_activity_symbol,created_at,updated_at" },
  stock_transfers: { label: "Stock transfers", table: "portfolio_stock_transfers",
    fields: "id,from_holding_id,to_holding_id,sent_on,received_on,shares::text,same_day_order,from_account,to_account,statement_reference,receiving_snapshot_id,snaptrade_reference,updated_at" },
  referral_codes: { label: "Referral codes", table: "referral_codes", fields: "id,code,is_active,created_at,updated_at" },
  referral_activity: { label: "Referrals made", table: "referrals", owner: "referrer_id",
    fields: "id,status,created_at,updated_at,expires_at" },
  referral_signup: { label: "Referral used for this account", table: "referrals", owner: "referee_id",
    fields: "id,status,signed_up_at,portfolio_created_at,first_holding_at,expires_at,created_at,updated_at" },
  broker_connections: { label: "Broker connections", table: "broker_connections",
    fields: "id,adapter_id,name,environment,permissions,status,sync_state,last_synced_at,revoked_at,created_at,updated_at" },
  sync_connections: { label: "Broker sync connection history", table: "secure_credentials",
    fields: "id,purpose,provider,created_at,updated_at,revoked_at" },
  broker_orders: { label: "Broker orders", table: "broker_orders",
    fields: "id,connection_id,intent_id,provider_order_id,client_order_id,symbol,side,order_type,status,provider_status,quantity::text,notional::text,filled_quantity::text,average_fill_price::text,limit_price::text,stop_price::text,submitted_at,provider_updated_at,updated_at" },
  broker_fills: { label: "Broker fills", table: "broker_fills",
    fields: "id,connection_id,provider_fill_id,provider_order_id,symbol,side,quantity::text,price::text,fee::text,fee_currency,executed_at,ingested_at" },
  broker_balances: { label: "Broker balance history", table: "broker_balance_snapshots",
    fields: "id::text,connection_id,currency,total::text,available::text,reserved::text,observed_at" },
  broker_positions: { label: "Broker position history", table: "broker_position_snapshots",
    fields: "id::text,connection_id,symbol,asset_class,quantity::text,average_entry_price::text,cost_basis::text,market_value::text,currency,observed_at" },
  order_intents: { label: "Order requests", table: "order_intents",
    fields: "id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,quantity::text,notional::text,limit_price::text,stop_price::text,origin_kind,agent_id,rationale,client_order_id,status,estimate,risk,provider_order_id,created_at,expires_at,updated_at" },
  order_history: { label: "Order request status history", table: "order_intent_transitions",
    fields: "id::text,intent_id,from_status,to_status,note,at" },
  order_approvals: { label: "Order approvals", table: "order_approvals", owner: "approver_id", order: "intent_id",
    fields: "intent_id,approved_at,expires_at,consumed_at" },
  broker_risk: { label: "Broker risk settings", table: "provider_risk_policies", order: "connection_id",
    fields: "connection_id,version,limits,account_limits,updated_at" },
  trading_risk: { label: "Trading risk settings", table: "risk_policies", order: "user_id",
    fields: "kill_switch_engaged,kill_switch_at,max_symbol_exposure_pct,max_total_daily_notional,live_manual_orders_enabled,live_approval_agents_enabled,live_autonomous_agents_enabled,created_at,updated_at" },
  trading_accounts: { label: "Trading accounts", table: "trading_accounts",
    fields: "id,name,kind,mode,currency,agent_id,starting_cash,cash,realized_pnl,fees_paid,peak_equity,day_key,day_start_equity,realized_today,notional_today,created_at,marked_at,updated_at,deleted_at" },
  trading_positions: { label: "Trading positions", table: "positions",
    fields: "id,ledger_id,instrument_id,instrument,quantity,cost_basis,opened_at,last_price,last_price_time,updated_at" },
  trading_snapshots: { label: "Trading account history", table: "trading_portfolio_snapshots",
    fields: "id,ledger_id,time,equity,cash" },
  trading_orders: { label: "Trading orders", table: "orders",
    fields: "id,client_order_id,ledger_id,instrument_id,instrument,side,type,quantity,limit_price,stop_price,time_in_force,source_kind,agent_id,proposal_id,mode,status,filled_quantity,average_fill_price,fees,reference_price,created_at,updated_at,expires_at,stop_triggered_at,status_note,signal_bar_time,broker_order_id" },
  trading_fills: { label: "Trading fills", table: "order_fills",
    fields: "id,order_id,fill_no,ledger_id,instrument_id,instrument,side,quantity,price,fee,time,source_kind,agent_id,proposal_id,mode,realized_pnl,signal_bar_time,created_at" },
  trading_agents: { label: "Trading agents", table: "trading_agents",
    fields: "id,name,template_id,mode,status,pause_reason,risk_policy,ledger_id,budget,review_each_paper_trade,schedule_interval_minutes,strategy_version,created_at,last_run_at,next_run_at,updated_at,deleted_at" },
  strategies: { label: "Saved strategy versions", table: "agent_strategy_versions", fields: "id,agent_id,version,spec,note,author,created_at" },
  trade_proposals: { label: "Trade proposals", table: "trade_proposals",
    fields: "id,agent_id,signal_id,strategy_version,ledger_id,instrument_id,instrument,side,quantity,reference_price,notional,estimated_fee,mode,status,risk,headline,sizing_note,signal_bar_time,created_at,expires_at,resolved_at,resolution_note,order_id,client_order_id" },
  signals: { label: "Agent signals", table: "trading_signals",
    fields: "id,agent_id,strategy_version,instrument_id,instrument,action,headline,evidence,bar_time,close,rule_margin,exit_reason,provenance,created_at" },
  agent_runs: { label: "Agent runs", table: "agent_runs",
    fields: "id,agent_id,strategy_version,trigger,started_at,finished_at,status,summary,steps,signal_ids,proposal_ids,order_ids,created_at" },
  agent_events: { label: "Agent activity", table: "agent_events",
    fields: "id,kind,title,body,mode,agent_id,order_id,proposal_id,instrument_id,created_at" },
  trading_audit: { label: "Trading audit history", table: "audit_events",
    fields: "id,time,actor,kind,summary,mode,agent_id,ledger_id,order_id,proposal_id,instrument_id" },
  investment_audit: { label: "Private Markets audit history", table: "investment_audit_logs",
    fields: "id::text,action,subject_id,created_at,provider_event_at,source" },
  ai_usage: { label: "AI request history", table: "ai_usage_daily", fields: "usage_date,request_count", order: "usage_date" },
  market_data_usage: { label: "Market data request history", table: "market_data_usage",
    fields: "window_start,request_count", order: "window_start" },
} satisfies Record<string, TableSection>;

export const accountSections = [
  { id: "account", label: "Account identity" },
  ...Object.entries(sections).map(([id, { label }]) => ({ id, label })),
  ...Object.entries(privateExportSections).map(([id, label]) => ({ id: "private_" + id, label })),
];

export function parseAccountPage(section: unknown, offset: unknown) {
  const start = exportOffset(offset);
  const entry = accountSections.find(({ id }) => id === section);
  if (!entry || start === null || start > 1_000_000_000 || (entry.id === "account" && start !== 0)) return null;
  return { id: entry.id, start };
}

export async function accountRecords(
  admin: ReturnType<typeof serviceClient>, owner: string, section: string, offset: number,
) {
  const privateSection = section.startsWith("private_") && exportSection(section.slice("private_".length));
  if (privateSection) {
    let keys: ReturnType<typeof parseKeyring> | undefined;
    return await privateExportPage(admin, owner, privateSection, offset,
      async (kind, id, sealed: SealedSecret) => {
        keys ??= parseKeyring(Deno.env.get("CREDENTIAL_KEKS"), Deno.env.get("CREDENTIAL_ACTIVE_KEK"));
        const decoded = await open(await keys, sealed, `private_${kind}:${owner}:${id}`);
        if (kind === "document") return decoded;
        const { source_refs, ...report } = JSON.parse(decoded);
        return { ...report, refresh_available: source_refs !== undefined };
      });
  }
  const spec: TableSection = sections[section as keyof typeof sections];
  const size = 50;
  let query = admin.from(spec.table).select(spec.fields).eq(spec.owner ?? "user_id", owner);
  for (const column of (spec.order ?? "id").split(",")) query = query.order(column);
  const { data, error } = await query.range(offset, offset + size).returns<Record<string, unknown>[]>();
  if (error) throw error;
  return { records: data.slice(0, size), next_offset: data.length > size ? offset + size : null };
}
