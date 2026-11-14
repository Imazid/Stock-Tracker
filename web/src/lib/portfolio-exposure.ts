import { catalogInstruments } from "../../../supabase/functions/_shared/trading/catalog.ts";
import { makeInstrument, parseYahooSymbol, venueCountry, type Venue } from "../../../supabase/functions/_shared/trading/market.ts";
import type { IssuerClassification } from "./issuer-classification.ts";
import type { InstrumentView, QuoteResponse, QuoteView } from "./market-types.ts";

export type ExposureCurrency = "AUD" | "USD";
export type PortfolioReferenceRates = Record<ExposureCurrency, Record<string, { rate: string; date: string }>>;

type Holding = { shares: number; instrument: InstrumentView | null };
type ExposureSlice = { label: string; value: number };
type Dimension = "asset" | "country" | "currency" | "listing" | "sector" | "incorporation";

export const portfolioAssetLabels = { equity: "Listed shares", etf: "ETFs", crypto: "Crypto" };

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
  if (!symbol) return null;
  if (row.kind === "Crypto") return makeInstrument(symbol.replace(/\/USD$/, ""), "crypto", "crypto", row.name);
  const exchange = row.exchange?.trim().toUpperCase() ?? "";
  const venue = venuesByExchange.get(exchange);
  const suffix = parseYahooSymbol(symbol);
  if (suffix && venue && venue !== suffix.venue) return null;
  const listingVenue = suffix?.venue ?? venue;
  if (listingVenue) {
    const ticker = suffix?.symbol ?? symbol;
    const known = catalogInstruments.find((item) => item.venue === listingVenue && item.symbol === ticker);
    return makeInstrument(ticker, known?.assetClass ?? "equity", listingVenue, row.name || known?.name);
  }
  if (exchange) return null;
  const known = catalogInstruments.filter((item) => item.venue !== "crypto" && item.symbol === symbol);
  return known.length === 1 ? { ...known[0], name: row.name || known[0].name } : null;
}

export function matchingHoldingQuote(instrument: InstrumentView | null, quote: QuoteView | undefined) {
  if (instrument && quote?.instrumentId === instrument.id && quote.currency === instrument.currency &&
      Number.isFinite(quote.last) && quote.last > 0 && Number.isFinite(Date.parse(quote.observedAt))) return quote;
}

export function holdingValue(shares: number, quote: QuoteView, base: ExposureCurrency, rates: PortfolioReferenceRates | undefined) {
  if (quote.stale || !Number.isFinite(shares) || shares <= 0) return {};
  const local = shares * quote.last;
  if (!Number.isFinite(local) || local <= 0) return {};
  const fx = quote.currency === base ? undefined : rates?.[base]?.[quote.currency];
  const rate = quote.currency === base ? 1 : Number(fx?.rate);
  if (!Number.isFinite(rate) || rate <= 0) return { local, missingRate: true };
  const converted = local * rate;
  return { local, converted: Number.isFinite(converted) && converted > 0 ? converted : undefined, fxDate: fx?.date };
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
    const quote = matchingHoldingQuote(instrument, data?.quote);
    if (!quote) continue;
    const { converted: value, missingRate, fxDate } = holdingValue(shares, quote, base, rates);
    if (missingRate) missingRates++;
    if (value === undefined || !Number.isFinite(total + value)) continue;
    total += value;
    priced++;
    const iso = new Date(quote.observedAt).toISOString();
    if (!oldestQuote || iso < oldestQuote) oldestQuote = iso;
    if (fxDate) fxDates.add(fxDate);
    const assetClass = data?.instrument.id === instrument.id ? data.instrument.assetClass : instrument.assetClass;
    const country = instrument.venue === "crypto" ? "Crypto markets" : venueCountry(instrument.venue);
    add("asset", assetClass, portfolioAssetLabels[assetClass], value);
    add("country", country, country, value);
    add("currency", quote.currency, quote.currency, value);
    const listing = `${instrument.symbol} · ${instrument.venueShort}`;
    add("listing", instrument.id, listing, value);

    if (assetClass !== "equity") {
      add("sector", assetClass, portfolioAssetLabels[assetClass], value);
      add("incorporation", assetClass, portfolioAssetLabels[assetClass], value);
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
