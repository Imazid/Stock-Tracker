import type { SupabaseClient } from "@supabase/supabase-js";
import { assetRisk } from "@/lib/asset-risk";
import { instrumentID } from "@engine/market.ts";
import { matchingHoldingQuote, portfolioExposure, portfolioInstrument } from "@/lib/portfolio-exposure";
import { toView } from "@/lib/instrument-view";
import type { QuoteResponse } from "@/lib/market-types";
import { getCandles, getQuote } from "@/server/market/service";
import { portfolioReferenceRates } from "./reference-rates";
import { issuerClassifications } from "./issuer-classifications";

const MAX_HOLDINGS = 200;
const MAX_QUOTES = 40;

export async function accountPortfolioRisk(db: SupabaseClient, owner: string, signal: AbortSignal, now = Date.now()) {
  const result = await db.from("portfolio_holdings").select("asset_symbol,asset_name,asset_kind,asset_exchange,shares")
    .eq("user_id", owner).is("deleted_at", null).gt("shares", 0).order("asset_symbol").order("id")
    .limit(MAX_HOLDINGS + 1).abortSignal(signal);
  if (result.error) throw new Error("Synced holdings are unavailable.");

  const holdings = result.data.slice(0, MAX_HOLDINGS).map((row) => {
    const asset = portfolioInstrument({ symbol: row.asset_symbol, name: row.asset_name, kind: row.asset_kind, exchange: row.asset_exchange });
    return { shares: Number(row.shares), instrument: asset ? toView(asset) : null, asset };
  });
  const listings = new Map(holdings.flatMap(({ asset, instrument }) => asset && instrument ? [[instrument.id, asset] as const] : []));
  const requested = [...listings.values()].slice(0, MAX_QUOTES);
  const quotes = new Map<string, QuoteResponse>();
  let cursor = 0;
  const needsRates = requested.some((instrument) => instrument.currency !== "AUD");
  const [rates] = await Promise.all([
    needsRates ? portfolioReferenceRates(signal, fetch, now).catch(() => undefined) : undefined,
    ...Array.from({ length: Math.min(8, requested.length) }, async () => {
      while (cursor < requested.length && !signal.aborted) {
        const instrument = requested[cursor++];
        const quote = await getQuote(instrument).catch(() => undefined);
        const observed = Date.parse(quote?.quote.observedAt ?? "");
        const id = instrumentID(instrument);
        if (quote?.instrument.id === id && observed >= now - 7 * 86_400_000 && observed <= Date.now()) {
          quotes.set(id, quote);
        }
      }
    }),
  ]);
  signal.throwIfAborted();
  const coveredIssuers = [...quotes.values()].filter(({ instrument, quote }) =>
    instrument.assetClass === "equity" && !quote.stale && matchingHoldingQuote(instrument, quote)).map(({ instrument }) => instrument.id);
  const issuer = await issuerClassifications(coveredIssuers).catch(() => ({ issuers: {}, limited: true }));
  signal.throwIfAborted();

  const exposure = portfolioExposure(holdings, (id) => quotes.get(id), "AUD", rates, issuer.issuers);
  const top = exposure.listings.slice(0, 5).map(({ id, value, weight }) => {
    const { instrument, quote } = quotes.get(id)!;
    return { id, symbol: instrument.symbol, venue: instrument.venueShort, value, weight,
      source: quote.source, observedAt: quote.observedAt, status: quote.status };
  });
  const sector = exposure.sectors.find(({ id }) => id !== "unknown" && id !== "etf" && id !== "crypto");
  const recentPriceRisk = await Promise.all(top.slice(0, 3).map(async ({ id, symbol, venue }) => {
    const candles = await getCandles(listings.get(id)!, "3M").catch(() => undefined);
    const risk = candles?.instrument.id === id ? assetRisk(candles, Date.now()) : undefined;
    return { id, symbol, venue, risk };
  }));
  signal.throwIfAborted();
  const sectorSource = sector ? exposure.issuerSources.filter(([, entry]) => entry.classification.sector === sector.id)
    .slice(0, 5).map(([id, { classification }]) => ({ id, issuer: classification.issuer, url: classification.evidence.url,
      observedAt: classification.evidence.filedOn ?? classification.evidence.retrievedAt })) : [];
  const holdingsTruncated = result.data.length > MAX_HOLDINGS;
  const unquotedListings = Math.max(0, listings.size - requested.length);
  return {
    currency: "AUD" as const, checkedAt: new Date(now).toISOString(), holdingsChecked: holdings.length,
    holdingsValued: exposure.priced, missingRates: exposure.missingRates,
    unresolvedHoldings: holdings.filter(({ instrument }) => !instrument).length,
    holdingsTruncated, unquotedListings, total: exposure.total, oldestQuote: exposure.oldestQuote, fxDates: exposure.fxDates,
    top, topThreeWeight: top.slice(0, 3).reduce((sum, listing) => sum + listing.weight, 0), recentPriceRisk,
    quoteCurrencies: exposure.currencies, largestSector: sector, sectorCoverageWeight: exposure.classifiedWeight.sectors,
    issuerLookupsLimited: issuer.limited, sectorSources: sectorSource,
  };
}

export type PortfolioRiskSummary = Awaited<ReturnType<typeof accountPortfolioRisk>>;
