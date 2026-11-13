// Client-safe twin of the server's toView (no server-only imports).
import { type Instrument, instrumentID, venueCurrency, venueDisplayName, venueShortName } from "@engine/market.ts";
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
