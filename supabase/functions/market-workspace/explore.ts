import { COIN_IDS } from "../_shared/market/coingecko.ts";
import { isRecord, type MarketDataProvider } from "../_shared/market/provider.ts";
import { MarketCalendar } from "../_shared/trading/calendar.ts";
import { catalogInstruments, UniverseCatalog } from "../_shared/trading/catalog.ts";
import { type Instrument, instrumentID, makeInstrument, type Venue } from "../_shared/trading/market.ts";

type Side = "gainers" | "losers";
type StockVenue = Extract<Venue, "us" | "asx">;

export interface MarketMover {
  instrument: Instrument;
  price: number;
  changePct: number;
}

export interface Movers {
  source: string;
  scope: string;
  observedAt: string;
  gainers: MarketMover[];
  losers: MarketMover[];
}

export interface TrendingCrypto {
  checkedAt: string;
  instruments: Instrument[];
}

export interface MarketExplore {
  us: Movers | null;
  asx: Movers | null;
  trending: TrendingCrypto | null;
  mostWatched?: Instrument[];
}

const STOCKS = [...UniverseCatalog.technology, ...UniverseCatalog.financials, ...UniverseCatalog.healthcare, ...UniverseCatalog.energy, ...UniverseCatalog.otherUS];
const KNOWN = new Map(catalogInstruments.map((instrument) => [instrumentID(instrument), instrument]));
const DISPLAY_LIMIT = 5;

export function knownWatchedListings(payload: unknown): Instrument[] {
  if (!Array.isArray(payload)) return [];
  return payload.flatMap((id) => {
    const instrument = typeof id === "string" ? KNOWN.get(id) : undefined;
    return instrument ? [instrument] : [];
  }).slice(0, DISPLAY_LIMIT);
}

function splitMovers(rows: MarketMover[]): Pick<Movers, Side> {
  return {
    gainers: rows.filter((row) => row.changePct > 0).sort((a, b) => b.changePct - a.changePct).slice(0, DISPLAY_LIMIT),
    losers: rows.filter((row) => row.changePct < 0).sort((a, b) => a.changePct - b.changePct).slice(0, DISPLAY_LIMIT),
  };
}

export function decodeAlpacaMovers(payload: unknown, now: number): Movers | null {
  if (!isRecord(payload) || payload.market_type !== "stocks" || typeof payload.last_updated !== "string" ||
      !Array.isArray(payload.gainers) || !Array.isArray(payload.losers)) return null;
  const stamp = Date.parse(payload.last_updated);
  if (!Number.isFinite(stamp) || stamp > now + 60_000 || MarketCalendar.tradingDays("us", stamp, now) > 1) return null;
  const open = MarketCalendar.session("us", now);
  if (open && now >= open.start && now < open.end && stamp < Math.max(open.start, now - 30 * 60_000)) return null;

  const seen = new Set<string>();
  const rows: MarketMover[] = [];
  for (const entry of [...payload.gainers, ...payload.losers]) {
    if (!isRecord(entry) || typeof entry.symbol !== "string" || !/^[A-Z0-9][A-Z0-9.-]{0,19}$/.test(entry.symbol) ||
        typeof entry.price !== "number" || !Number.isFinite(entry.price) || entry.price <= 0 ||
        typeof entry.percent_change !== "number" || !Number.isFinite(entry.percent_change) ||
        entry.percent_change <= -100 || seen.has(entry.symbol)) continue;
    seen.add(entry.symbol);
    rows.push({
      instrument: KNOWN.get(`us:${entry.symbol}`) ?? makeInstrument(entry.symbol, "equity", "us"),
      price: entry.price,
      changePct: entry.percent_change,
    });
  }
  if (!rows.some((row) => row.changePct !== 0)) return null;
  return { source: "Alpaca (SIP screener)", scope: "Eligible US listings · change from previous close", observedAt: new Date(stamp).toISOString(), ...splitMovers(rows) };
}

function previousSessions(venue: StockVenue, now: number): [number, number] | undefined {
  const closes: number[] = [];
  for (let day = 0; day < 10 && closes.length < 2; day++) {
    const stamp = now - day * 86_400_000;
    if (!MarketCalendar.coversDate(venue, stamp)) return undefined;
    const hours = MarketCalendar.session(venue, stamp);
    if (hours && hours.end + 20 * 60_000 <= now) closes.push(hours.end);
  }
  return closes.length === 2 ? [closes[1], closes[0]] : undefined;
}

export async function trackedStockMovers(provider: MarketDataProvider, venue: StockVenue, now: number): Promise<Movers | null> {
  const closes = previousSessions(venue, now);
  if (!closes) return null;
  const universe = venue === "asx" ? UniverseCatalog.asxBlueChips : STOCKS;
  const { series } = await provider.bars(universe, "day", 4, now);
  const rows: MarketMover[] = [];
  const sources = new Set<string>();
  for (const instrument of universe) {
    const data = series[instrumentID(instrument)];
    if (!data || data.provenance.kind !== "market") continue;
    // A bar must belong to the exact comparison session on its own exchange.
    const barFor = (close: number) => data.bars.findLast((bar) => MarketCalendar.session(venue, bar.time)?.end === close);
    const start = barFor(closes[0])?.close;
    const end = barFor(closes[1])?.close;
    if (!start || !end || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < 0) continue;
    const changePct = (end / start - 1) * 100;
    if (!Number.isFinite(changePct)) continue;
    rows.push({ instrument, price: end, changePct });
    sources.add(data.provenance.source);
  }
  if (rows.length < Math.ceil(universe.length / 2)) return null;
  return {
    source: [...sources].sort().join(" · "),
    scope: `Last completed session · ${rows.length} of ${universe.length} tracked ${venue === "asx" ? "ASX" : "US"} stocks`,
    observedAt: new Date(closes[1]).toISOString(),
    ...splitMovers(rows),
  };
}

export function decodeTrendingCrypto(payload: unknown, now: number): TrendingCrypto | null {
  if (!isRecord(payload) || !Array.isArray(payload.coins)) return null;
  const instruments: Instrument[] = [];
  const seen = new Set<string>();
  for (const value of payload.coins) {
    if (!isRecord(value) || !isRecord(value.item)) continue;
    const { id, name, symbol } = value.item;
    if (typeof id !== "string" || typeof name !== "string" || typeof symbol !== "string") continue;
    const ticker = symbol.toUpperCase();
    // CoinGecko IDs distinguish unrelated tokens sharing a ticker.
    if (COIN_IDS.get(ticker) !== id || seen.has(id)) continue;
    seen.add(id);
    instruments.push(KNOWN.get(`crypto:${ticker}`) ?? makeInstrument(ticker, "crypto", "crypto", name));
    if (instruments.length === DISPLAY_LIMIT) break;
  }
  return { checkedAt: new Date(now).toISOString(), instruments };
}

async function upstream(url: string, headers: Record<string, string>, request: typeof fetch): Promise<unknown> {
  const response = await request(url, { headers, signal: AbortSignal.timeout(5_000), redirect: "error" });
  if (response.ok) return await response.json();
  await response.body?.cancel().catch(() => {});
  return null;
}

export async function marketExplore(provider: MarketDataProvider, env: (name: string) => string | undefined, now: number, request = fetch): Promise<MarketExplore> {
  const key = env("ALPACA_DATA_KEY_ID");
  const secret = env("ALPACA_DATA_SECRET");
  const cgKey = env("COINGECKO_API_KEY");
  const [us, asx, trending] = await Promise.all([
    (async () => {
      if (key && secret) {
        const raw = await upstream("https://data.alpaca.markets/v1beta1/screener/stocks/movers?top=8",
          { "APCA-API-KEY-ID": key, "APCA-API-SECRET-KEY": secret }, request).catch(() => null);
        const screener = decodeAlpacaMovers(raw, now);
        if (screener) return screener;
      }
      return await trackedStockMovers(provider, "us", now);
    })().catch(() => null),
    trackedStockMovers(provider, "asx", now).catch(() => null),
    upstream("https://api.coingecko.com/api/v3/search/trending", cgKey ? { "x-cg-demo-api-key": cgKey } : {}, request)
      .then((raw) => decodeTrendingCrypto(raw, now)).catch(() => null),
  ]);
  return { us, asx, trending };
}

// Concurrent callers in one isolate share the same read. A complete outage retries sooner.
let cached: { expires: number; value: Promise<MarketExplore> } | undefined;
export function cachedMarketExplore(provider: MarketDataProvider, env: (name: string) => string | undefined, now: number): Promise<MarketExplore> {
  if (cached && cached.expires > now) return cached.value;
  const entry = { expires: now + 120_000, value: marketExplore(provider, env, now) };
  cached = entry;
  void entry.value.then((feed) => {
    if (!feed.us && !feed.asx && !feed.trending) entry.expires = now + 20_000;
  });
  return entry.value;
}
