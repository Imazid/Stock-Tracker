// Client-safe twin of the server's toView (no server-only imports).
import { type Instrument, instrumentID, makeInstrument, parseYahooSymbol, venueCurrency, venueDisplayName, venueShortName } from "@engine/market.ts";
import type { InstrumentView } from "@/lib/market-types";

export function toView(instrument: Instrument): InstrumentView {
  return {
    id: instrumentID(instrument),
    symbol: instrument.symbol,
    name: instrument.name,
    assetClass: instrument.assetClass,
    venue: instrument.venue,
    venueName: venueDisplayName(instrument.venue),
    venueShort: venueShortName(instrument.venue),
    currency: instrument.currency || venueCurrency(instrument.venue),
    pair: instrument.venue === "crypto" ? `${instrument.symbol}/USD` : undefined,
  };
}

/** The synced app rows use bare US/ASX symbols and Yahoo suffixes for other venues. */
export function rowToInstrument(row: { symbol: string; name: string; kind: "Stock" | "Crypto"; exchange: string | null }): Instrument {
  const symbol = row.symbol.toUpperCase();
  if (row.kind === "Crypto") return makeInstrument(symbol, "crypto", "crypto", row.name);
  if ((row.exchange ?? "").toUpperCase() === "ASX" || symbol.endsWith(".AX")) {
    return makeInstrument(symbol.replace(/\.AX$/, ""), "equity", "asx", row.name);
  }
  const parsed = parseYahooSymbol(symbol);
  return makeInstrument(parsed?.symbol ?? symbol, "equity", parsed?.venue ?? "us", row.name);
}
