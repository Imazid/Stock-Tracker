import { sha256Hex } from "@engine/sha256.ts";
import type { BacktestResponse } from "@/server/strategy/backtest";

export type BacktestArchive = Omit<BacktestResponse, "chart"> & { schemaVersion: 1; title: string };

export interface SavedBacktestRow {
  id: string;
  title: string;
  engine: string;
  ran_at: string;
  saved_at: string;
}

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0)
      .map(([key, item]) => [key, canonical(item)]));
  }
  return value;
}

// JSONB can reorder every object. Array order is part of the report.
export function backtestFingerprint(result: BacktestResponse["result"]): string {
  return sha256Hex(JSON.stringify(canonical(result))).slice(0, 12);
}
