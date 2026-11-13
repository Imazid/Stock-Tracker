// SnapTrade reports the original currency and may have only a calendar date.
// Keep the reported day and signed amounts rather than inferring FX or settlement.
const KINDS: Record<string, string> = {
  CONTRIBUTION: "Cash contribution",
  WITHDRAWAL: "Cash withdrawal",
  DIVIDEND: "Dividend",
  SUBSTITUTE_DIVIDEND: "Substitute dividend",
  STOCK_DIVIDEND: "Stock dividend",
  REI: "Dividend reinvestment",
  INTEREST: "Interest",
  REBATE: "Rebate",
  RETURN_OF_CAPITAL: "Return of capital",
  DISTRIBUTION: "Distribution",
  FEE: "Fee",
  TAX: "Tax",
  TRANSFER: "Transfer",
  EXTERNAL_ASSET_TRANSFER_IN: "Incoming asset transfer",
  EXTERNAL_ASSET_TRANSFER_OUT: "Outgoing asset transfer",
  INTERNAL_CASH_TRANSFER_IN: "Incoming cash transfer between accounts",
  INTERNAL_CASH_TRANSFER_OUT: "Outgoing cash transfer between accounts",
  INTERNAL_ASSET_TRANSFER_IN: "Incoming asset transfer between accounts",
  INTERNAL_ASSET_TRANSFER_OUT: "Outgoing asset transfer between accounts",
  SPLIT: "Stock split",
  REVERSE_SPLIT: "Reverse stock split",
  SPINOFF: "Spinoff",
  STOCK_MERGER: "Merger",
  ADJUSTMENT: "Adjustment",
};

export const activityTypes = Object.keys(KINDS).join(",");
export const activityPageSize = 50;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

export function validActivityDay(value: unknown): value is string {
  if (typeof value !== "string" || !DAY.test(value) || value < "1900-01-01") return false;
  const timestamp = Date.parse(value + "T00:00:00Z");
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString().slice(0, 10) === value;
}

function record(value: unknown): Record<string, unknown> | undefined {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) return value as Record<string, unknown>;
}

function boundedNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER ? value : null;
}

function text(value: unknown, limit: number): string | null {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, limit) : null;
}

export async function normalizeActivityPage(
  payload: unknown,
  accountId: string,
  start: string,
  end: string,
  offset: number,
) {
  const body = record(payload);
  const page = record(body?.pagination);
  const total = page?.total;
  if (!Array.isArray(body?.data) || body.data.length > activityPageSize ||
      page?.offset !== offset || typeof total !== "number" || !Number.isSafeInteger(total) || total < 0 ||
      (body.data.length === 0 && offset < total) ||
      (body.data.length > 0 && offset + body.data.length > total)) return null;

  const rows = await Promise.all(body.data.map(async (value: unknown) => {
    const row = record(value);
    const kind = row?.type;
    const id = row?.id;
    const day = typeof row?.trade_date === "string" ? row.trade_date.slice(0, 10) : undefined;
    if (!row || typeof kind !== "string" || !Object.hasOwn(KINDS, kind) ||
        typeof id !== "string" || !id.trim() || id.length > 200 || !validActivityDay(day) || day < start || day > end) return null;

    const code = record(row.currency)?.code;
    const currency = typeof code === "string" && /^[A-Z]{3}$/.test(code) ? code : null;
    const amount = boundedNumber(row.amount);
    const symbol = text(record(row.symbol)?.symbol, 40);
    const option = record(row.option_symbol);
    const cashOnly = row.symbol === null && (row.option_symbol === null || row.option_symbol === undefined) &&
      (row.units === null || row.units === undefined || row.units === 0);
    const isDeposit = kind === "CONTRIBUTION" || kind === "INTERNAL_CASH_TRANSFER_IN";
    const isWithdrawal = kind === "WITHDRAWAL" || kind === "INTERNAL_CASH_TRANSFER_OUT";
    const kindMatchesAmount = amount !== null && (isDeposit && amount > 0 || isWithdrawal && amount < 0);
    const cents = amount === null ? 0 : Math.round(Math.abs(amount) * 100);
    const cashFlow = cashOnly && kindMatchesAmount && currency === "USD" && cents > 0 && cents <= 999999999999999 &&
      amount !== null && cents / 100 === Math.abs(amount) ? { date: day, kind: isDeposit ? "deposit" : "withdrawal", amount: cents / 100 } : null;
    const original = amount !== null ? String(Math.abs(amount)) : "";
    const foreignCashFlow = cashOnly && kindMatchesAmount && currency && currency !== "USD" &&
      /^(?:0|[1-9]\d{0,12})(?:\.\d{1,8})?$/.test(original)
      ? { date: day, kind: isDeposit ? "deposit" : "withdrawal", currency, amount: original }
      : null;
    const fingerprint = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([accountId.toLowerCase(), id])));
    return {
      id: Array.from(new Uint8Array(fingerprint), (byte) => byte.toString(16).padStart(2, "0")).join(""),
      date: day,
      label: KINDS[kind],
      amount,
      currency,
      units: boundedNumber(row.units),
      fee: boundedNumber(row.fee),
      symbol: symbol ?? text(option?.ticker, 40),
      cashFlow,
      foreignCashFlow,
    };
  }));
  const activities = [...new Map(rows.flatMap((row) => row ? [[row.id, row] as const] : [])).values()];
  const next = offset + body.data.length;
  return { activities, omitted: rows.filter((row) => !row).length, nextOffset: next < total ? next : null };
}
