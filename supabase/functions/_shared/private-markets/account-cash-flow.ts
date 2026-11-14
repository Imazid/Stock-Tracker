export type AccountCashFlow = {
  id: string;
  status: "contribution" | "pending" | "paid" | "cancelled" | "distribution" | "sale";
  amount: string;
  date: string;
  source: string;
  dueOn?: string;
  resolutionSource?: string;
  soldUnits?: string;
  disposedCost?: string;
  closesPosition?: true;
};

const sydneyDay = new Intl.DateTimeFormat("sv-SE", { dateStyle: "short", timeZone: "Australia/Sydney" });
const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;
const decimal = (value: unknown): value is string => typeof value === "string" && /^\d{1,22}(?:\.\d{1,16})?$/.test(value);

function day(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const time = Date.parse(value);
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value;
}

const source = (value: unknown): value is string => typeof value === "string" && !!value.trim() && value.length <= 400;

export function accountCashFlow(value: unknown, now: Date): AccountCashFlow | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const { id, status, amount, date, source: note, dueOn, resolutionSource, soldUnits, disposedCost,
    closesPosition, ...other } = value as Record<string, unknown>;
  if (Object.keys(other).length || typeof id !== "string" || !uuid.test(id) || !source(note) ||
    !decimal(amount) || (status !== "sale" && !/[1-9]/.test(amount)) ||
    !day(date) || (status !== "contribution" && status !== "distribution" && status !== "pending" &&
      status !== "paid" && status !== "cancelled" && status !== "sale")) return null;
  if (status !== "pending" && date > sydneyDay.format(now)) return null;
  const common: AccountCashFlow = { id: id.toLowerCase(), status, amount, date, source: note.trim() };
  if (status === "sale") {
    if (dueOn !== undefined || resolutionSource !== undefined || (disposedCost !== undefined && !decimal(disposedCost))) return null;
    const sale = { ...common, disposedCost };
    if (closesPosition === true && soldUnits === undefined) return { ...sale, closesPosition: true };
    if (closesPosition === undefined && decimal(soldUnits) && /[1-9]/.test(soldUnits)) return { ...sale, soldUnits };
    return null;
  }
  if (soldUnits !== undefined || disposedCost !== undefined || closesPosition !== undefined) return null;
  if (status === "paid" || status === "cancelled") {
    if (!day(dueOn) || !source(resolutionSource)) return null;
    return { ...common, dueOn, resolutionSource: resolutionSource.trim() };
  }
  return dueOn === undefined && resolutionSource === undefined ? common : null;
}

const scale = 10n ** 16n;

function exact(value: string) {
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole) * scale + BigInt(fraction.padEnd(16, "0"));
}

function formatted(value: bigint) {
  const fraction = (value % scale).toString().padStart(16, "0").replace(/0+$/, "");
  return (value / scale).toString() + (fraction ? "." + fraction : "");
}

function sumAmounts(flows: AccountCashFlow[], statuses: AccountCashFlow["status"][]) {
  return formatted(flows.reduce((total, flow) => statuses.includes(flow.status) ? total + exact(flow.amount) : total, 0n));
}

export function accountSalePosition(units: unknown, sales: AccountCashFlow[]) {
  let remaining = decimal(units) ? exact(units) : undefined;
  let lastSaleOn: string | undefined;
  let exitedOn: string | undefined;
  let exitSource: string | undefined;
  const ordered = [...sales].sort((a, b) => a.date.localeCompare(b.date) ||
    Number(Boolean(a.closesPosition)) - Number(Boolean(b.closesPosition)));
  for (const sale of ordered) {
    if (remaining === 0n) return null;
    if (sale.closesPosition) {
      remaining = 0n;
    } else {
      if (remaining === undefined || sale.soldUnits === undefined) return null;
      remaining -= exact(sale.soldUnits);
      if (remaining < 0n) return null;
    }
    lastSaleOn = sale.date;
    if (remaining === 0n) {
      exitedOn = sale.date;
      exitSource = sale.source;
    }
  }
  return { remainingUnits: sales.length && remaining !== undefined ? formatted(remaining) : undefined,
    lastSaleOn, exitedOn, exitSource, saleProceeds: sales.length ? sumAmounts(sales, ["sale"]) : undefined };
}

export function accountCashFlowBalances(flows: AccountCashFlow[]) {
  return {
    paid: sumAmounts(flows, ["contribution", "paid"]),
    returned: sumAmounts(flows, ["distribution"]),
    pendingCalls: sumAmounts(flows, ["pending"]),
  };
}
