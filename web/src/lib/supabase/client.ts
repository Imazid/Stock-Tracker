"use client";

import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import { SUPABASE_ANON_KEY, SUPABASE_URL, supabaseConfigured } from "@/lib/env";

let client: SupabaseClient | undefined;

/** The browser client, or undefined when accounts aren't configured. */
export function browserSupabase(): SupabaseClient | undefined {
  if (!supabaseConfigured) return undefined;
  client ??= createBrowserClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  return client;
}
