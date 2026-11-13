// A day-long cache in front of a dollar-volume source (CoinGecko), with the phone's rule:
// a coin's figure is kept for 24 hours from when it was fetched, and only a real, positive
// figure is kept. A coin with no fresh figure is asked for again; one that still can't be
// found stays unknown. The cache never invents or stretches a figure, and if the store
// can't be read or written the source is simply asked directly.

import type { Instrument } from "../trading/market.ts";
import { instrumentID } from "../trading/market.ts";
import { type DollarVolumeSource, uniqueInstruments } from "./provider.ts";

/** How long a figure is kept: one day, as TradingMarketData.swift keeps it. */
export const VOLUME_TTL_MS = 86_400_000;

export interface VolumeStore {
  /** Figures fetched at or after `notBefore`, keyed by instrument id. */
  read(ids: string[], notBefore: number): Promise<Record<string, number>>;
  write(figures: Record<string, number>, fetchedAt: number, source: string): Promise<void>;
}

const usable = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value > 0;

export class CachedVolumeSource implements DollarVolumeSource {
  readonly #source: DollarVolumeSource;
  readonly #store: VolumeStore;
  readonly #ttlMs: number;
  readonly #name: string;
  readonly #log?: (event: Record<string, unknown>) => void;

  constructor(source: DollarVolumeSource, store: VolumeStore, options: { ttlMs?: number; name?: string; log?: (event: Record<string, unknown>) => void } = {}) {
    this.#source = source;
    this.#store = store;
    this.#ttlMs = options.ttlMs !== undefined && options.ttlMs > 0 ? options.ttlMs : VOLUME_TTL_MS;
    this.#name = options.name ?? "CoinGecko";
    this.#log = options.log;
  }

  async dollarVolume(instruments: Instrument[], now: number): Promise<Record<string, number>> {
    const wanted = uniqueInstruments(instruments);
    if (wanted.length === 0) return {};
    const ids = wanted.map(instrumentID);

    let cached: Record<string, number> = {};
    try {
      const read = await this.#store.read(ids, now - this.#ttlMs);
      for (const id of ids) if (usable(read[id])) cached[id] = read[id];
    } catch {
      cached = {};
      this.#log?.({ event: "volume_cache_read_failed" });
    }
    const missing = wanted.filter((instrument) => cached[instrumentID(instrument)] === undefined);
    this.#log?.({ event: "volume_cache", asked: ids.length, hits: ids.length - missing.length });
    if (missing.length === 0) return cached;

    let fresh: Record<string, number> = {};
    try {
      const answer = await this.#source.dollarVolume(missing, now);
      const asked = new Set(missing.map(instrumentID));
      for (const [id, value] of Object.entries(answer ?? {})) if (asked.has(id) && usable(value)) fresh[id] = value;
    } catch {
      fresh = {};
    }
    if (Object.keys(fresh).length > 0) {
      try {
        await this.#store.write(fresh, now, this.#name);
      } catch {
        this.#log?.({ event: "volume_cache_write_failed" });
      }
    }
    return { ...cached, ...fresh };
  }
}

/** A store that lives as long as the process (tests, and a fallback with no database). */
export function memoryVolumeStore(): VolumeStore & { entries: Map<string, { value: number; at: number; source: string }> } {
  const entries = new Map<string, { value: number; at: number; source: string }>();
  return {
    entries,
    read(ids, notBefore) {
      const out: Record<string, number> = {};
      for (const id of ids) {
        const entry = entries.get(id);
        if (entry && entry.at >= notBefore) out[id] = entry.value;
      }
      return Promise.resolve(out);
    },
    write(figures, fetchedAt, source) {
      for (const [id, value] of Object.entries(figures)) {
        const old = entries.get(id);
        if (!old || old.at <= fetchedAt) entries.set(id, { value, at: fetchedAt, source });
      }
      return Promise.resolve();
    },
  };
}
