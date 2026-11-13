// One provider in front of several: each instrument goes to the source that prices its
// market (Alpaca for US shares and crypto, Yahoo Finance for the eleven other exchanges),
// and the answers come back merged. An instrument no configured source prices gets a
// plain reason, never a price from somewhere else.

import { type Instrument, instrumentID, type Timeframe, venueDisplayName } from "../trading/market.ts";
import { type BarsResult, type MarketDataProvider, type QuotesResult, uniqueInstruments } from "./provider.ts";

export class RoutedProvider implements MarketDataProvider {
  readonly name: string;
  readonly #providers: MarketDataProvider[];

  /** The first provider that supports an instrument prices it. */
  constructor(providers: MarketDataProvider[]) {
    this.#providers = providers;
    this.name = providers.map((provider) => provider.name).join("+") || "none";
  }

  supports(instrument: Instrument): boolean {
    return this.#providers.some((provider) => provider.supports(instrument));
  }

  /** Instruments grouped by the provider that prices them; the rest are failures. */
  #route(instruments: Instrument[], failures: Record<string, string>): Map<MarketDataProvider, Instrument[]> {
    const routes = new Map<MarketDataProvider, Instrument[]>();
    for (const instrument of uniqueInstruments(instruments)) {
      const provider = this.#providers.find((candidate) => candidate.supports(instrument));
      if (provider === undefined) {
        failures[instrumentID(instrument)] = `Market data for the ${venueDisplayName(instrument.venue)} isn't configured on the server`;
        continue;
      }
      routes.set(provider, [...(routes.get(provider) ?? []), instrument]);
    }
    return routes;
  }

  async bars(instruments: Instrument[], timeframe: Timeframe, count: number, now: number): Promise<BarsResult> {
    const result: BarsResult = { series: {}, failures: {} };
    const routes = this.#route(instruments, result.failures);
    const answers = await Promise.all([...routes].map(([provider, group]) => provider.bars(group, timeframe, count, now)));
    for (const answer of answers) {
      Object.assign(result.series, answer.series);
      Object.assign(result.failures, answer.failures);
    }
    return result;
  }

  async quotes(instruments: Instrument[], now: number): Promise<QuotesResult> {
    const result: QuotesResult = { quotes: {}, failures: {} };
    const routes = this.#route(instruments, result.failures);
    const answers = await Promise.all([...routes].map(([provider, group]) => provider.quotes(group, now)));
    for (const answer of answers) {
      Object.assign(result.quotes, answer.quotes);
      Object.assign(result.failures, answer.failures);
    }
    return result;
  }

  async dollarVolume(instruments: Instrument[], now: number): Promise<Record<string, number>> {
    const known: Record<string, number> = {};
    const routes = this.#route(instruments, {});
    for (const [provider, group] of routes) {
      if (typeof provider.dollarVolume !== "function") continue;
      try {
        Object.assign(known, await provider.dollarVolume(group, now));
      } catch {
        // Not knowing is an answer.
      }
    }
    return known;
  }
}
