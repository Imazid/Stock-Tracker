export const COMPANY_ALERT_KINDS = ["price_above", "price_below", "volume_above", "filing", "insider", "news"] as const;
export type CompanyAlertKind = typeof COMPANY_ALERT_KINDS[number];

export interface CompanyAlert {
  id: string;
  kind: CompanyAlertKind;
  threshold: number | null;
  currency: string | null;
  created_at: string;
  last_checked_at: string | null;
  last_problem: string | null;
}

export interface CompanyAlertEvent {
  id: number;
  title: string;
  url: string | null;
  occurred_at: string;
}
