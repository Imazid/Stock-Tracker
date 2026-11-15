const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;
const classes = new Set(["Startup equity", "Venture fund", "Private equity", "Syndicate or SPV", "Private secondary", "Other alternative"]);
const decimal = /^-?\d{1,22}(?:\.\d{1,16})?$/;
const text = (value: unknown, max: number): value is string =>
  typeof value === "string" && value.trim().length > 0 && value.length <= max;
const reading = (value: unknown, signed = false): value is string =>
  typeof value === "string" && value.trim() === value && decimal.test(value) && (signed || !value.startsWith("-"));
const date = (value: unknown): value is string =>
  typeof value === "string" && value.length === 20 && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value) &&
  Number.isFinite(Date.parse(value)) && new Date(value).toISOString().replace(".000Z", "Z") === value;
function fields(value: unknown, keys: string[]): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value) &&
    Object.keys(value).every((key) => keys.includes(key));
}

const capitalStatuses = new Set(["pending", "paid", "cancelled", "distribution", "sale"]);

function calendarDay(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) && date(`${value}T00:00:00Z`);
}

function validCapitalActivity(value: unknown): boolean {
  if (!Array.isArray(value)) return false;
  const seen = new Set<string>();
  for (const entry of value) {
    if (!fields(entry, ["id", "status", "amount", "date", "dueOn", "source", "resolutionSource"]) ||
      typeof entry.id !== "string" || !uuid.test(entry.id) || seen.has(entry.id.toLowerCase()) ||
      typeof entry.status !== "string" || !capitalStatuses.has(entry.status) ||
      !reading(entry.amount) || !calendarDay(entry.date) || !text(entry.source, 400)) return false;
    if (entry.status === "paid" || entry.status === "cancelled") {
      if (entry.dueOn !== undefined && !calendarDay(entry.dueOn)) return false;
      if (entry.resolutionSource !== undefined && (!text(entry.resolutionSource, 400) || !entry.dueOn)) return false;
      if (entry.status === "cancelled" && (!entry.dueOn || !entry.resolutionSource)) return false;
    } else if (entry.dueOn !== undefined || entry.resolutionSource !== undefined) return false;
    seen.add(entry.id.toLowerCase());
  }
  return true;
}

export type SnapshotValuation = { value: string; date: string; source: string; method: string };

export function validSnapshotValuation(mark: unknown, latestValuation: number): mark is SnapshotValuation {
  return fields(mark, ["value", "date", "source", "method"]) && reading(mark.value) && date(mark.date) &&
    text(mark.source, 400) && text(mark.method, 400) && Date.parse(mark.date) <= latestValuation;
}

type OwnershipEvidence = { excerptID: string; reviewedOn: string };
type SnapshotHolding = Record<string, unknown> & { ownershipEvidence?: OwnershipEvidence };

export function validManualSnapshot(value: unknown, latestValuation = Date.now()): value is SnapshotHolding[] {
  if (!Array.isArray(value) || !value.length || value.length > 150) return false;
  const seen = new Set<string>();
  for (const item of value) {
    if (!fields(item, ["id", "name", "assetClass", "currency", "units", "ownership", "shareClass", "lockupUntil",
      "commitment", "paid", "returned", "pendingCalls", "exitedOn", "valuation", "netGain", "realizedGain",
      "unrealizedGain", "multiple", "dpi", "xirr", "ownershipEvidence", "capitalActivity"]) ||
      typeof item.id !== "string" || !uuid.test(item.id) || seen.has(item.id.toLowerCase()) ||
      !text(item.name, 160) || typeof item.assetClass !== "string" || !classes.has(item.assetClass) ||
      typeof item.currency !== "string" || !/^[A-Z]{3}$/.test(item.currency) ||
      (item.shareClass !== undefined && !text(item.shareClass, 160)) ||
      !reading(item.paid) || !reading(item.returned) || !reading(item.pendingCalls)) return false;
    if (["units", "commitment", "multiple", "dpi"].some((key) => item[key] !== undefined && !reading(item[key])) ||
      ["netGain", "realizedGain", "unrealizedGain", "xirr"].some((key) => item[key] !== undefined && !reading(item[key], true)) ||
      ["lockupUntil", "exitedOn"].some((key) => item[key] !== undefined && !date(item[key])) ||
      (item.ownership !== undefined && (!reading(item.ownership) || Number(item.ownership) > 100))) return false;
    if (item.capitalActivity !== undefined && !validCapitalActivity(item.capitalActivity)) return false;
    if (item.ownershipEvidence !== undefined) {
      const evidence = item.ownershipEvidence;
      if (!fields(evidence, ["excerptID", "reviewedOn"]) || typeof evidence.excerptID !== "string" ||
        !uuid.test(evidence.excerptID) || !date(evidence.reviewedOn) || Date.parse(evidence.reviewedOn) > Date.now()) return false;
    }
    if (item.valuation !== undefined && !validSnapshotValuation(item.valuation, latestValuation)) return false;
    seen.add(item.id.toLowerCase());
  }
  return true;
}
