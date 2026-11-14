import { catalogInstruments } from "../../../supabase/functions/_shared/trading/catalog.ts";
import { makeInstrument, parseYahooSymbol, venueCountry, type Venue } from "../../../supabase/functions/_shared/trading/market.ts";
import type { IssuerClassification } from "./issuer-classification.ts";
import type { InstrumentView, QuoteResponse } from "./market-types.ts";

export type ExposureCurrency = "AUD" | "USD";
export type PortfolioReferenceRates = Record<ExposureCurrency, Record<string, { rate: string; date: string }>>;

type Holding = { shares: number; instrument: InstrumentView | null };
type ExposureSlice = { label: string; value: number };
type Dimension = "asset" | "country" | "currency" | "listing" | "sector" | "incorporation";

const assetLabels = { equity: "Listed shares", etf: "ETFs", crypto: "Crypto" };

const venuesByExchange = new Map<string, Venue>([
  ["US", "us"], ["NYSE", "us"], ["XNYS", "us"], ["NASDAQ", "us"], ["XNAS", "us"],
  ["NYSE ARCA", "us"], ["ARCX", "us"], ["AMEX", "us"], ["XASE", "us"], ["BATS", "us"], ["BZX", "us"],
  ["ASX", "asx"], ["XASX", "asx"], ["AUSTRALIAN SECURITIES EXCHANGE", "asx"], ["LSE", "lse"], ["XLON", "lse"],
  ["XETRA", "xetra"], ["XETR", "xetra"], ["XPAR", "euronextParis"], ["PARIS", "euronextParis"],
  ["XAMS", "euronextAmsterdam"], ["AMSTERDAM", "euronextAmsterdam"],
  ["SIX", "six"], ["XSWX", "six"], ["TSE", "tse"], ["XTKS", "tse"], ["HKEX", "hkex"], ["XHKG", "hkex"],
  ["SGX", "sgx"], ["XSES", "sgx"], ["KRX", "krx"], ["XKRX", "krx"], ["NSE", "nse"], ["XNSE", "nse"],
]);
export function portfolioInstrument(row: { symbol: string; name: string; kind: "Stock" | "Crypto"; exchange: string | null }) {
  const symbol = row.symbol.trim().toUpperCase();
  if (row.kind === "Crypto") return makeInstrument(symbol.replace(/\/USD$/, ""), "crypto", "crypto", row.name);
  const exchange = row.exchange?.trim().toUpperCase() ?? "";
  const venue = venuesByExchange.get(exchange);
  const suffix = parseYahooSymbol(symbol);
  if (suffix) {
    if (venue && venue !== suffix.venue) return null;
    return makeInstrument(suffix.symbol, "equity", suffix.venue, row.name);
  }
  if (venue) return makeInstrument(symbol, "equity", venue, row.name);
  if (exchange) return null;
  const known = catalogInstruments.filter((item) => item.venue !== "crypto" && item.symbol === symbol);
  return known.length === 1 ? { ...known[0], name: row.name || known[0].name } : null;
}

export function portfolioExposure(
  holdings: readonly Holding[],
  quoteFor: (id: string) => QuoteResponse | undefined,
  base: ExposureCurrency,
  rates: PortfolioReferenceRates | undefined,
  issuers: Readonly<Record<string, IssuerClassification>> = {},
) {
  const buckets: Record<Dimension, Map<string, ExposureSlice>> = {
    asset: new Map(), country: new Map(), currency: new Map(), listing: new Map(),
    sector: new Map(), incorporation: new Map(),
  };
  const issuerSources = new Map<string, { listing: string; classification: IssuerClassification }>();
  const fxDates = new Set<string>();
  const classifiedValue = { sectors: 0, incorporations: 0 };
  let total = 0;
  let priced = 0;
  let missingRates = 0;
  let oldestQuote: string | undefined;

  function add(dimension: Dimension, key: string, label: string, value: number) {
    const group = buckets[dimension];
    group.set(key, { label, value: (group.get(key)?.value ?? 0) + value });
  }

  for (const { shares, instrument } of holdings) {
    if (!instrument) continue;
    const data = quoteFor(instrument.id);
    const quote = data?.quote;
    if (!quote || quote.instrumentId !== instrument.id || quote.currency !== instrument.currency || quote.stale ||
        !Number.isFinite(shares) || shares <= 0 || !Number.isFinite(quote.last) || quote.last <= 0) continue;
    const observed = Date.parse(quote.observedAt);
    if (!Number.isFinite(observed)) continue;
    const fx = quote.currency !== base ? rates?.[base]?.[quote.currency] : undefined;
    const rate = quote.currency === base ? 1 : Number(fx?.rate);
    if (!Number.isFinite(rate) || rate <= 0) {
      missingRates++;
      continue;
    }
    const value = shares * quote.last * rate;
    if (!Number.isFinite(value) || value <= 0 || !Number.isFinite(total + value)) continue;
    total += value;
    priced++;
    const iso = new Date(observed).toISOString();
    if (!oldestQuote || iso < oldestQuote) oldestQuote = iso;
    if (fx) fxDates.add(fx.date);
    const assetClass = data?.instrument.id === instrument.id ? data.instrument.assetClass : instrument.assetClass;
    const country = instrument.venue === "crypto" ? "Crypto markets" : venueCountry(instrument.venue);
    add("asset", assetClass, assetLabels[assetClass], value);
    add("country", country, country, value);
    add("currency", quote.currency, quote.currency, value);
    const listing = `${instrument.symbol} · ${instrument.venueShort}`;
    add("listing", instrument.id, listing, value);

    if (assetClass !== "equity") {
      add("sector", assetClass, assetLabels[assetClass], value);
      add("incorporation", assetClass, assetLabels[assetClass], value);
      continue;
    }
    const classification = issuers[instrument.id];
    if (classification?.sector) classifiedValue.sectors += value;
    if (classification?.country) classifiedValue.incorporations += value;
    add("sector", classification?.sector ?? "unknown", classification?.sector ?? "Unclassified shares", value);
    add("incorporation", classification?.country ?? "unknown", classification?.country ?? "Unclassified shares", value);
    if (classification) issuerSources.set(instrument.id, { listing, classification });
  }

  const rows = (dimension: Dimension) => [...buckets[dimension].entries()]
    .map(([id, item]) => ({ id, ...item, weight: item.value / total * 100 }))
    .sort((left, right) => right.value - left.value || left.id.localeCompare(right.id));

  return {
    total, priced, missingRates, oldestQuote, fxDates: [...fxDates].sort(),
    assets: rows("asset"), countries: rows("country"), currencies: rows("currency"), listings: rows("listing"),
    sectors: rows("sector"), incorporations: rows("incorporation"),
    classifiedWeight: {
      sectors: total ? classifiedValue.sectors / total * 100 : 0,
      incorporations: total ? classifiedValue.incorporations / total * 100 : 0,
    },
    issuerSources: [...issuerSources.entries()].sort(([, a], [, b]) => a.listing.localeCompare(b.listing)),
  };
}
