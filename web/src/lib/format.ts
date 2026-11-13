// Number and time formatting. Money always shows its currency explicitly (A$, US$, £ …):
// two markets side by side must never both read "$".

const SYMBOLS: Record<string, string> = {
  USD: "US$", AUD: "A$", GBP: "£", EUR: "€", CHF: "CHF ", JPY: "¥", HKD: "HK$", SGD: "S$", KRW: "₩", INR: "₹", CAD: "C$", NZD: "NZ$",
};

export function currencySymbol(currency: string): string {
  return SYMBOLS[currency] ?? `${currency} `;
}

function decimalsFor(value: number, currency: string): number {
  if (currency === "JPY" || currency === "KRW") return value >= 100 ? 0 : 2;
  const abs = Math.abs(value);
  if (abs === 0) return 2;
  if (abs < 0.01) return 6;
  if (abs < 1) return 4;
  return 2;
}

export function money(value: number | undefined | null, currency: string, options: { decimals?: number } = {}): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  const decimals = options.decimals ?? decimalsFor(value, currency);
  const text = Math.abs(value).toLocaleString("en-AU", { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
  return `${value < 0 ? "−" : ""}${currencySymbol(currency)}${text}`;
}

export function signedMoney(value: number | undefined | null, currency: string): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  return `${value > 0 ? "+" : value < 0 ? "−" : ""}${money(Math.abs(value), currency)}`;
}

export function percent(value: number | undefined | null, options: { signed?: boolean; decimals?: number } = {}): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  const d = options.decimals ?? 2;
  const sign = options.signed !== false ? (value > 0 ? "+" : value < 0 ? "−" : "") : value < 0 ? "−" : "";
  return `${sign}${Math.abs(value).toFixed(d)}%`;
}

export function compact(value: number | undefined | null): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  return new Intl.NumberFormat("en-AU", { notation: "compact", maximumFractionDigits: 2 }).format(value);
}

export function plainNumber(value: number | undefined | null, decimals = 2): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return "—";
  return value.toLocaleString("en-AU", { minimumFractionDigits: 0, maximumFractionDigits: decimals });
}

/** "2 min ago", "3 h ago", "12 Nov 14:05" — relative to now. */
export function ago(iso: string | undefined, now = Date.now()): string {
  if (!iso) return "—";
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "—";
  const s = Math.round((now - t) / 1000);
  if (s < 45) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86_400) return `${Math.round(s / 3600)} h ago`;
  return dateTime(iso);
}

/** Local date-time with the viewer's zone named, so it's never ambiguous. */
export function dateTime(iso: string | undefined): string {
  if (!iso) return "—";
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "—";
  return new Intl.DateTimeFormat("en-AU", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false, timeZoneName: "short" }).format(new Date(t));
}

export function direction(value: number | undefined | null): "up" | "down" | "flat" {
  if (value === undefined || value === null || !Number.isFinite(value) || value === 0) return "flat";
  return value > 0 ? "up" : "down";
}
