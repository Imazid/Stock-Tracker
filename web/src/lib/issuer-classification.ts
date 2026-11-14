export const ISSUER_LOOKUP_LIMIT = 20;

export type IssuerClassification = {
  issuer: string;
  sector?: string;
  country?: string;
  sic?: string;
  industry?: string;
  evidence: { url: string; filedOn?: string; retrievedAt?: string };
};

export type IssuerClassificationResponse = {
  issuers: Record<string, IssuerClassification>;
  limited: boolean;
};
