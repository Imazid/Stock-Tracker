// Picks the market-data provider for a request from the function's environment.
//
//   TRADING_ALLOW_FIXTURE_DATA   "1" only in test deployments; anything else means no fixtures
//   ALPACA_DATA_KEY_ID           market-data credentials. They are read here, handed to
//   ALPACA_DATA_SECRET           the provider, and never logged, returned or put in a URL.
//   COINGECKO_API_KEY            optional CoinGecko Demo key (a higher rate limit for the
//                                crypto traded-value lookup). Same handling.

import { AlpacaDataProvider } from "./alpaca.ts";
import { CoinGeckoVolumeSource } from "./coingecko.ts";
import { type FixtureData, FixtureDataProvider } from "./fixture.ts";
import type { DollarVolumeSource, MarketDataProvider } from "./provider.ts";
import { CachedVolumeSource, type VolumeStore } from "./volume_cache.ts";

export * from "./provider.ts";
export { AlpacaDataProvider, type AlpacaDataProviderOptions } from "./alpaca.ts";
export { CoinGeckoVolumeSource, type CoinGeckoVolumeSourceOptions } from "./coingecko.ts";
export { type FixtureData, FixtureDataProvider, type FixtureQuote, type FixtureSeries } from "./fixture.ts";
export { CachedVolumeSource, memoryVolumeStore, VOLUME_TTL_MS, type VolumeStore } from "./volume_cache.ts";

export interface ProviderFromEnvOptions {
  /** Canned data a caller asked to run on (from a request body). Honoured only with the flag. */
  fixture?: unknown;
  log?: (event: Record<string, unknown>) => void;
  fetch?: typeof fetch;
  /** Where CoinGecko's traded-value figures are kept for a day. Without one, every snapshot asks again. */
  volumeStore?: VolumeStore;
}

export interface ProviderChoice {
  provider: MarketDataProvider | null;
  /** True only when TRADING_ALLOW_FIXTURE_DATA is exactly "1". */
  allowFixtureData: boolean;
  /** Why there is no provider, in plain English. */
  reason?: string;
}

/**
 * `env` is a lookup such as `(name) => Deno.env.get(name)`.
 *
 * A caller that supplies `fixture` gets fixture data or nothing: it is never quietly
 * switched to real data, and fixtures are never served without the flag.
 */
export function providerFromEnv(env: (name: string) => string | undefined, options: ProviderFromEnvOptions = {}): ProviderChoice {
  const allowFixtureData = env("TRADING_ALLOW_FIXTURE_DATA") === "1";

  if (options.fixture !== undefined) {
    if (!allowFixtureData) return { provider: null, allowFixtureData: false, reason: "Fixture data isn't allowed here." };
    return { provider: new FixtureDataProvider(options.fixture as FixtureData), allowFixtureData };
  }

  const keyId = (env("ALPACA_DATA_KEY_ID") ?? "").trim();
  const secret = (env("ALPACA_DATA_SECRET") ?? "").trim();
  if (keyId !== "" && secret !== "") {
    // Always wired: the key only raises CoinGecko's rate limit, the lookup works without it.
    const coinGecko = new CoinGeckoVolumeSource({ apiKey: env("COINGECKO_API_KEY"), fetch: options.fetch, log: options.log });
    const volumeSource: DollarVolumeSource = options.volumeStore
      ? new CachedVolumeSource(coinGecko, options.volumeStore, { name: "CoinGecko", log: options.log })
      : coinGecko;
    return { provider: new AlpacaDataProvider({ keyId, secret, fetch: options.fetch, log: options.log, volumeSource }), allowFixtureData };
  }

  return { provider: null, allowFixtureData, reason: "Market data isn't configured." };
}
