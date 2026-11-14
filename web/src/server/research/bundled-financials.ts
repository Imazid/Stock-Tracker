import type { Evidence, FinancialFact } from "@/lib/research-types";

// Selected annual figures transcribed from the consolidated statements. Currency
// is the issuer's reporting currency. Keep the original fiscal end and filing date.
const annual = {
  apple: {
    provider: "SEC EDGAR", url: "https://www.sec.gov/Archives/edgar/data/320193/000032019326000026/aapl-20260926.htm",
    filedOn: "2026-11-03", end: "2026-09-26",
    values: [["Revenue", "Net sales", 478_834], ["OperatingIncome", "Operating income", 133_050], ["NetIncome", "Net income", 132_175]],
  },
  bhp: {
    provider: "BHP annual report", url: "https://www.bhp.com/-/media/documents/investors/annual-reports/2026/260818_bhpannualreport2026",
    filedOn: "2026-08-18", end: "2026-06-30",
    values: [["Revenue", "Revenue", 58_760], ["OperatingIncome", "Profit from operations", 23_869], ["NetIncome", "Profit attributable to BHP shareholders", 9_833]],
  },
} as const;
const listing = new Map<string, (typeof annual)[keyof typeof annual]>([
  ["us:AAPL", annual.apple], ["asx:BHP", annual.bhp], ["us:BHP", annual.bhp],
]);

export function bundledAnnualFacts(instrumentId: string, asOf: string): FinancialFact[] {
  const report = listing.get(instrumentId);
  if (!report || report.filedOn > asOf) return [];
  const evidence: Evidence = { provider: report.provider, url: report.url, license: "public_filing",
    publishedAt: report.filedOn, retrievedAt: report.filedOn };
  return report.values.map(([concept, label, millions]) => ({
    concept, label, statement: "income", value: millions * 1_000_000, unit: "USD", end: report.end,
    period: "annual", evidence,
  }));
}
