import { createClient } from "@supabase/supabase-js";
import type { FinancialFact } from "@/lib/research-types";
import { SEC_DIRECTORY, type SecListing } from "./sec";

export function researchDatabase() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.RESEARCH_SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return undefined;
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: (url, options) => fetch(url, { ...options, signal: AbortSignal.timeout(12_000) }) },
  });
}

export async function readSnapshot(id: string, listing: SecListing): Promise<{ facts: FinancialFact[]; retrievedAt: string } | undefined> {
  const db = researchDatabase();
  if (!db) return undefined;
  const { data, error } = await db.from("research_snapshots").select("retrieved_at,payload")
    .eq("instrument_id", id).eq("dataset", "sec-companyfacts")
    .eq("source_url", factsUrl(listing)).order("retrieved_at", { ascending: false }).limit(1).maybeSingle();
  if (error) console.warn("Company research snapshot read failed", error.code);
  if (data && Array.isArray(data.payload)) return { facts: data.payload, retrievedAt: data.retrieved_at };
}

function factsUrl(listing: SecListing) {
  return `https://data.sec.gov/api/xbrl/companyfacts/CIK${listing.cik}.json`;
}

export async function saveSnapshot(id: string, listing: SecListing, facts: FinancialFact[], retrievedAt: string) {
  const db = researchDatabase();
  if (!db) return;
  const { error: registryError } = await db.from("research_instruments").upsert({
    instrument_id: id, venue: "us", symbol: id.slice(3), company_name: listing.name, exchange: listing.exchange, sec_cik: listing.cik,
    source_url: SEC_DIRECTORY, observed_at: retrievedAt,
  });
  if (registryError) {
    console.warn("Company research registry write failed", registryError.code);
    return;
  }
  const { error } = await db.from("research_snapshots").insert({
    instrument_id: id, dataset: "sec-companyfacts", retrieved_at: retrievedAt, source_url: factsUrl(listing), payload: facts,
  });
  if (error && error.code !== "23505") console.warn("Company research snapshot write failed", error.code);
}
