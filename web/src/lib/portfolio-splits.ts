export const SPLIT_MIN_DATE = "1900-01-01";
export const SPLIT_MAX_RATIO = 1_000_000;

export type SplitActivityLabel = "Stock split" | "Reverse stock split";
export type SplitActivity = { id: string; date: string; label: SplitActivityLabel; symbol: string | null };

type SplitActivityReference = {
  snaptrade_activity_id: string | null;
  snaptrade_activity_date: string | null;
  snaptrade_activity_label: SplitActivityLabel | null;
  snaptrade_activity_symbol: string | null;
};

export type FractionalShareCash = {
  id: string;
  holding_id: string;
  effective_date: string;
  statement_reference: string;
  fraction_shares: string;
  fraction_paid_on: string;
  fraction_currency: string;
  fraction_proceeds: string;
  fraction_fees: string;
  fraction_net_usd: string | null;
};

export type StockSplit = SplitActivityReference & Partial<{
  [Key in Exclude<keyof FractionalShareCash, "id" | "holding_id" | "effective_date" | "statement_reference">]:
    FractionalShareCash[Key] | null;
}> & {
  id: string;
  holding_id: string;
  effective_date: string;
  new_shares: number;
  old_shares: number;
  statement_reference: string;
  updated_at: string;
  portfolio_holdings: { asset_symbol: string; asset_exchange: string | null; asset_kind: string } | null;
};

export function fractionalShareCash(split: StockSplit): FractionalShareCash | undefined {
  const { id, holding_id, effective_date, statement_reference, fraction_shares, fraction_paid_on, fraction_currency,
    fraction_proceeds, fraction_fees, fraction_net_usd } = split;
  if (!fraction_shares || !fraction_paid_on || !fraction_currency || !fraction_proceeds || !fraction_fees) return;
  return { id, holding_id, effective_date, statement_reference, fraction_shares, fraction_paid_on, fraction_currency,
    fraction_proceeds, fraction_fees, fraction_net_usd: fraction_net_usd ?? null };
}

export const splitFields = "id,holding_id,effective_date,new_shares,old_shares,statement_reference,updated_at,snaptrade_activity_id,snaptrade_activity_date,snaptrade_activity_label,snaptrade_activity_symbol,fraction_shares,fraction_paid_on,fraction_currency,fraction_proceeds,fraction_fees,fraction_net_usd,portfolio_holdings(asset_symbol,asset_exchange,asset_kind)";
