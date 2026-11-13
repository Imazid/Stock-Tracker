// CoinGecko: aggregate crypto prices across many exchanges. An aggregate is indicative —
// it isn't a price any single venue would fill at. Without a Demo key CoinGecko starts
// answering 429 after a handful of calls a minute; the cache absorbs most of that.

import type { Instrument } from "@engine/market.ts";
import { getJSON, UpstreamError } from "./http";

export const COINGECKO_SOURCE = "CoinGecko aggregate";

// Only coins we can price are offered in search (same rule as the iPhone app).
export const COINGECKO_IDS: Record<string, string> = {
  BTC: "bitcoin", ETH: "ethereum", SOL: "solana", ADA: "cardano", BNB: "binancecoin", XRP: "ripple",
  DOGE: "dogecoin", DOT: "polkadot", MATIC: "matic-network", LINK: "chainlink", AVAX: "avalanche-2",
  UNI: "uniswap", LTC: "litecoin", ATOM: "cosmos",
};

export const COIN_NAMES: Record<string, string> = {
  BTC: "Bitcoin", ETH: "Ethereum", SOL: "Solana", ADA: "Cardano", BNB: "BNB", XRP: "XRP", DOGE: "Dogecoin",
  DOT: "Polkadot", MATIC: "Polygon", LINK: "Chainlink", AVAX: "Avalanche", UNI: "Uniswap", LTC: "Litecoin", ATOM: "Cosmos",
};

export interface CoinGeckoQuote {
  last: number;
  changePct?: number;
  volume24hUSD?: number;
  observedAt: number;
}

export async function coinGeckoQuote(instrument: Instrument): Promise<CoinGeckoQuote> {
  const id = COINGECKO_IDS[instrument.symbol];
  if (!id) throw new UpstreamError("CoinGecko isn't set up for that coin", 404);
  const key = process.env.COINGECKO_API_KEY;
  const url = `https://api.coingecko.com/api/v3/simple/price?ids=${id}&vs_currencies=usd&include_24hr_change=true&include_24hr_vol=true&include_last_updated_at=true`;
  const body = (await getJSON(url, { label: "CoinGecko", headers: key ? { "x-cg-demo-api-key": key } : {} })) as Record<string, {
    usd?: number; usd_24h_change?: number; usd_24h_vol?: number; last_updated_at?: number;
  }>;
  const row = body[id];
  if (!row || typeof row.usd !== "number" || !(row.usd > 0) || typeof row.last_updated_at !== "number") {
    throw new UpstreamError("CoinGecko has no current price for that coin", 404);
  }
  return {
    last: row.usd,
    changePct: typeof row.usd_24h_change === "number" ? row.usd_24h_change : undefined,
    volume24hUSD: typeof row.usd_24h_vol === "number" ? row.usd_24h_vol : undefined,
    observedAt: row.last_updated_at * 1000,
  };
}
