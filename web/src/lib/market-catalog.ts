import { catalogInstruments } from "../../../supabase/functions/_shared/trading/catalog.ts";
import { makeInstrument } from "../../../supabase/functions/_shared/trading/market.ts";

// Listings used in the portfolio benchmark and iPhone onboarding.
export const marketCatalog = [
  ...catalogInstruments,
  makeInstrument("IVV", "etf", "us", "iShares Core S&P 500 ETF"),
  makeInstrument("STW", "etf", "asx", "S&P/ASX 200 ETF"),
  makeInstrument("VAS", "etf", "asx", "Vanguard Australian Shares"),
  makeInstrument("VGS", "etf", "asx", "Vanguard MSCI International Shares"),
  makeInstrument("IVV", "etf", "asx", "iShares S&P 500 ETF"),
  makeInstrument("NDQ", "etf", "asx", "Betashares Nasdaq 100 ETF"),
  makeInstrument("A200", "etf", "asx", "Betashares Australia 200 ETF"),
];
