// POST /functions/v1/snaptrade-proxy   { "operation": "...", "params": { ... } }
//
// The only path from the app to SnapTrade. Secrets (Edge Function secrets, never in the app):
//   SNAPTRADE_CLIENT_ID, SNAPTRADE_CONSUMER_KEY   — SnapTrade partner credentials
//   CREDENTIAL_KEKS, CREDENTIAL_ACTIVE_KEK        — vault key-encryption keys (kid:base64,…)
//   SNAPTRADE_ALLOW_TRADE_CONNECTIONS             — "true" to allow trading portals (default off)
// See supabase/functions/_shared/snaptrade/proxy.ts for the allowlisted operations.

import { handleSnapTradeRequest } from "../_shared/snaptrade/proxy.ts";
import { CredentialConflictError, SealedSnapTradeStore } from "../_shared/secure/credentials.ts";
import { parseKeyring } from "../_shared/secure/envelope.ts";
import {
  authenticatedUserId,
  credentialTable,
  errorResponse,
  jsonResponse,
  readJson,
  serviceClient,
} from "../_shared/secure/edge.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return errorResponse(405, "METHOD_NOT_ALLOWED", "use POST");

  let admin;
  let keyring;
  try {
    admin = serviceClient();
    keyring = await parseKeyring(Deno.env.get("CREDENTIAL_KEKS"), Deno.env.get("CREDENTIAL_ACTIVE_KEK"));
  } catch (error) {
    console.error("snaptrade-proxy misconfigured", (error as Error).name);
    return errorResponse(503, "SERVER_NOT_CONFIGURED", "secure credential storage is not configured");
  }

  const userId = await authenticatedUserId(req, admin);
  if (!userId) return errorResponse(401, "UNAUTHENTICATED", "sign in first");

  let body: unknown;
  try {
    body = await readJson(req);
  } catch {
    return errorResponse(400, "INVALID_JSON", "body must be JSON under 64 KB");
  }

  try {
    const result = await handleSnapTradeRequest(userId, body, {
      config: {
        clientId: Deno.env.get("SNAPTRADE_CLIENT_ID") ?? "",
        consumerKey: Deno.env.get("SNAPTRADE_CONSUMER_KEY") ?? "",
        allowTradeConnections: Deno.env.get("SNAPTRADE_ALLOW_TRADE_CONNECTIONS") === "true",
      },
      store: new SealedSnapTradeStore(credentialTable(admin), keyring),
      fetch,
      now: Date.now,
      async readActivityCache(userId, request) {
        const { data, error } = await admin.rpc("read_snaptrade_activity_cache", {
          p_user: userId, p_account: request.accountId, p_start: request.startDate, p_end: request.endDate,
          p_offset: request.offset, p_snapshot: request.snapshot,
        });
        return error ? null : data;
      },
    });
    return jsonResponse(result.status, result.body);
  } catch (error) {
    if (error instanceof CredentialConflictError) {
      return errorResponse(409, "IDENTITY_IN_USE", "this SnapTrade identity is already linked to an account");
    }
    // Never log request bodies or secrets; the error class is enough to triage.
    console.error("snaptrade-proxy failure", (error as Error).name, (error as Error).message.slice(0, 120));
    return errorResponse(500, "INTERNAL", "unexpected server error");
  }
});
