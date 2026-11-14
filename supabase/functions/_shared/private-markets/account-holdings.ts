import { type AccountCashFlow, accountCashFlowBalances, accountSalePosition } from "./account-cash-flow.ts";
import { type SnapshotValuation, validManualSnapshot, validSnapshotValuation } from "./manual-snapshot.ts";

const sydneyDay = new Intl.DateTimeFormat("sv-SE", { dateStyle: "short", timeZone: "Australia/Sydney" });

const calendarLimit = (now: Date) => Date.parse(`${sydneyDay.format(now)}T00:00:00Z`);

export function accountValuation(mark: unknown, now: Date): SnapshotValuation | null {
  return validSnapshotValuation(mark, calendarLimit(now)) ? mark : null;
}

export function accountValuationDate(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}T00:00:00Z$/.test(value);
}

export type SavedAccountHolding = Record<string, unknown> & {
  valuation?: SnapshotValuation; valuationHistory?: SnapshotValuation[]; cashFlows?: AccountCashFlow[];
  sales?: AccountCashFlow[]; lastSaleOn?: string; exitedOn?: string;
};

export function accountValuations(holding?: SavedAccountHolding) {
  if (holding?.valuationHistory) return holding.valuationHistory;
  if (!holding?.valuation) return [];
  const mark = holding.valuation;
  const date = accountValuationDate(mark.date) ? mark.date : `${sydneyDay.format(new Date(mark.date))}T00:00:00Z`;
  return [{ ...mark, date }];
}

export function withAccountValuations(holding: SavedAccountHolding, marks: SnapshotValuation[],
  change?: SnapshotValuation | string): SavedAccountHolding {
  const changing = typeof change === "string" ? change : change?.date;
  const history = marks.filter((mark) => mark.date !== changing);
  if (change && typeof change !== "string") history.push(change);
  history.sort((a, b) => b.date.localeCompare(a.date));
  const latest = history[0];
  const valuation = holding.exitedOn || (latest && holding.lastSaleOn && latest.date.slice(0, 10) <= holding.lastSaleOn)
    ? undefined : latest;
  return { ...holding, valuation, valuationHistory: history };
}

export function accountHolding(value: unknown, now: Date) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const holding = value as Record<string, unknown>;
  if (Object.keys(holding).some((key) => ![
    "id", "name", "assetClass", "currency", "units", "ownership", "shareClass", "lockupUntil",
    "commitment", "valuation", "excerptID",
  ].includes(key))) return null;
  const { excerptID, id, currency, ...fields } = holding;
  if (typeof id !== "string" || typeof currency !== "string" ||
    (excerptID !== undefined && typeof excerptID !== "string")) return null;
  const canonical = {
    ...fields, id: id.toLowerCase(), currency, valuation: fields.valuation, paid: "0", returned: "0", pendingCalls: "0",
    ...(excerptID !== undefined ? {
      ownershipEvidence: { excerptID, reviewedOn: now.toISOString().replace(/\.\d{3}Z$/, "Z") },
    } : {}),
  };
  if (!validManualSnapshot([canonical], calendarLimit(now))) return null;
  const valuation = accountValuation(fields.valuation, now);
  if (fields.valuation !== undefined && !accountValuationDate(valuation?.date)) return null;
  return { ...canonical, valuation: valuation ?? undefined };
}


export function accountCashFlows(holding?: SavedAccountHolding) {
  return [...(holding?.cashFlows ?? []), ...(holding?.sales ?? [])];
}

export function withAccountCashFlows(holding: SavedAccountHolding, flows: AccountCashFlow[]): SavedAccountHolding | null {
  const cashFlows = flows.filter((flow) => flow.status !== "sale");
  // Earlier clients decode cashFlows using a closed enum.
  const sales = flows.filter((flow) => flow.status === "sale");
  const position = accountSalePosition(holding.units, sales);
  if (!position) return null;
  const balances = accountCashFlowBalances(cashFlows);
  return withAccountValuations({ ...holding, ...balances, ...position, cashFlows,
    sales: sales.length ? sales : undefined,
  }, accountValuations(holding));
}
