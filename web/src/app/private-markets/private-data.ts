import { browserSupabase } from "@/lib/supabase/client";

export type FinancialPeriod = {
  id: string; period_end_on: string; period_kind: "financial_year" | "month_snapshot";
  assurance: "audited" | "issuer_reported"; currency: string; revenue: number | null;
  annual_recurring_revenue: number | null; net_profit_loss: number | null;
  operating_cash_flow: number | null; cash_and_equivalents: number | null;
  published_on: string; source_url: string;
};

export type PrivateCompany = {
  id: string; name: string; sector: string; country: string; location: string | null;
  description: string | null; logo_url: string | null; founders: string[] | null; investors: string[] | null;
  source_url: string; verified_at: string; financials: FinancialPeriod[];
};

export type PrivateDeal = {
  id: string; provider: string; category: string; status: string; minimum: number | null;
  eligibility: string; jurisdictions: string[]; source_url: string; offer_document_url: string | null; verified_at: string;
  round: {
    id: string; stage: string; raised: number | null; target: number | null; valuation: number | null;
    valuation_method: string | null; currency: string; announced_on: string | null; closes_at: string | null;
    source_url: string; verified_at: string; traction: string | null;
    company: PrivateCompany;
    share_classes: { name: string; rights: string; source_url: string }[];
    listing: {
      exchange: string; symbol: string; quotation_status: "proposed" | "anticipated" | "listed" | "withdrawn";
      expected_offer_close_on: string | null; quotation_on: string | null; source_url: string;
    } | null;
  };
};

export type Criteria = {
  countries: string[]; investor_jurisdictions: string[]; sectors: string[]; stages: string[];
  categories: string[]; statuses: string[]; eligibility: string[]; providers: string[];
  company: string; currency: string; max_minimum: number; max_valuation: number;
  min_raise_target: number; max_raise_target: number; disclosed_traction: boolean; unsupported: string[];
};

export type Discovery = {
  deals: PrivateDeal[]; criteria: Criteria; matched_count: number; scanned_all: boolean;
};

export type SavedReport = { id: string; title: string; created_at: string };
export type SavedExcerpt = { id: string; title: string; created_at: string };
export type ResearchCapabilities = { document_provider: "openai" | "gemini" | null };
export type ResearchRun = { id: string; status: "running" | "complete" | "failed"; created_at: string; failure_message: string | null };
export type Finding = {
  title: string; analysis: string; confidence: string; evidence: { source: string; quote: string }[];
  missing: string[]; questions: string[]; bull?: string; base?: string; bear?: string;
};
export type Report = {
  id: string; question: string; created_at: string; findings: Finding[]; committee?: Finding;
  refresh_available?: boolean; previous_report_id?: string;
  sources: { id: string; title: string; url?: string }[];
  reported_facts?: { source: string; title: string; entries: { label: string; value: string }[] }[];
};
export type ResearchRefresh = {
  unavailable_sources: number; revision_tracking_available: boolean;
  documents: SavedExcerpt[]; deals: PrivateDeal[]; announcements: CompanyUpdate[]; newer_announcements: CompanyUpdate[];
  changed_deal_ids: string[]; changed_announcement_ids: string[];
  source_changes: { source_id: string; title: string; fields: { field: string; previous: string | null; current: string | null }[] }[];
};
export type PortfolioHolding = {
  id: string; name: string; asset_class: string; currency: string; units: number | null; ownership_percent: number | null;
  remaining_units: number | null; settled_amount: number | null; committed_amount: number | null;
  settled_on: string | null; settlement_source: string | null; last_disposition_on: string | null;
  disposition_revision_at: string | null; exit_source: string | null;
  commitment: { provider: string; provider_reference: string | null; connection?: { revoked_at: string | null } | null };
  marks: { id: string; value: number; valued_on: string; source: string; methodology: string; provider_event_at: string | null }[];
  calls: { id: string; amount: number; due_on: string; settled_on: string | null; source: string }[];
  cancelled_calls: { id: string; amount: number; due_on: string; cancelled_at: string; cancellation_source: string }[];
  distributions: { id: string; amount: number; received_on: string; source: string }[];
  dispositions: { id: string; sold_units: number; net_proceeds: number; disposed_cost: number | null; settled_on: string; source: string }[];
};
export type CapitalActivityItem = {
  id: string; holding_id: string; holding_name: string; provider: string; currency: string; amount: string;
  status: "upcoming" | "overdue" | "paid" | "cancelled" | "distribution" | "sale";
  due_on: string | null; occurred_on: string; source: string;
};
export type PortfolioPage = { holdings: PortfolioHolding[]; next_offset: number | null };
export type InvestorProfile = { country: string; declared_class: "unknown" | "retail" | "wholesale" };
export type ProviderVerification = {
  provider: string; jurisdiction: string; verified_class: "retail" | "wholesale";
  verified_at: string; expires_at: string; accountant_certificate_reviewed_at: string | null;
  connection: { revoked_at: string | null };
};
export type InvestorProfileResponse = {
  profile: InvestorProfile | null; eligibility: ProviderVerification[];
  link_providers?: { provider: string; jurisdiction: string }[];
  connections?: ProviderConnection[];
};
export type ProviderConnection = {
  provider: string; revoked_at: string | null; owner_disconnected_at: string | null;
};
export type Application = {
  id: string; status: string; requested_amount: number; provider_application_amount: number | null;
  currency: string; provider: string; provider_reference: string | null;
  connection?: { revoked_at: string | null } | null;
  acknowledged_at: string; provider_received_at: string | null; confirmed_at: string | null;
  cooling_off_ends_at: string | null; withdrawn_at: string | null; withdrawal_requested_at: string | null;
  withdrawal_declined_at: string | null; supplementary_notice_at: string | null;
  supplementary_withdrawal_ends_at: string | null; supplementary_document_url: string | null;
  offer: { round: { stage: string; company: { name: string } | null } | null } | null;
};
export type HandoffReview = { deal: PrivateDeal; requested_amount: string; currency: string };

export type MonitorPreferences = {
  company_ids: string[]; eligible_opportunities: boolean; digest_enabled: boolean; refreshed_at: string;
};

export type CompanyUpdate = {
  id: string; title: string; significance: string; source_url: string; source_label?: string | null;
  kind: "announcement" | "financial_disclosure" | "closed_round" | "open_round" | "interest";
  published_at: string; revised_at?: string | null; company: { name: string };
};

export type MonitorAlert = {
  id: string; kind: string; company_name: string; title: string; significance: string;
  source_url: string | null; source_label: string | null; occurred_at: string; revised_at: string | null;
};

type PrivateAction = "catalog" | "discover" | "research" | "research_status" | "research_runs" |
  "reports" | "report" | "delete_report" | "research_refresh" | "confirmed_holdings" | "capital_activity" | "valuation_history" | "manual_portfolio" | "remove_manual_portfolio" | "account_holdings" | "save_account_holding" | "remove_account_holding" | "save_account_valuation" | "remove_account_valuation" | "save_account_cash_flow" | "remove_account_cash_flow" | "applications" | "allocation" | "updates" |
  "set_account_holding_company" | "account_provider_options" | "set_account_holding_provider" |
  "profile" | "save_profile" | "issue_provider_link" | "disconnect_provider" | "handoff_check" | "handoff" |
  "handoff_review" | "handoff_resume_check" | "handoff_resume" |
  "documents" | "document" | "save_document" | "delete_document" | "research_capabilities" |
  "web_monitor_preferences" | "save_web_monitor" | "monitor_inbox" | "monitor_digests";

export class PrivateMarketsError extends Error {
  constructor(message: string, public readonly code?: string) {
    super(message);
  }
}

export async function privateMarkets<T>(
  action: PrivateAction, { owner, signal, ...body }: Record<string, unknown> & { owner?: string; signal?: AbortSignal } = {},
): Promise<T> {
  const supabase = browserSupabase();
  const session = owner && supabase ? (await supabase.auth.getSession()).data.session : null;
  if (action !== "catalog" && (!owner || session?.user.id !== owner)) throw new Error("Sign in again to continue.");
  const response = await fetch("/api/workspace-service/private-markets", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(session ? { Authorization: `Bearer ${session.access_token}` } : {}),
    },
    body: JSON.stringify({ ...body, action }),
    cache: "no-store",
    signal,
  });
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    throw new PrivateMarketsError(data?.error?.message ?? "Private Markets is temporarily unavailable.", data?.error?.code);
  }
  return data as T;
}

export const availabilityLabels = {
  open: "Open at verification", interest: "Expression of interest", closed: "Closed",
  expired: "Deadline passed", unverified: "Status unverified",
};

export function availability(deal: PrivateDeal, now: number): keyof typeof availabilityLabels {
  if (deal.status === "closed") return "closed";
  const end = deal.round.closes_at ? Date.parse(deal.round.closes_at) : null;
  if (end !== null && end <= now) return "expired";
  const fresh = [deal.verified_at, deal.round.verified_at].map(Date.parse)
    .every((date) => date <= now && now - date <= 86_400_000);
  if (!fresh || (end !== null && !(end > now))) return "unverified";
  if (deal.status === "open" && end !== null) return "open";
  if (deal.status === "interest") return "interest";
  return "unverified";
}

export function providerName(id: string) {
  switch (id) {
    case "birchal": return "Birchal";
    case "onmarket": return "OnMarket";
    case "angellist": return "AngelList";
    case "syndex": return "Syndex";
    case "issuer": return "Company announcement";
    default: return id;
  }
}

const sydneyDay = new Intl.DateTimeFormat("en-CA", { dateStyle: "short", timeZone: "Australia/Sydney" });

export function dayInSydney(timestamp: number) {
  return sydneyDay.format(timestamp);
}

const dateFormat = new Intl.DateTimeFormat("en-AU", { dateStyle: "medium", timeZone: "Australia/Sydney" });
const timeFormat = new Intl.DateTimeFormat("en-AU", { dateStyle: "medium", timeStyle: "short", timeZone: "Australia/Sydney" });
const monthFormat = new Intl.DateTimeFormat("en-AU", { year: "numeric", month: "long", timeZone: "Australia/Sydney" });
const numberFormat = new Intl.NumberFormat("en-AU", { maximumFractionDigits: 4 });

export function dateLabel(value: string | null | undefined, style: "day" | "time" | "month" = "day") {
  if (!value) return "Undisclosed";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Undisclosed";
  return (style === "time" ? timeFormat : style === "month" ? monthFormat : dateFormat).format(date);
}

export function amount(value: number | null, currency: string) {
  return value == null ? "Undisclosed" : `${currency} ${numberFormat.format(value)}`;
}

// The ledger returns decimal text so display preserves provider precision.
export function groupedDecimal(value: string) {
  const [whole, fraction] = value.split(".");
  return whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",") + (fraction ? "." + fraction : "");
}

const countryNames = new Intl.DisplayNames(["en-AU"], { type: "region" });

export function countryName(value: string) {
  return /^[A-Z]{2}$/.test(value) ? countryNames.of(value) ?? value : value;
}

export function sourceHref(value?: string | null) {
  if (!value) return;
  try {
    const url = new URL(value);
    if (url.protocol === "https:" && !url.username && !url.password) return url.href;
  } catch {
    // A source may have been removed or may not have a public URL.
  }
}
