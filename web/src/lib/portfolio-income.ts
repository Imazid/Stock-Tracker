export const incomeKinds = {
  dividend: "Dividend",
  distribution: "Distribution",
  substitute_dividend: "Payment in lieu of dividend",
} as const;

export type IncomeKind = keyof typeof incomeKinds;

export const incomeNotice = "Preliminary cash records for review. Check the payment details, withholding, franking credits and tax treatment against your statements. This report does not calculate tax.";

export const cashAmount = /^(?:0|[1-9]\d{0,11})(?:\.\d{1,8})?$/;

export function amountUnits(value: string): bigint {
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole + fraction.padEnd(8, "0"));
}

export function incomeMoney(value: string, currency: string) {
  const [whole, fraction = ""] = value.split(".");
  const decimals = fraction.replace(/0+$/, "").padEnd(2, "0");
  return `${currency} ${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${decimals}`;
}

export type IncomeActivity = {
  id: string;
  date: string;
  kind: IncomeKind;
  symbol: string | null;
  currency: string;
  amount: string;
  account: string;
};

export type IncomeRow = {
  id: string;
  paid_on: string;
  kind: IncomeKind;
  payer: string;
  account_label: string;
  currency: string;
  cash_received: string;
  gross_amount: string | null;
  withholding: string | null;
  franking_credit_aud: string | null;
  statement_reference: string;
  snaptrade_activity_id: string | null;
  snaptrade_reported_on: string | null;
  snaptrade_reported_amount: string | null;
  snaptrade_reported_currency: string | null;
  updated_at: string;
};

export type IncomeTotal = { currency: string; cash_received: string; payments: number };

export const incomeFields = "id,paid_on,kind,payer,account_label,currency,cash_received::text,gross_amount::text,withholding::text,franking_credit_aud::text,statement_reference,snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_amount::text,snaptrade_reported_currency,updated_at";

export const incomeMinDay = "1900-01-01";

export function incomeDay(value: string | null) {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value) || value < incomeMinDay) return null;
  const time = Date.parse(value + "T00:00:00Z");
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value ? value : null;
}
