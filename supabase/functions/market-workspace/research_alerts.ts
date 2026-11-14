import { Field, HttpError } from "../_shared/server/http.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.49.4";
import { researchListing, researchOrigin } from "./research_report.ts";

const unavailable = () => new HttpError(503, "alerts_unavailable", "Company alerts are temporarily unavailable.");
const methods = { read: "GET", create: "POST", remove: "DELETE" } as const;

export async function mobileCompanyAlertActivity(db: SupabaseClient, userID: string) {
  const events = await db.from("company_research_alert_events")
    .select("id,title,url,occurred_at,company_research_alerts(instrument_id)")
    .eq("user_id", userID)
    .order("occurred_at", { ascending: false })
    .order("id", { ascending: false })
    .limit(50)
    .abortSignal(AbortSignal.timeout(12_000));
  if (events.error) throw unavailable();
  return events.data;
}

export async function mobileCompanyAlerts(
  body: Record<string, unknown>,
  authorization: string,
  origin: string | undefined,
  bypass: string | undefined,
  request: typeof fetch = fetch,
) {
  const id = Field.string(body.instrumentId, "instrumentId", 42);
  researchListing(id);
  const operation = Field.oneOf(body.operation, ["read", "create", "remove"] as const, "operation");
  const mutation = operation === "create" ? {
    kind: Field.string(body.kind, "kind", 20),
    threshold: Field.optionalNumber(body.threshold, "threshold"),
  } : operation === "remove" ? { id: Field.uuid(body.id, "id") } : undefined;
  const resolved = researchOrigin(origin, bypass, unavailable);

  try {
    const result = await request(new URL(`/api/markets/instruments/${encodeURIComponent(id)}/research/alerts`, resolved.web), {
      method: methods[operation],
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        Authorization: authorization,
        "x-vercel-protection-bypass": resolved.bypass,
      },
      body: mutation === undefined ? undefined : JSON.stringify(mutation),
      signal: AbortSignal.timeout(25_000),
      redirect: "error",
    });
    if (!result.headers.get("content-type")?.includes("application/json")) throw unavailable();
    const payload = await result.json();
    if (!result.ok) {
      const code = payload?.error?.code;
      const message = payload?.error?.message;
      if (typeof code === "string" && typeof message === "string") throw new HttpError(result.status, code, message);
      throw unavailable();
    }
    if (operation === "read") {
      if (!Array.isArray(payload?.alerts) || !Array.isArray(payload?.events) ||
          !Array.isArray(payload?.availableKinds) || typeof payload?.monitoring !== "boolean") throw unavailable();
    } else if (payload?.ok !== true) {
      throw unavailable();
    }
    return payload;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw unavailable();
  }
}
