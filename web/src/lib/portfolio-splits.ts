export const SPLIT_MIN_DATE = "1900-01-01";
export const SPLIT_MAX_RATIO = 1_000_000;

export type StockSplit = {
  id: string;
  holding_id: string;
  effective_date: string;
  new_shares: number;
  old_shares: number;
  statement_reference: string;
  updated_at: string;
  portfolio_holdings: { asset_symbol: string; asset_exchange: string | null; asset_kind: string } | null;
};

export const splitFields = "id,holding_id,effective_date,new_shares,old_shares,statement_reference,updated_at,portfolio_holdings(asset_symbol,asset_exchange,asset_kind)";
