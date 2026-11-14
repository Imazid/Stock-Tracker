import { COIN_IDS } from "../_shared/market/coingecko.ts";
import { cryptoFactsRefreshMs, type CryptoFacts } from "../_shared/market/crypto_facts_types.ts";
import { isRecord, positiveNumber } from "../_shared/market/provider.ts";

const platformNames = new Map([
  ["ethereum", "Ethereum"], ["polygon-pos", "Polygon PoS"], ["arbitrum-one", "Arbitrum One"],
  ["binance-smart-chain", "BNB Smart Chain"], ["optimistic-ethereum", "Optimism"],
  ["avalanche", "Avalanche"], ["solana", "Solana"], ["base", "Base"], ["fantom", "Fantom"],
]);

export const cryptoCoinID = (symbol: string): string | undefined => symbol === "POL" ? "polygon-ecosystem-token" : COIN_IDS.get(symbol);

function text(value: unknown, max: number): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= max && !/[\p{C}<>]/u.test(value)
    ? value.trim() || undefined : undefined;
}

function instant(value: unknown, now: number): string | undefined {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return;
  const ms = Date.parse(value);
  if (Number.isFinite(ms) && ms <= now + 5 * 60_000) return new Date(ms).toISOString();
}

function day(value: unknown): string | undefined {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return;
  const ms = Date.parse(value);
  if (Number.isFinite(ms) && new Date(ms).toISOString().slice(0, 10) === value) return value;
}

function safeLinks(input: unknown, limit: number): string[] {
  if (!Array.isArray(input)) return [];
  const links = new Set<string>();
  for (const value of input.slice(0, 20)) {
    if (typeof value !== "string" || value.length > 500) continue;
    try {
      const url = new URL(value);
      if (url.protocol !== "https:" || !url.hostname.includes(".") || url.username || url.password || url.port) continue;
      links.add(url.href);
      if (links.size === limit) break;
    } catch {
      continue;
    }
  }
  return [...links];
}

function description(raw: unknown): string | undefined {
  if (!isRecord(raw) || typeof raw.en !== "string") return;
  const entities = new Map([["amp", "&"], ["quot", '"'], ["#39", "'"], ["apos", "'"], ["nbsp", " "], ["lt", "<"], ["gt", ">"]]);
  const plain = raw.en.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "").replace(/<[^>]*>/g, " ")
    .replace(/&([a-zA-Z0-9#]+);/g, (all, key: string) => entities.get(key) ?? all)
    .replace(/\p{C}/gu, " ").replace(/\s+/g, " ").replace(/\s+([.,;:!?])/g, "$1").trim();
  if (!plain) return;
  if (plain.length <= 420) return plain;
  const limit = plain.lastIndexOf(" ", 416);
  return `${plain.slice(0, limit > 320 ? limit : 416)}…`;
}

export function decodeCryptoFacts(raw: unknown, symbol: string, id: string, now: number): CryptoFacts | undefined {
  if (!isRecord(raw) || raw.id !== id || typeof raw.symbol !== "string" || raw.symbol.toUpperCase() !== symbol) return;
  const name = text(raw.name, 80);
  if (!name) return;
  const market = isRecord(raw.market_data) ? raw.market_data : {};
  const amount = (key: string) => {
    const item = market[key];
    return isRecord(item) ? positiveNumber(item.usd) : undefined;
  };
  const links = isRecord(raw.links) ? raw.links : {};
  const slug = typeof raw.web_slug === "string" && /^[a-z0-9-]{1,80}$/.test(raw.web_slug) ? raw.web_slug : id;
  const contracts = isRecord(raw.platforms) ? raw.platforms : {};
  const platforms = Object.entries(contracts).flatMap(([id, value]) => {
    if (!/^[a-z0-9-]{1,64}$/.test(id) || typeof value !== "string" || !/^[a-zA-Z0-9:._-]{2,160}$/.test(value)) return [];
    const name = platformNames.get(id) ?? id.split("-").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ");
    return [{ id, name, contract: value }];
  }).sort((a, b) => Number(b.id === raw.asset_platform_id) - Number(a.id === raw.asset_platform_id) || a.name.localeCompare(b.name));
  const athDate = isRecord(market.ath_date) ? instant(market.ath_date.usd, now) : undefined;
  const rank = positiveNumber(raw.market_cap_rank);
  const facts: CryptoFacts = {
    id, symbol, name, sourceURL: `https://www.coingecko.com/en/coins/${slug}`,
    observedAt: instant(market.last_updated, now),
    rank: Number.isSafeInteger(rank) ? rank : undefined,
    marketCap: amount("market_cap"),
    fullyDilutedValuation: amount("fully_diluted_valuation"),
    volume24h: amount("total_volume"),
    high24h: amount("high_24h"), low24h: amount("low_24h"),
    circulatingSupply: positiveNumber(market.circulating_supply),
    totalSupply: positiveNumber(market.total_supply),
    maxSupply: positiveNumber(market.max_supply),
    unlimitedSupply: market.max_supply_infinite === true && positiveNumber(market.max_supply) === undefined,
    allTimeHigh: amount("ath"), allTimeHighDate: athDate?.slice(0, 10),
    launchedOn: day(raw.genesis_date), about: description(raw.description), homepage: safeLinks(links.homepage, 1)[0],
    explorers: safeLinks(links.blockchain_site, 3), platforms,
  };
  if (facts.marketCap === undefined && facts.volume24h === undefined && facts.circulatingSupply === undefined &&
      !facts.launchedOn && !facts.about && !facts.homepage && facts.explorers.length === 0 && platforms.length === 0) return;
  return facts;
}

const cache = new Map<string, { until: number; pending: Promise<CryptoFacts | undefined> }>();

export function cachedCryptoFacts(symbol: string, now: number, key?: string, paidKey?: string): Promise<CryptoFacts | undefined> {
  const id = cryptoCoinID(symbol);
  if (!id) return Promise.resolve(undefined);
  const cached = cache.get(symbol);
  if (cached && cached.until > now) return cached.pending;
  const request = async () => {
    const host = paidKey ? "pro-api.coingecko.com" : "api.coingecko.com";
    const url = new URL(`https://${host}/api/v3/coins/${id}`);
    url.search = "localization=false&tickers=false&market_data=true&community_data=false&developer_data=false&sparkline=false";
    const headers = new Headers({ accept: "application/json" });
    if (paidKey) headers.set("x-cg-pro-api-key", paidKey);
    else if (key) headers.set("x-cg-demo-api-key", key);
    const reply = await fetch(url, { headers, redirect: "error", signal: AbortSignal.timeout(5_000) });
    if (!reply.ok) {
      await reply.body?.cancel().catch(() => {});
      return;
    }
    return decodeCryptoFacts(await reply.json(), symbol, id, now);
  };
  const entry = { until: now + cryptoFactsRefreshMs, pending: request().catch(() => undefined) };
  cache.set(symbol, entry);
  void entry.pending.then((value) => { if (!value) entry.until = now + 15_000; });
  return entry.pending;
}
