// Edge Function plumbing shared by the secret-custody functions (snaptrade-proxy, ai-proxy).
// Deno-only: imports supabase-js from npm. The tested logic lives in the pure modules.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.4";
import { CredentialConflictError, type CredentialRow, type CredentialTable } from "./credentials.ts";

export const JSON_HEADERS = { "Content-Type": "application/json", "Cache-Control": "no-store" };

export function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export function errorResponse(status: number, code: string, message: string): Response {
  return jsonResponse(status, { error: { code, message } });
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

/** Service-role client. Never leaves the function; never sees a user token. */
export function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Resolves the signed-in user from the request's bearer token by asking Supabase Auth.
 * This supports both legacy and asymmetric project signing keys.
 */
export async function authenticatedUserId(req: Request, admin: SupabaseClient): Promise<string | null> {
  const header = req.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) return null;
  const { data, error } = await admin.auth.getUser(match[1]);
  if (error || !data.user) return null;
  return data.user.id;
}

export async function readJson(req: Request, maxBytes = 64_000): Promise<unknown> {
  const text = await req.text();
  if (text.length > maxBytes) throw new RangeError("body too large");
  return text ? JSON.parse(text) : {};
}

/** supabase-js binding of the vault's table interface. */
export function credentialTable(admin: SupabaseClient): CredentialTable {
  const columns = "id,user_id,purpose,provider,external_ref,sealed,kek_id";
  return {
    async findActive(userId, purpose, provider) {
      const { data, error } = await admin
        .from("secure_credentials")
        .select(columns)
        .eq("user_id", userId)
        .eq("purpose", purpose)
        .eq("provider", provider)
        .is("revoked_at", null)
        .maybeSingle();
      if (error) throw new Error(`secure_credentials read failed: ${error.code}`);
      return (data as CredentialRow | null) ?? null;
    },
    async insert(row) {
      const { data, error } = await admin.from("secure_credentials").insert(row).select(columns).single();
      if (error) {
        if (error.code === "23505") throw new CredentialConflictError();
        throw new Error(`secure_credentials insert failed: ${error.code}`);
      }
      return data as CredentialRow;
    },
    async revoke(id) {
      const { error } = await admin.from("secure_credentials").update({ revoked_at: new Date().toISOString() }).eq("id", id);
      if (error) throw new Error(`secure_credentials revoke failed: ${error.code}`);
    },
    async logEvent({ userId, credentialId, action, provider }) {
      const { error } = await admin
        .from("credential_events")
        .insert({ user_id: userId, credential_id: credentialId, action, provider });
      if (error) throw new Error(`credential_events insert failed: ${error.code}`);
    },
  };
}
