import type { FinancialFact } from "./research-types.ts";

const REVENUE = ["RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues", "SalesRevenueNet", "Revenue"];
const NET_INCOME = ["NetIncomeLoss", "ProfitLoss"];
const OPERATING_CASH = ["NetCashProvidedByUsedInOperatingActivities", "CashFlowsFromUsedInOperatingActivities"];
const CAPEX = ["PaymentsToAcquirePropertyPlantAndEquipment", "PurchaseOfPropertyPlantAndEquipmentClassifiedAsInvestingActivities"];
const EQUITY = ["StockholdersEquity", "Equity"];
const ASSETS = ["Assets"];
const CURRENT_ASSETS = ["AssetsCurrent", "CurrentAssets"];
const CURRENT_LIABILITIES = ["LiabilitiesCurrent", "CurrentLiabilities"];

const tag = (fact: FinancialFact) => fact.concept.split(":").at(-1)!;
const filed = (fact: FinancialFact) => fact.evidence.publishedAt ?? "";
export const dayOf = (time: number) => new Date(time).toISOString().slice(0, 10);

export function reportedOn(facts: FinancialFact[], asOf: string): FinancialFact[] {
  return facts.filter((fact) => filed(fact) && filed(fact).slice(0, 10) <= asOf && fact.end <= asOf)
    .sort((a, b) => b.end.localeCompare(a.end) || filed(b).localeCompare(filed(a)) || a.concept.localeCompare(b.concept));
}

export function latestVersions(facts: FinancialFact[]): FinancialFact[] {
  const seen = new Set<string>();
  return facts.filter((fact) => {
    const key = [fact.concept, fact.unit, fact.start, fact.end].join("|");
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function annualRevenue(facts: FinancialFact[]): FinancialFact | undefined {
  const candidates = facts.filter((fact) => fact.period === "annual" && REVENUE.includes(tag(fact)) && /^[A-Z]{3}$/.test(fact.unit));
  const end = candidates[0]?.end;
  return REVENUE.map((name) => candidates.find((fact) => fact.end === end && tag(fact) === name)).find(Boolean);
}

function matching(facts: FinancialFact[], reference: FinancialFact, concepts: string[], instant = false): FinancialFact | undefined {
  return concepts.map((name) => facts.find((f) => tag(f) === name && f.unit === reference.unit && f.end === reference.end && f.start === (instant ? undefined : reference.start))).find(Boolean);
}

export function trailingFacts(facts: FinancialFact[]): FinancialFact[] {
  const groups = new Map<string, FinancialFact[]>();
  for (const f of latestVersions(facts)) {
    if (!f.start || f.statement !== "income" && f.statement !== "cash" || f.unit.includes("/") || f.unit === "shares") continue;
    const key = `${f.concept}|${f.unit}`;
    const group = groups.get(key) ?? [];
    group.push(f);
    groups.set(key, group);
  }
  const output: FinancialFact[] = [];
  for (const group of groups.values()) {
    // Use annual plus current YTD minus comparable prior YTD. An annual period is itself TTM.
    const annual = group.find((f) => f.period === "annual");
    if (!annual) continue;
    const latest = group.find((f) => f.end > annual.end && Date.parse(f.start!) - Date.parse(annual.end) === 86_400_000);
    const prior = latest && group.find((f) => f.start === annual.start && f.end < annual.end &&
      Math.abs((Date.parse(f.end) - Date.parse(f.start!)) - (Date.parse(latest.end) - Date.parse(latest.start!))) <= 7);
    if (latest && !prior) continue;
    const end = latest?.end ?? annual.end;
    const start = prior ? dayOf(Date.parse(prior.end) + 86_400_000) : annual.start;
    const inputs = latest && prior ? [annual, latest, prior] : [annual];
    if (Math.abs((Date.parse(end) - Date.parse(start!)) / 86_400_000 - 365) > 15) continue;
    const recent = inputs.reduce((a, b) => filed(a) >= filed(b) ? a : b);
    output.push({ ...annual, start, end, period: "ttm", evidence: recent.evidence, inputs: inputs.map((f) => f.evidence),
      value: latest && prior ? annual.value + latest.value - prior.value : annual.value,
      formula: latest && prior ? "Last fiscal year + current fiscal YTD − prior fiscal YTD" : "Reported full fiscal year" });
  }
  return output.sort((a, b) => b.end.localeCompare(a.end) || a.label.localeCompare(b.label));
}

export function annualMetrics(facts: FinancialFact[]): FinancialFact[] {
  const revenue = annualRevenue(facts);
  const reference = revenue ?? facts.find((fact) => fact.period === "annual" && fact.start && NET_INCOME.includes(tag(fact)) && /^[A-Z]{3}$/.test(fact.unit));
  if (!reference) return [];
  const result: FinancialFact[] = [];
  const ratio = (label: string, numerator: FinancialFact | undefined, denominator: FinancialFact | undefined, unit = "%") => {
    if (!numerator || !denominator || denominator.value <= 0) return;
    const evidence = filed(numerator) >= filed(denominator) ? numerator.evidence : denominator.evidence;
    const value = numerator.value / denominator.value * (unit === "%" ? 100 : 1);
    if (Number.isFinite(value)) result.push({ ...reference, concept: `calculated:${label}`, label, evidence, unit, value, formula: `${numerator.label} ÷ ${denominator.label}${unit === "%" ? " × 100" : ""}`, inputs: [numerator.evidence, denominator.evidence] });
  };
  const netIncome = matching(facts, reference, NET_INCOME);
  ratio("Gross margin", matching(facts, reference, ["GrossProfit"]), revenue);
  ratio("Operating margin", matching(facts, reference, ["OperatingIncomeLoss", "OperatingIncome", "ProfitLossFromOperatingActivities"]), revenue);
  ratio("Net margin", netIncome, revenue);
  ratio("Current ratio", matching(facts, reference, CURRENT_ASSETS, true), matching(facts, reference, CURRENT_LIABILITIES, true), "×");
  ratio("Equity / assets", matching(facts, reference, EQUITY, true), matching(facts, reference, ASSETS, true));
  const comparablePrior = (metric: FinancialFact | undefined) => metric && facts.find((row) => {
    const separation = (Date.parse(metric.end) - Date.parse(row.end)) / 86_400_000;
    return row.period === "annual" && row.concept === metric.concept && row.unit === metric.unit && separation >= 350 && separation <= 380;
  });
  const yearOverYear = (label: string, metric: FinancialFact | undefined) => {
    const prior = comparablePrior(metric);
    if (!metric || !prior || prior.value <= 0) return;
    result.push({ ...metric, label, concept: `calculated:${label}`, unit: "%", value: (metric.value / prior.value - 1) * 100,
      evidence: filed(metric) >= filed(prior) ? metric.evidence : prior.evidence,
      formula: "(Current fiscal year ÷ prior fiscal year − 1) × 100", inputs: [metric.evidence, prior.evidence] });
  };
  yearOverYear("Revenue growth (annual)", revenue);
  yearOverYear("Net income growth (annual)", netIncome);
  const cash = matching(facts, reference, OPERATING_CASH);
  const capex = matching(facts, reference, CAPEX);
  // SEC payment concepts use positive outflows. Avoid applying this formula to signed vendor CapEx.
  if (cash && capex && capex.value >= 0) {
    const fcf = { ...cash, concept: "calculated:freeCashFlow", label: "Free cash flow", value: cash.value - capex.value,
      formula: `${cash.label} − ${capex.label}`, evidence: filed(cash) >= filed(capex) ? cash.evidence : capex.evidence, inputs: [cash.evidence, capex.evidence] };
    result.push(fcf);
    ratio("Free cash flow margin", fcf, revenue);
  }
  return result;
}

export interface DcfAssumptions { cashFlow: number; growth: number; discount: number; terminal: number; netDebt: number; shares: number }
export function dcf(input: DcfAssumptions): number | undefined {
  const { cashFlow, growth, discount, terminal, netDebt, shares } = input;
  if (!Object.values(input).every(Number.isFinite) || cashFlow <= 0 || shares <= 0 || growth <= -1 || terminal <= -1 || discount <= 0 || discount <= terminal) return undefined;
  let present = 0;
  let cash = cashFlow;
  for (let year = 1; year <= 5; year++) {
    cash *= 1 + growth;
    present += cash / (1 + discount) ** year;
  }
  const equity = present + cash * (1 + terminal) / (discount - terminal) / (1 + discount) ** 5 - netDebt;
  return Number.isFinite(equity) ? equity / shares : undefined;
}
