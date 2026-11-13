export const RESEARCH_SECTIONS = ["overview", "financials", "valuation", "earnings", "ownership", "events", "options", "peers"] as const;
export type ResearchSection = typeof RESEARCH_SECTIONS[number];
export type CoverageStatus = "available" | "partial" | "historical" | "delayed" | "unavailable" | "restricted" | "not_applicable";

export interface Evidence {
  provider: string;
  url: string;
  retrievedAt: string;
  license: "public_filing" | "licensed";
  publishedAt?: string;
}

export interface ResearchProfile {
  name: string;
  exchange?: string;
  cik?: string;
  isin?: string;
  cusip?: string;
  kind?: string;
  industry?: string;
  sector?: string;
  headquarters?: string;
  incorporation?: string;
  description?: string;
  website?: string;
  logo?: string;
  ceo?: string;
  employees?: number;
  ipoDate?: string;
  evidence: Evidence;
}

export type Statement = "income" | "balance" | "cash" | "other";
export interface FinancialFact {
  concept: string;
  label: string;
  statement: Statement;
  value: number;
  unit: string;
  start?: string;
  end: string;
  period: "annual" | "quarter" | "ttm" | "other";
  evidence: Evidence;
  inputs?: Evidence[];
  formula?: string;
}

export interface ResearchEvent {
  id: string;
  title: string;
  category: string;
  date: string;
  reportDate?: string;
  publisher?: string;
  evidence: Evidence;
}

export interface ResearchRecord {
  id: string;
  label: string;
  date?: string;
  values: Record<string, string | number>;
  evidence: Evidence;
}

export interface DatasetCoverage {
  dataset: string;
  status: CoverageStatus;
  detail: string;
  refreshedAt?: string;
}

export interface ResearchResponse {
  instrumentId: string;
  asOf: string;
  coverage: DatasetCoverage[];
  profile?: ResearchProfile;
  facts?: FinancialFact[];
  events?: ResearchEvent[];
  records?: ResearchRecord[];
  links?: { label: string; url: string }[];
  total?: number;
  archiveCount?: number;
  next?: string;
  exportAllowed?: boolean;
}

export interface FilingPassages {
  passages: { location: number; text: string }[];
  evidence: Evidence;
  form: string;
}

export interface CompanyReport {
  instrumentId: string;
  asOf: string;
  profile?: ResearchProfile;
  facts: FinancialFact[];
  events: ResearchEvent[];
  ownership: ResearchEvent[];
  earnings: ResearchRecord[];
  peers: ResearchRecord[];
  multiples: ResearchRecord[];
  quote?: import("./market-types").QuoteView;
  history?: { first: string; last: string; changePct: number; source: string; adjustment: string; currency: string };
  links?: ResearchResponse["links"];
  coverage: DatasetCoverage[];
}
