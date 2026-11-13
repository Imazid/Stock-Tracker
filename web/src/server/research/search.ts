import { type Venue, VENUES, makeInstrument, parseYahooSymbol } from "@engine/market.ts";
import type { SearchResult } from "@/lib/market-types";
import { toView } from "@/server/market/instruments";
import { fmpConfigured, fmpRows } from "./licensed";
import { secDirectory, type SecListing } from "./sec";
import { asText } from "./upstream";

export function decodeSearch(query: string): { term: string; venue?: Venue; cik?: string; identifier?: "isin" | "cusip" } {
  const q = query.trim();
  const venueFilter = /^([a-z]+)\s*:\s*(.+)$/i.exec(q);
  const rawVenue = venueFilter?.[1].toLowerCase();
  const venue = rawVenue === "au" ? "asx" : VENUES.find((v) => v.toLowerCase() === rawVenue);
  const cik = /^(?:CIK[\s:]*|(?=\d{10}$))(\d{1,10})$/i.exec(q)?.[1]?.padStart(10, "0");
  const identifier = /^(ISIN|CUSIP)\s*:\s*/i.exec(q)?.[1].toLowerCase() as "isin" | "cusip" | undefined;
  const term = venue ? venueFilter![2].trim() : identifier ? q.split(":").slice(1).join(":").trim().toUpperCase() : q;
  return { term, venue, cik, identifier };
}

const eligible = (row: SecListing) => /^(nasdaq|nyse|cboe|txse|otc)$/i.test(row.exchange);
function fromSec(row: SecListing): SearchResult {
  const etf = /\bETF\b|exchange.traded fund/i.test(row.name);
  return { ...toView(makeInstrument(row.symbol, etf ? "etf" : "equity", "us", row.name)), exchangeLabel: row.exchange, origin: "search" };
}

export async function researchSearch(query: ReturnType<typeof decodeSearch>): Promise<SearchResult[]> {
  if (!query.term || query.venue && query.venue !== "us") return [];
  const term = query.term.toUpperCase();
  if (query.identifier) {
    const valid = query.identifier === "isin" ? /^[A-Z]{2}[A-Z0-9]{9}\d$/.test(term) : /^[A-Z0-9]{9}$/.test(term);
    if (!valid || !fmpConfigured()) return [];
    const { rows } = await fmpRows(`search-${query.identifier}`, { [query.identifier]: term });
    return rows.flatMap((row): SearchResult[] => {
      const ticker = asText(row.symbol);
      const name = asText(row.name ?? row.companyName);
      const exchange = asText(row.exchange ?? row.exchangeShortName);
      if (!ticker || !name || !exchange || !/^[A-Z0-9][A-Z0-9.\-&]{0,19}$/.test(ticker)) return [];
      const listing = /^(NASDAQ|NYSE|AMEX|CBOE|OTC)/i.test(exchange)
        ? { venue: "us" as const, symbol: ticker }
        : parseYahooSymbol(ticker);
      if (!listing) return [];
      return [{ ...toView(makeInstrument(listing.symbol, row.isEtf === true ? "etf" : "equity", listing.venue, name)), exchangeLabel: exchange, origin: "search" }];
    }).slice(0, 20);
  }
  const listing = await secDirectory();
  const words = term.split(/\s+/).filter(Boolean);
  return listing.filter((row) => eligible(row) && (query.cik ? row.cik === query.cik
    : row.symbol.startsWith(term) || row.symbol.replace("-", ".") === term || words.every((word) => row.name.toUpperCase().includes(word))))
    .sort((a, b) => Number(b.symbol === term) - Number(a.symbol === term) || Number(b.symbol.startsWith(term)) - Number(a.symbol.startsWith(term)))
    .slice(0, 20).map(fromSec);
}
