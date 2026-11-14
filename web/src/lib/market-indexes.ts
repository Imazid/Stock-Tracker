import { type Instrument, makeInstrument } from "@engine/market.ts";

export const marketIndexes: Instrument[] = [
  makeInstrument("^GSPC", "equity", "us", "S&P 500"),
  makeInstrument("^IXIC", "equity", "us", "Nasdaq Composite"),
  makeInstrument("^DJI", "equity", "us", "Dow Jones Industrial Average"),
  makeInstrument("^AXJO", "equity", "asx", "S&P/ASX 200"),
];

export function isMarketIndex(symbol: string): boolean {
  return symbol.startsWith("^");
}
