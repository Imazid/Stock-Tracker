export type AccountCashFlow = {
  id: string;
  status: "contribution" | "pending" | "paid" | "cancelled" | "distribution";
  amount: string;
  date: string;
  source: string;
  dueOn?: string;
  resolutionSource?: string;
};

const sydneyDay = new Intl.DateTimeFormat("sv-SE", { dateStyle: "short", timeZone: "Australia/Sydney" });
const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;

function day(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const time = Date.parse(value);
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value;
}

const source = (value: unknown): value is string => typeof value === "string" && !!value.trim() && value.length <= 400;

export function accountCashFlow(value: unknown, now: Date): AccountCashFlow | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const { id, status, amount, date, source: note, dueOn, resolutionSource, ...other } = value as Record<string, unknown>;
  if (Object.keys(other).length || typeof id !== "string" || !uuid.test(id) || !source(note) ||
    typeof amount !== "string" || !/^\d{1,22}(?:\.\d{1,16})?$/.test(amount) || !/[1-9]/.test(amount) ||
    !day(date) || (status !== "contribution" && status !== "distribution" && status !== "pending" &&
      status !== "paid" && status !== "cancelled")) return null;
  if (status !== "pending" && date > sydneyDay.format(now)) return null;
  const common: AccountCashFlow = { id: id.toLowerCase(), status, amount, date, source: note.trim() };
  if (status === "paid" || status === "cancelled") {
    if (!day(dueOn) || !source(resolutionSource)) return null;
    return { ...common, dueOn, resolutionSource: resolutionSource.trim() };
  }
  return dueOn === undefined && resolutionSource === undefined ? common : null;
}

// Exact totals for the ledger display. The clients derive ratios from these records.
function sumAmounts(flows: AccountCashFlow[], statuses: AccountCashFlow["status"][]) {
  const scale = 10n ** 16n;
  let total = 0n;
  for (const record of flows) {
    if (!statuses.includes(record.status)) continue;
    const [whole, fraction = ""] = record.amount.split(".");
    total += BigInt(whole) * scale + BigInt(fraction.padEnd(16, "0"));
  }
  const fraction = (total % scale).toString().padStart(16, "0").replace(/0+$/, "");
  return (total / scale).toString() + (fraction ? "." + fraction : "");
}

export function accountCashFlowBalances(flows: AccountCashFlow[]) {
  return {
    paid: sumAmounts(flows, ["contribution", "paid"]),
    returned: sumAmounts(flows, ["distribution"]),
    pendingCalls: sumAmounts(flows, ["pending"]),
  };
}
