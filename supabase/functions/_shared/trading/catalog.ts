// Named groups of well-known, liquid instruments. A port of `UniverseCatalog` in
// TradingCore/Sources/TradingCore/Templates.swift. It is used to fill in what a
// hand-written or AI-drafted strategy left out of an asset (see `decodeInstrument`).
//
// Only types are imported from market.ts, so the two files can refer to each other.

import type { AssetClass, Instrument, Venue } from "./market.ts";

function make(symbol: string, name: string, assetClass: AssetClass, venue: Venue): Instrument {
  return { symbol, name, assetClass, venue, currency: venue === "asx" ? "AUD" : "USD" };
}
const us = (symbol: string, name: string) => make(symbol, name, "equity", "us");
const etf = (symbol: string, name: string) => make(symbol, name, "etf", "us");
const coin = (symbol: string, name: string) => make(symbol, name, "crypto", "crypto");
const asx = (symbol: string, name: string) => make(symbol, name, "equity", "asx");

export const UniverseCatalog = {
  technology: [
    us("AAPL", "Apple"), us("MSFT", "Microsoft"), us("NVDA", "NVIDIA"), us("GOOGL", "Alphabet"), us("AMZN", "Amazon"),
    us("META", "Meta Platforms"), us("AVGO", "Broadcom"), us("AMD", "Advanced Micro Devices"),
  ],
  semiconductors: [
    us("NVDA", "NVIDIA"), us("AMD", "Advanced Micro Devices"), us("AVGO", "Broadcom"), us("TSM", "Taiwan Semiconductor"),
    us("QCOM", "Qualcomm"), us("MU", "Micron"),
  ],
  financials: [
    us("JPM", "JPMorgan Chase"), us("BAC", "Bank of America"), us("GS", "Goldman Sachs"), us("MS", "Morgan Stanley"),
    us("V", "Visa"), us("MA", "Mastercard"),
  ],
  healthcare: [
    us("LLY", "Eli Lilly"), us("UNH", "UnitedHealth"), us("JNJ", "Johnson & Johnson"), us("ABBV", "AbbVie"), us("MRK", "Merck"),
  ],
  energy: [us("XOM", "Exxon Mobil"), us("CVX", "Chevron"), us("COP", "ConocoPhillips")],
  otherUS: [
    us("TSLA", "Tesla"), us("NFLX", "Netflix"), us("COST", "Costco"), us("WMT", "Walmart"), us("DIS", "Disney"),
    us("INTC", "Intel"), us("CRM", "Salesforce"), us("ORCL", "Oracle"), us("PLTR", "Palantir"), us("COIN", "Coinbase"),
  ],
  broadETFs: [
    etf("SPY", "S&P 500 ETF"), etf("QQQ", "Nasdaq-100 ETF"), etf("VTI", "Total US Market ETF"), etf("IWM", "Russell 2000 ETF"),
  ],
  balancedETFs: [etf("VTI", "Total US Market ETF"), etf("VXUS", "Total International ETF"), etf("BND", "Total Bond Market ETF")],
  otherETFs: [
    etf("VOO", "S&P 500 ETF"), etf("DIA", "Dow Jones ETF"), etf("GLD", "Gold ETF"), etf("TLT", "20+ Year Treasury ETF"),
    etf("XLK", "Technology Sector ETF"),
  ],
  cryptoMajors: [coin("BTC", "Bitcoin"), coin("ETH", "Ethereum"), coin("SOL", "Solana")],
  otherCrypto: [
    coin("XRP", "XRP"), coin("ADA", "Cardano"), coin("DOGE", "Dogecoin"), coin("AVAX", "Avalanche"), coin("LINK", "Chainlink"),
    coin("LTC", "Litecoin"), coin("DOT", "Polkadot"), coin("UNI", "Uniswap"),
  ],
  asxBlueChips: [
    asx("BHP", "BHP Group"), asx("CBA", "Commonwealth Bank"), asx("CSL", "CSL"), asx("NAB", "National Australia Bank"),
    asx("WBC", "Westpac"), asx("ANZ", "ANZ Group"), asx("WES", "Wesfarmers"), asx("MQG", "Macquarie Group"),
  ],
};

/** Every instrument the catalog knows, US and crypto first. */
export const catalogInstruments: Instrument[] = (() => {
  const seen = new Set<string>();
  const out: Instrument[] = [];
  const c = UniverseCatalog;
  for (const list of [c.technology, c.semiconductors, c.financials, c.healthcare, c.energy, c.otherUS, c.broadETFs,
    c.balancedETFs, c.otherETFs, c.cryptoMajors, c.otherCrypto, c.asxBlueChips]) {
    for (const instrument of list) {
      const id = `${instrument.venue}:${instrument.symbol}`;
      if (!seen.has(id)) {
        seen.add(id);
        out.push(instrument);
      }
    }
  }
  return out;
})();

/**
 * A known instrument by ticker. Where a ticker exists on two venues the US or crypto
 * listing wins unless `preferring` says otherwise.
 */
export function lookupInstrument(symbol: string, preferring?: Venue): Instrument | undefined {
  const upper = symbol.toUpperCase();
  const matches = catalogInstruments.filter((instrument) => instrument.symbol === upper);
  if (preferring !== undefined) {
    const hit = matches.find((instrument) => instrument.venue === preferring);
    if (hit) return hit;
  }
  return matches[0];
}
