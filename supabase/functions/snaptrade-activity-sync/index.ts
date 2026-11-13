import { type SnapTradeProxyDeps } from "../_shared/snaptrade/proxy.ts";
import { SealedSnapTradeStore } from "../_shared/secure/credentials.ts";
import { credentialTable, serviceClient } from "../_shared/secure/edge.ts";
import { parseKeyring } from "../_shared/secure/envelope.ts";
import { errorResponse, HttpError, logEvent, ok, sameSecret } from "../_shared/server/http.ts";

import { syncSnapTradeActivities } from "./worker.ts";

Deno.serve(async (request) => {
  try {
    if (request.method !== "POST") throw new HttpError(405, "method_not_allowed", "Send a POST request.");
    const secret = Deno.env.get("SNAPTRADE_ACTIVITY_SYNC_SECRET") ?? "";
    if (secret.length < 32 || !sameSecret(secret, request.headers.get("x-scheduler-secret") ?? "")) {
      throw new HttpError(401, "unauthorized", "Not allowed.");
    }
    const admin = serviceClient();
    const clientId = Deno.env.get("SNAPTRADE_CLIENT_ID") ?? "";
    const consumerKey = Deno.env.get("SNAPTRADE_CONSUMER_KEY") ?? "";
    if (!clientId || !consumerKey) throw new HttpError(503, "unavailable", "Broker activity sync is not configured.");
    const keyring = await parseKeyring(Deno.env.get("CREDENTIAL_KEKS"), Deno.env.get("CREDENTIAL_ACTIVE_KEK"));
    const deps: SnapTradeProxyDeps = {
      config: { clientId, consumerKey, timeoutMs: 12_000 },
      store: new SealedSnapTradeStore(credentialTable(admin), keyring),
      fetch,
      now: Date.now,
    };
    const summary = await syncSnapTradeActivities(admin, deps);
    logEvent("snaptrade_activity_sync", summary);
    return ok(summary);
  } catch (error) {
    const response = errorResponse(error);
    logEvent("snaptrade_activity_sync_failed", { status: response.status });
    return response;
  }
});
