// Saved strategy versions. There's no strategies table in the committed database schema yet,
// so versions are kept in this browser only — and the page says so. Every access is guarded:
// storage can be missing or blocked.

import type { StrategySpec } from "@engine/strategy.ts";
import { uuid } from "@/lib/uuid";

const KEY = "st-strategy-versions-v1";

export interface SavedVersion {
  id: string;
  name: string;
  version: number;
  savedAt: string;
  spec: StrategySpec;
}

export function readVersions(): SavedVersion[] {
  try {
    const raw = localStorage.getItem(KEY);
    const parsed = raw ? (JSON.parse(raw) as unknown) : [];
    return Array.isArray(parsed) ? (parsed as SavedVersion[]).filter((v) => v && typeof v.name === "string" && v.spec) : [];
  } catch {
    return [];
  }
}

export function saveVersion(spec: StrategySpec): SavedVersion[] | undefined {
  try {
    const all = readVersions();
    const name = spec.title.trim() || "Untitled strategy";
    const version = 1 + Math.max(0, ...all.filter((v) => v.name === name).map((v) => v.version));
    const next = [{ id: uuid(), name, version, savedAt: new Date().toISOString(), spec }, ...all].slice(0, 100);
    localStorage.setItem(KEY, JSON.stringify(next));
    return next;
  } catch {
    return undefined;
  }
}

export function deleteVersion(id: string): SavedVersion[] {
  try {
    const next = readVersions().filter((v) => v.id !== id);
    localStorage.setItem(KEY, JSON.stringify(next));
    return next;
  } catch {
    return readVersions();
  }
}
