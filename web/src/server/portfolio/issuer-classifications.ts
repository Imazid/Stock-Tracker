import type { IssuerClassification, IssuerClassificationResponse } from "../../lib/issuer-classification.ts";
import { findSecListing, secConfigured, secDirectory, secSubmissions } from "../research/sec.ts";
import bundledFilings from "../../../../Stock Tracker/IssuerFilings.json" with { type: "json" };

// Xcode also includes this dated SEC filing catalog as a bundle resource.
const issuerFilings: Readonly<Record<string, IssuerClassification>> = bundledFilings;

export function bundledIssuerFiling(id: string): IssuerClassification | undefined {
  return Object.hasOwn(issuerFilings, id) ? issuerFilings[id] : undefined;
}

// The US SIC divisions are based on the OSHA SIC Manual. Special-purpose investment
// vehicles have no operating sector. Preserve that distinction for exposure weights.
const sicDivisions = [
  [1, 9, "Agriculture, forestry and fishing"],
  [10, 14, "Mining and extraction"],
  [15, 17, "Construction"],
  [20, 39, "Manufacturing"],
  [40, 49, "Transport, communications and utilities"],
  [50, 51, "Wholesale trade"],
  [52, 59, "Retail trade"],
  [60, 67, "Finance, insurance and real estate"],
  [70, 89, "Services"],
] as const;
const nonOperating = new Set(["6722", "6726", "6770", "6781", "6799"]);

// SEC incorporation codes differ from ISO country codes.
const usStates = new Set("AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY X1".split(" "));
const canada = new Set("A0 A1 A2 A3 A4 A5 A6 A7 A8 A9 B0 Z4".split(" "));
const countries = new Map(Object.entries({
  C3: "Australia", C9: "Belgium", D0: "Bermuda", D5: "Brazil", E9: "Cayman Islands", F4: "China", F5: "Taiwan",
  I0: "France", "2M": "Germany", K3: "Hong Kong", K7: "India", L2: "Ireland", L3: "Israel", L6: "Italy",
  M0: "Japan", M5: "South Korea", N4: "Luxembourg", P7: "Netherlands", Q2: "New Zealand",
  G7: "Denmark", H9: "Finland", O5: "Mexico", Q8: "Norway", T3: "South Africa", U0: "Singapore",
  U3: "Spain", V7: "Sweden", V8: "Switzerland", X0: "United Kingdom",
}));

export function operatingSector(sic: string | undefined) {
  if (!sic || !/^\d{3,4}$/.test(sic)) return undefined;
  const normalized = sic.padStart(4, "0");
  if (nonOperating.has(normalized)) return undefined;
  const major = Number(normalized.slice(0, 2));
  return sicDivisions.find(([from, to]) => major >= from && major <= to)?.[2];
}

export function incorporationCountry(code: string | undefined) {
  if (!code) return undefined;
  if (usStates.has(code)) return "United States";
  if (canada.has(code)) return "Canada";
  return countries.get(code);
}

export async function issuerClassifications(ids: readonly string[], deps = {
  configured: secConfigured, directory: secDirectory, submissions: secSubmissions,
}): Promise<IssuerClassificationResponse> {
  const issuers: Record<string, IssuerClassification> = {};
  const missing: string[] = [];
  for (const id of new Set(ids)) {
    const bundled = bundledIssuerFiling(id);
    if (bundled) issuers[id] = bundled;
    else if (id.startsWith("us:")) missing.push(id);
  }

  // Preserve the bundled classifications through an upstream failure. The shared
  // SEC client applies its existing request spacing and backoff.
  if (!missing.length || !deps.configured()) return { issuers, limited: false };
  let limited = false;
  try {
    const listings = await deps.directory();
    let cursor = 0;
    await Promise.all(Array.from({ length: Math.min(missing.length, 4) }, async () => {
      while (cursor < missing.length) {
        const id = missing[cursor++];
        const listing = findSecListing(listings, id.slice(3));
        if (!listing) continue;
        try {
          const { profile, entityType } = await deps.submissions(listing);
          if (entityType === "investmentcompany" || nonOperating.has(profile.sic?.padStart(4, "0") ?? "")) continue;
          const sector = operatingSector(profile.sic);
          const country = incorporationCountry(profile.incorporationCode);
          if (sector || country) {
            issuers[id] = { issuer: profile.name, sic: profile.sic, sector, country, industry: profile.industry, evidence: profile.evidence };
          }
        } catch {
          limited = true;
        }
      }
    }));
  } catch {
    limited = true;
  }
  return { issuers, limited };
}
