export const brokerReinvestmentLabel = "Dividend reinvestment";

export type BrokerReinvestment = {
  id: string;
  date: string;
  symbol: string | null;
  currency: string | null;
  amount: number | null;
  units: number | null;
};

export type Reinvestment = {
  id: string;
  holding_id: string;
  paid_on: string;
  acquired_on: string;
  currency: string;
  dividend_amount: string;
  reinvested_amount: string;
  shares: string;
  basis_usd: string | null;
  franking_credit_aud: string | null;
  statement_reference: string;
  updated_at: string;
  snaptrade_activity_id?: string | null;
  snaptrade_reported_on?: string | null;
  snaptrade_reported_symbol?: string | null;
  snaptrade_reported_currency?: string | null;
  snaptrade_reported_amount?: string | null;
  snaptrade_reported_units?: string | null;
  portfolio_holdings: { asset_symbol: string; asset_exchange: string | null; asset_kind: string; deleted_at: string | null } | null;
};

export const reinvestmentFields = "id,holding_id,paid_on,acquired_on,currency,dividend_amount::text,reinvested_amount::text,shares::text,basis_usd::text,franking_credit_aud::text,statement_reference,updated_at,snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_symbol,snaptrade_reported_currency,snaptrade_reported_amount::text,snaptrade_reported_units::text,portfolio_holdings(asset_symbol,asset_exchange,asset_kind,deleted_at)";
export const reinvestmentShares = /^(?:0|[1-9]\d{0,11})(?:\.\d{1,18})?$/;
