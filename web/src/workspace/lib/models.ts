export type Venue = "us" | "asx" | "crypto" | "lse" | "xetra" | "euronextParis" | "euronextAmsterdam" | "six" | "tse" | "hkex" | "sgx" | "krx" | "nse";
export type Instrument = { symbol: string; name: string; venue: Venue; currency: string; assetClass: "equity" | "etf" | "crypto" };
export type Provenance = { source: string; delaySeconds: number };
export type Quote = { last: number; time: number; provenance: Provenance };
export type Bar = { time: number; open: number; high: number; low: number; close: number; volume: number };
export type Series = { bars: Bar[]; provenance: Provenance };
export type Quotes = { quotes: Record<string, Quote>; series: Record<string, Series> };
export type Point = { time: number; value: number };
export type Range = "1D" | "1W" | "1M" | "3M" | "1Y";
export type Holding = { id: string; asset_symbol: string; asset_name: string; asset_kind: string; asset_exchange: string | null; shares: number; avg_cost: number; ledger_revision: string };
export type Watch = { id: string; symbol: string; name: string; kind: string; exchange: string | null };
export type Alert = { id: string; symbol: string; target_price: number; condition: "Above" | "Below"; is_active: boolean; repeats: boolean };
export type Transaction = { id: string; holding_id: string; transaction_date: string; shares: number; price_per_share: number; type: string };
export type Journal = { holdings: Holding[]; watch: Watch[]; alerts: Alert[]; transactions: Transaction[] };
export const emptyJournal: Journal = { holdings: [], watch: [], alerts: [], transactions: [] };

export const venues: Record<Venue, { title: string; currency: string; suffix?: string }> = {
  us: { title: "US", currency: "USD" }, crypto: { title: "Crypto", currency: "USD" },
  asx: { title: "ASX", currency: "AUD", suffix: ".AX" }, lse: { title: "LSE", currency: "GBP", suffix: ".L" },
  xetra: { title: "XETRA", currency: "EUR", suffix: ".DE" }, euronextParis: { title: "Paris", currency: "EUR", suffix: ".PA" },
  euronextAmsterdam: { title: "Amsterdam", currency: "EUR", suffix: ".AS" }, six: { title: "SIX", currency: "CHF", suffix: ".SW" },
  tse: { title: "TSE", currency: "JPY", suffix: ".T" }, hkex: { title: "HKEX", currency: "HKD", suffix: ".HK" },
  sgx: { title: "SGX", currency: "SGD", suffix: ".SI" }, krx: { title: "KRX", currency: "KRW", suffix: ".KS" },
  nse: { title: "NSE", currency: "INR", suffix: ".NS" },
};
const etfs = new Set(["SPY", "QQQ", "VTI", "VOO", "VXUS", "BND", "GLD", "DIA", "IWM", "VAS", "VGS"]);
export const instrumentID = ({ venue, symbol }: Instrument) => `${venue}:${symbol}`;

export function fromTicker(ticker: string, name = "", market?: Venue, assetClass?: Instrument["assetClass"]): Instrument {
  const symbol = ticker.toUpperCase().trim();
  const listing = (Object.entries(venues) as [Venue, typeof venues.us][]).find(([, entry]) => entry.suffix && symbol.endsWith(entry.suffix));
  const venue = listing?.[0] ?? market ?? (assetClass === "crypto" ? "crypto" : "us");
  const bare = listing?.[1].suffix ? symbol.slice(0, -listing[1].suffix.length) : symbol;
  return { symbol: bare, name: name.trim() || bare, venue, assetClass: venue === "crypto" ? "crypto" : assetClass === "etf" || etfs.has(bare) ? "etf" : "equity", currency: venues[venue].currency };
}

export function fromWatch(row: Pick<Watch, "symbol" | "name" | "kind" | "exchange">) {
  const exchange = row.exchange?.toLowerCase() ?? "";
  const market = (Object.entries(venues) as [Venue, typeof venues.us][]).find(([id, entry]) =>
    exchange === id.toLowerCase() || exchange === entry.title.toLowerCase())?.[0];
  const aliases: Record<string, Venue> = { "australian securities exchange": "asx", "london stock exchange": "lse", tokyo: "tse", "hong kong": "hkex", "national stock exchange": "nse", sydney: "asx" };
  return fromTicker(row.symbol.replace(/\/USD$/i, ""), row.name, row.kind.toLowerCase() === "crypto" ? "crypto" : market ?? aliases[exchange], row.kind.toLowerCase() === "etf" ? "etf" : undefined);
}
export const fromHolding = (row: Holding) => fromWatch({ symbol: row.asset_symbol, name: row.asset_name, kind: row.asset_kind, exchange: row.asset_exchange });
export const storedTicker = (asset: Instrument) => asset.venue === "asx" ? asset.symbol : asset.symbol + (venues[asset.venue].suffix ?? "");
export const storedExchange = (asset: Instrument) => ({ us: "US", crypto: "Crypto" }[asset.venue as "us" | "crypto"] ?? venues[asset.venue].title);
export const storedKind = (asset: Instrument) => asset.assetClass === "crypto" ? "Crypto" : "Stock";
export const money = (value: number | null | undefined, currency = "USD") => value == null ? "—" :
  new Intl.NumberFormat("en-US", { style: "currency", currency, maximumFractionDigits: Math.abs(value) > 0 && Math.abs(value) < 1 ? 5 : 2 }).format(value);
export const qty = (value: number) => new Intl.NumberFormat("en-US", { maximumFractionDigits: 6 }).format(value);
export const pct = (value: number) => `${value >= 0 ? "+" : ""}${value.toFixed(2)}%`;
export const dateText = (value: number | string, dateOnly = false) => new Intl.DateTimeFormat("en-AU", dateOnly ?
  { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" } :
  { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" }).format(new Date(value));

export const popular = [
  fromTicker("SPY", "S&P 500 ETF"), fromTicker("QQQ", "Nasdaq-100 ETF"),
  fromTicker("AAPL", "Apple"), fromTicker("NVDA", "NVIDIA"), fromTicker("MSFT", "Microsoft"),
  fromTicker("BTC", "Bitcoin", "crypto"), fromTicker("ETH", "Ethereum", "crypto"),
  fromTicker("SOL", "Solana", "crypto"), fromTicker("BHP.AX", "BHP Group"), fromTicker("CBA.AX", "Commonwealth Bank"),
];
export const message = (error: unknown) => error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String(error.message) : "Something went wrong. Try again.";
