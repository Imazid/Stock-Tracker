// Named groups of well-known, liquid instruments. A port of `UniverseCatalog` in
// TradingCore/Sources/TradingCore/Templates.swift. It is used to fill in what a
// hand-written or AI-drafted strategy left out of an asset (see `decodeInstrument`).
//
// Only types are imported from market.ts, so the two files can refer to each other.

import type { AssetClass, Instrument, Venue } from "./market.ts";

const CURRENCY: Record<Venue, string> = {
  us: "USD", asx: "AUD", crypto: "USD", lse: "GBP", xetra: "EUR", euronextParis: "EUR", euronextAmsterdam: "EUR", six: "CHF",
  tse: "JPY", hkex: "HKD", sgx: "SGD", krx: "KRW", nse: "INR",
};

function make(symbol: string, name: string, assetClass: AssetClass, venue: Venue): Instrument {
  return { symbol, name, assetClass, venue, currency: CURRENCY[venue] };
}
const on = (venue: Venue, symbol: string, name: string) => make(symbol, name, "equity", venue);
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
    etf("XLK", "Technology Sector ETF"), etf("IVV", "iShares Core S&P 500 ETF"),
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
  asxETFs: [
    make("STW", "S&P/ASX 200 ETF", "etf", "asx"),
    make("VAS", "Vanguard Australian Shares", "etf", "asx"),
    make("VGS", "Vanguard MSCI International Shares", "etf", "asx"),
    make("IVV", "iShares S&P 500 ETF", "etf", "asx"),
    make("NDQ", "Betashares Nasdaq 100 ETF", "etf", "asx"),
    make("A200", "Betashares Australia 200 ETF", "etf", "asx"),
  ],
  ukBlueChips: [
    on("lse", "AZN", "AstraZeneca"), on("lse", "SHEL", "Shell"), on("lse", "HSBA", "HSBC Holdings"), on("lse", "ULVR", "Unilever"),
    on("lse", "BP", "BP"), on("lse", "GSK", "GSK"), on("lse", "RIO", "Rio Tinto"), on("lse", "BARC", "Barclays"),
    on("lse", "LLOY", "Lloyds Banking Group"), on("lse", "VOD", "Vodafone"),
  ],
  germanBlueChips: [
    on("xetra", "SAP", "SAP"), on("xetra", "SIE", "Siemens"), on("xetra", "ALV", "Allianz"), on("xetra", "DTE", "Deutsche Telekom"),
    on("xetra", "MBG", "Mercedes-Benz Group"), on("xetra", "BMW", "BMW"), on("xetra", "BAS", "BASF"), on("xetra", "ADS", "Adidas"),
  ],
  frenchBlueChips: [
    on("euronextParis", "MC", "LVMH"), on("euronextParis", "OR", "L'Oréal"), on("euronextParis", "TTE", "TotalEnergies"),
    on("euronextParis", "SAN", "Sanofi"), on("euronextParis", "AIR", "Airbus"), on("euronextParis", "BNP", "BNP Paribas"),
  ],
  dutchBlueChips: [
    on("euronextAmsterdam", "ASML", "ASML Holding"), on("euronextAmsterdam", "INGA", "ING Groep"),
    on("euronextAmsterdam", "AD", "Ahold Delhaize"), on("euronextAmsterdam", "HEIA", "Heineken"), on("euronextAmsterdam", "PRX", "Prosus"),
  ],
  /** The largest euro-listed companies across Frankfurt, Paris and Amsterdam (one currency). */
  euroBlueChips: [
    on("euronextAmsterdam", "ASML", "ASML Holding"), on("xetra", "SAP", "SAP"), on("euronextParis", "MC", "LVMH"),
    on("xetra", "SIE", "Siemens"), on("euronextParis", "TTE", "TotalEnergies"), on("xetra", "ALV", "Allianz"),
    on("euronextParis", "OR", "L'Oréal"), on("euronextParis", "AIR", "Airbus"),
  ],
  swissBlueChips: [
    on("six", "NESN", "Nestlé"), on("six", "NOVN", "Novartis"), on("six", "ROG", "Roche"), on("six", "UBSG", "UBS Group"),
    on("six", "ABBN", "ABB"),
  ],
  japanBlueChips: [
    on("tse", "7203", "Toyota Motor"), on("tse", "6758", "Sony Group"), on("tse", "8306", "Mitsubishi UFJ Financial"),
    on("tse", "9984", "SoftBank Group"), on("tse", "6861", "Keyence"), on("tse", "7974", "Nintendo"),
  ],
  hongKongBlueChips: [
    on("hkex", "0700", "Tencent Holdings"), on("hkex", "9988", "Alibaba Group"), on("hkex", "0005", "HSBC Holdings"),
    on("hkex", "1299", "AIA Group"), on("hkex", "3690", "Meituan"), on("hkex", "0388", "Hong Kong Exchanges and Clearing"),
  ],
  singaporeBlueChips: [
    on("sgx", "D05", "DBS Group"), on("sgx", "O39", "OCBC"), on("sgx", "U11", "United Overseas Bank"), on("sgx", "Z74", "Singtel"),
  ],
  koreaBlueChips: [
    on("krx", "005930", "Samsung Electronics"), on("krx", "000660", "SK hynix"), on("krx", "035420", "NAVER"),
    on("krx", "005380", "Hyundai Motor"),
  ],
  indiaBlueChips: [
    on("nse", "RELIANCE", "Reliance Industries"), on("nse", "TCS", "Tata Consultancy Services"), on("nse", "HDFCBANK", "HDFC Bank"),
    on("nse", "INFY", "Infosys"), on("nse", "ICICIBANK", "ICICI Bank"),
  ],
};

/** Every instrument the catalog knows, US and crypto first. */
export const catalogInstruments: Instrument[] = (() => {
  const seen = new Set<string>();
  const out: Instrument[] = [];
  const c = UniverseCatalog;
  for (const list of [c.technology, c.semiconductors, c.financials, c.healthcare, c.energy, c.otherUS, c.broadETFs,
    c.balancedETFs, c.otherETFs, c.cryptoMajors, c.otherCrypto, c.asxBlueChips, c.asxETFs, c.ukBlueChips, c.germanBlueChips,
    c.frenchBlueChips, c.dutchBlueChips, c.swissBlueChips, c.japanBlueChips, c.hongKongBlueChips, c.singaporeBlueChips,
    c.koreaBlueChips, c.indiaBlueChips]) {
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
