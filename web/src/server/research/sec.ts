import type { Evidence, FinancialFact, ResearchEvent, ResearchProfile, Statement } from "../../lib/research-types.ts";
import { cached } from "../market/cache.ts";
import { asNumber, asObject, asText, providerJSON, safeUrl } from "./upstream.ts";

export const SEC = "SEC EDGAR";
export const SEC_DIRECTORY = "https://www.sec.gov/files/company_tickers_exchange.json";
const ACCESSION = /^\d{10}-\d{2}-\d{6}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const FORM = /^(10-K|10-Q|20-F|40-F)(\/A)?$/;
const QUARTER_FORM = /^(10-Q|6-K)(\/A)?$/;

export interface SecListing { cik: string; symbol: string; name: string; exchange: string }
export const secConfigured = () => Boolean(process.env.RESEARCH_SEC_USER_AGENT?.trim());

async function secJSON(url: string): Promise<unknown> {
  return providerJSON(new URL(url), SEC, { "User-Agent": process.env.RESEARCH_SEC_USER_AGENT!.trim() }, 200);
}

function evidence(url: string, retrievedAt: string, publishedAt?: string): Evidence {
  return { provider: SEC, url, license: "public_filing", retrievedAt, publishedAt };
}

export function archiveUrl(cik: string, accession: string, document?: string): string {
  const base = `https://www.sec.gov/Archives/edgar/data/${Number(cik)}/${accession.replaceAll("-", "")}/`;
  const primary = document && /^(?:[\w.-]+\/)*[\w.-]+$/.test(document) && !document.split("/").some((part) => part === "." || part === "..");
  return base + (primary ? document : `${accession}-index.htm`);
}

export function normalizeSecDirectory(raw: unknown): SecListing[] {
  const obj = asObject(raw);
  if (!Array.isArray(obj.fields) || !Array.isArray(obj.data)) return [];
  const fields = obj.fields;
  const [cikCol, nameCol, tickerCol, exchangeCol] = ["cik", "name", "ticker", "exchange"].map((field) => fields.indexOf(field));
  if ([cikCol, nameCol, tickerCol, exchangeCol].includes(-1)) return [];
  return obj.data.flatMap((row: unknown) => {
    if (!Array.isArray(row)) return [];
    const cik = asNumber(row[cikCol]);
    const name = asText(row[nameCol]);
    const symbol = asText(row[tickerCol])?.toUpperCase();
    const exchange = asText(row[exchangeCol]);
    if (!cik || cik < 1 || cik > 9_999_999_999 || !Number.isInteger(cik) || !name || !symbol || !exchange || !/^[A-Z0-9][A-Z0-9.\-&]{0,19}$/.test(symbol)) return [];
    return [{ cik: String(cik).padStart(10, "0"), symbol, name, exchange }];
  });
}

export function secDirectory(): Promise<SecListing[]> {
  if (!secConfigured()) return Promise.resolve([]);
  return cached("research:sec:directory", 86_400_000, async () => {
    const rows = normalizeSecDirectory(await secJSON(SEC_DIRECTORY));
    if (!rows.length) throw new Error("The SEC ticker directory was empty.");
    return rows;
  });
}

export function findSecListing(list: SecListing[], symbol: string): SecListing | undefined {
  const exact = list.filter((row) => row.symbol === symbol);
  const matches = exact.length ? exact : list.filter((row) => row.symbol.replace("-", ".") === symbol);
  return new Set(matches.map((row) => row.cik)).size === 1 ? matches[0] : undefined;
}

export interface SecSubmissions { profile: ResearchProfile; events: ResearchEvent[]; archives: string[] }

function filings(raw: unknown, cik: string, fetchedAt: string): ResearchEvent[] {
  const table = asObject(raw);
  const column = (key: string, i: number) => {
    const data = table[key];
    return Array.isArray(data) ? asText(data[i]) : undefined;
  };
  const accns = table.accessionNumber;
  if (!Array.isArray(accns)) return [];
  return accns.flatMap((accession: unknown, i): ResearchEvent[] => {
    const date = column("filingDate", i);
    const accepted = column("acceptanceDateTime", i);
    const category = column("form", i);
    if (typeof accession !== "string" || !ACCESSION.test(accession) || !date || !DATE.test(date) || !category) return [];
    return [{
      id: accession, title: column("primaryDocDescription", i) || `Form ${category}`,
      category, date, reportDate: column("reportDate", i),
      evidence: evidence(archiveUrl(cik, accession, column("primaryDocument", i)), fetchedAt, accepted && Number.isFinite(Date.parse(accepted)) ? accepted : date),
    }];
  });
}

export async function secSubmissions(listing: SecListing): Promise<SecSubmissions> {
  return cached(`research:sec:submissions:${listing.cik}`, 20 * 60_000, async () => {
    const url = `https://data.sec.gov/submissions/CIK${listing.cik}.json`;
    const raw = asObject(await secJSON(url));
    const fetchedAt = new Date().toISOString();
    const business = asObject(asObject(raw.addresses).business);
    const companyFilings = asObject(raw.filings);
    const archives = Array.isArray(companyFilings.files)
      ? companyFilings.files.map((file: unknown) => asText(asObject(file).name)).filter((name): name is string => Boolean(name && /^CIK\d{10}-submissions-\d{3,}\.json$/.test(name) && name.startsWith(`CIK${listing.cik}-`)))
      : [];
    const recent = filings(companyFilings.recent, listing.cik, fetchedAt);
    return {
      profile: {
        name: asText(raw.name) ?? listing.name, cik: listing.cik, exchange: listing.exchange,
        industry: asText(raw.sicDescription), headquarters: [asText(business.city), asText(business.stateOrCountryDescription)].filter(Boolean).join(", ") || undefined,
        incorporation: asText(raw.stateOfIncorporationDescription),
        website: safeUrl(raw.website) ?? safeUrl(raw.investorWebsite),
        evidence: evidence(url, fetchedAt),
      },
      events: recent,
      archives,
    };
  });
}

export function secArchive(cik: string, name: string): Promise<ResearchEvent[]> {
  return cached(`research:sec:archive:${name}`, 86_400_000, async () => {
    const payload = await secJSON(`https://data.sec.gov/submissions/${name}`);
    return filings(payload, cik, new Date().toISOString());
  });
}

const INCOME = new Set(["RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues", "SalesRevenueNet", "Revenue", "CostOfRevenue", "CostOfGoodsAndServicesSold", "GrossProfit", "OperatingIncomeLoss", "OperatingIncome", "ProfitLossFromOperatingActivities", "ResearchAndDevelopmentExpense", "OperatingExpenses", "InterestExpense", "IncomeTaxExpenseBenefit", "IncomeTaxExpenseContinuingOperations", "NetIncomeLoss", "ProfitLoss", "EarningsPerShareBasic", "EarningsPerShareDiluted", "BasicEarningsLossPerShare", "DilutedEarningsLossPerShare", "WeightedAverageNumberOfSharesOutstandingBasic", "WeightedAverageNumberOfDilutedSharesOutstanding"]);
const BALANCE = new Set(["Assets", "AssetsCurrent", "CurrentAssets", "Liabilities", "LiabilitiesCurrent", "CurrentLiabilities", "StockholdersEquity", "Equity", "CashAndCashEquivalentsAtCarryingValue", "CashAndCashEquivalents", "InventoryNet", "Inventories", "AccountsReceivableNetCurrent", "Goodwill", "LongTermDebtCurrent", "LongTermDebtNoncurrent", "ShortTermBorrowings", "PropertyPlantAndEquipmentNet", "EntityCommonStockSharesOutstanding"]);
const CASH = new Set(["NetCashProvidedByUsedInOperatingActivities", "CashFlowsFromUsedInOperatingActivities", "NetCashProvidedByUsedInInvestingActivities", "CashFlowsFromUsedInInvestingActivities", "NetCashProvidedByUsedInFinancingActivities", "CashFlowsFromUsedInFinancingActivities", "PaymentsToAcquirePropertyPlantAndEquipment", "PurchaseOfPropertyPlantAndEquipmentClassifiedAsInvestingActivities", "PaymentsForRepurchaseOfCommonStock", "PaymentsOfDividends", "ShareBasedCompensation", "DepreciationDepletionAndAmortization"]);

function statementFor(tag: string): Statement {
  if (INCOME.has(tag)) return "income";
  if (BALANCE.has(tag)) return "balance";
  if (CASH.has(tag)) return "cash";
  return "other";
}

export function normalizeSecFacts(raw: unknown, cik: string, retrievedAt: string): FinancialFact[] {
  const result: FinancialFact[] = [];
  for (const [taxonomy, concepts] of Object.entries(asObject(asObject(raw).facts))) {
    for (const [tag, body] of Object.entries(asObject(concepts))) {
      const { label, units } = asObject(body);
      for (const [unit, observations] of Object.entries(asObject(units))) {
        if (!Array.isArray(observations)) continue;
        for (const observation of observations) {
          const { val, end, start, filed, accn, form } = asObject(observation);
          if (asNumber(val) === undefined || typeof end !== "string" || !DATE.test(end) || typeof filed !== "string" || !DATE.test(filed) || end > filed || typeof accn !== "string" || !ACCESSION.test(accn) || typeof form !== "string") continue;
          const from = typeof start === "string" && DATE.test(start) ? start : undefined;
          if ((start != null && !from) || (from && from > end)) continue;
          const days = from ? (Date.parse(end) - Date.parse(from)) / 86_400_000 + 1 : undefined;
          const statement = statementFor(tag);
          let period: FinancialFact["period"] = "other";
          // Duration is measured directly. The filing's fp labels the document, not every row.
          if (FORM.test(form) && !QUARTER_FORM.test(form) && (days === undefined || days >= 350 && days <= 380)) period = "annual";
          if ((QUARTER_FORM.test(form) || FORM.test(form) && days !== undefined) && (days === undefined || days >= 75 && days <= 105)) period = "quarter";
          result.push({
            concept: `${taxonomy}:${tag}`, label: asText(label) ?? tag, statement, value: val as number, unit, start: from, end, period,
            evidence: evidence(archiveUrl(cik, accn), retrievedAt, filed),
          });
        }
      }
    }
  }
  return [...new Map(result.map((fact) => [[fact.concept, fact.unit, fact.start, fact.end, fact.evidence.url, fact.value].join("|"), fact])).values()];
}

export async function secFacts(listing: SecListing): Promise<FinancialFact[]> {
  const url = `https://data.sec.gov/api/xbrl/companyfacts/CIK${listing.cik}.json`;
  return normalizeSecFacts(await secJSON(url), listing.cik, new Date().toISOString());
}
