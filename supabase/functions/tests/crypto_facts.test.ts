import { assert, assertEquals } from "jsr:@std/assert@1";
import { cryptoCoinID, decodeCryptoFacts } from "../market-workspace/crypto_facts.ts";

const now = Date.parse("2026-11-15T03:00:00Z");

Deno.test("crypto research keeps the requested token, currency and provider timestamp", () => {
  const row = {
    id: "chainlink", symbol: "link", name: "Chainlink", market_cap_rank: 17, asset_platform_id: "ethereum",
    web_slug: "chainlink", genesis_date: "2017-09-16",
    description: { en: '<p>Network &amp; <a href="javascript:alert(1)">data.</a></p><script>alert(0)</script>' },
    links: {
      homepage: ["javascript:alert(0)", "https://chain.link"],
      blockchain_site: ["https://foo:pass@example.com", "https://etherscan.io/token/0xabc", "https://etherscan.io/token/0xabc"],
    },
    platforms: { "": "", base: "0x123", ethereum: "0xabc", polygon: "bad address", "invalid/": "0x456" },
    market_data: {
      last_updated: "2026-11-15T02:57:20.123Z", market_cap: { usd: 12_000_000, aud: 18_000_000 },
      total_volume: { usd: 87_000 }, circulating_supply: 123_456.5, max_supply: null,
      max_supply_infinite: null, ath: { usd: 50 }, ath_date: { usd: "2021-05-10T04:00:00Z" },
    },
  };
  assertEquals(cryptoCoinID("LINK"), "chainlink");
  assertEquals(cryptoCoinID("POL"), "polygon-ecosystem-token");
  assertEquals(cryptoCoinID("MATIC"), "matic-network");
  assertEquals(cryptoCoinID("constructor"), undefined);
  assertEquals(decodeCryptoFacts(row, "LINK", "uniswap", now), undefined);
  assertEquals(decodeCryptoFacts(row, "UNI", "chainlink", now), undefined);
  const facts = decodeCryptoFacts(row, "LINK", "chainlink", now);
  assert(facts);
  assertEquals(facts.observedAt, "2026-11-15T02:57:20.123Z");
  assertEquals(facts.marketCap, 12_000_000);
  assertEquals(facts.volume24h, 87_000);
  assertEquals(facts.circulatingSupply, 123_456.5);
  assertEquals(facts.allTimeHighDate, "2021-05-10");
  assertEquals(facts.maxSupply, undefined);
  assertEquals(facts.unlimitedSupply, false);
  assertEquals(facts.sourceURL, "https://www.coingecko.com/en/coins/chainlink");
  assertEquals(facts.explorers, ["https://etherscan.io/token/0xabc"]);
  assertEquals(facts.homepage, "https://chain.link/");
  assertEquals(facts.about, "Network & data.");
  assertEquals(facts.platforms, [
    { id: "ethereum", name: "Ethereum", contract: "0xabc" },
    { id: "base", name: "Base", contract: "0x123" },
  ]);
});

Deno.test("crypto research omits bad numbers and future dates and reports an explicitly uncapped supply", () => {
  const raw = {
    id: "ethereum", symbol: "eth", name: "Ethereum", genesis_date: "2017-02-31",
    last_updated: "2026-11-15T02:59:00.000Z",
    platforms: { "": "" },
    market_data: {
      market_cap: { usd: "2000" }, total_volume: { usd: -1 }, circulating_supply: 100,
      max_supply_infinite: true, last_updated: "2026-11-16T02:57:20.123Z",
    },
  };
  const facts = decodeCryptoFacts(raw, "ETH", "ethereum", now);
  assert(facts);
  assertEquals(facts.observedAt, undefined);
  assertEquals(facts.marketCap, undefined);
  assertEquals(facts.volume24h, undefined);
  assertEquals(facts.launchedOn, undefined);
  assertEquals(facts.unlimitedSupply, true);
  assertEquals(facts.platforms, []);
  assertEquals(decodeCryptoFacts({ id: "ethereum", name: "Ethereum", symbol: "ETH" }, "ETH", "ethereum", now), undefined);
});
