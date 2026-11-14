export type CryptoFacts = {
  id: string;
  symbol: string;
  name: string;
  sourceURL: string;
  observedAt?: string;
  rank?: number;
  marketCap?: number;
  fullyDilutedValuation?: number;
  volume24h?: number;
  high24h?: number;
  low24h?: number;
  circulatingSupply?: number;
  totalSupply?: number;
  maxSupply?: number;
  unlimitedSupply: boolean;
  allTimeHigh?: number;
  allTimeHighDate?: string;
  launchedOn?: string;
  about?: string;
  homepage?: string;
  explorers: string[];
  platforms: { id: string; name: string; contract: string }[];
};

export const cryptoFactsRefreshMs = 5 * 60_000;
export const cryptoFactsStaleMs = 15 * 60_000;
