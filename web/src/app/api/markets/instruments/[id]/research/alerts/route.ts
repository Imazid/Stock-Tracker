import { instrumentID } from "@engine/market.ts";
import { COMPANY_ALERT_KINDS, type CompanyAlertKind } from "@/lib/research-alert-types";
import { bearerSupabase, serverSupabase } from "@/lib/supabase/server";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { parseInstrumentID } from "@/server/market/instruments";
import { fmpConfigured } from "@/server/research/licensed";
import { secConfigured } from "@/server/research/sec";
import { companyAlertWorkerConfigured } from "@/server/research/storage";

const fields = "id,kind,threshold,currency,created_at,last_checked_at,last_problem";
type Context = { params: Promise<{ id: string }> };

async function handle(request: Request, context: Context) {
  const limited = rateLimited(request, 35);
  if (limited) return limited;
  const authorization = request.headers.get("authorization");
  const token = authorization === null ? undefined : /^Bearer\s+(\S+)$/i.exec(authorization)?.[1];
  if (authorization !== null && !token) return jsonError(401, "unauthenticated", "Sign in to manage company alerts.");
  const db = token ? bearerSupabase(token) : await serverSupabase();
  if (!db) return jsonError(503, "feature_disabled", "Accounts are unavailable.");
  const { data: { user } } = await db.auth.getUser(token);
  if (!user) return jsonError(401, "unauthenticated", "Sign in to manage company alerts.");

  let id: string;
  let currency: string;
  try {
    const instrument = parseInstrumentID((await context.params).id);
    if (instrument.venue === "crypto") return jsonError(400, "invalid", "Choose a company or fund listing.");
    id = instrumentID(instrument);
    currency = instrument.currency;
  } catch {
    return jsonError(400, "invalid", "Choose a valid company listing.");
  }

  const monitoring = companyAlertWorkerConfigured();
  const availableKinds = monitoring ? COMPANY_ALERT_KINDS.filter((kind) => {
    if (kind === "volume_above") return false;
    if (kind === "news") return fmpConfigured() && process.env.RESEARCH_FMP_ALERTS === "true";
    if (kind === "filing" || kind === "insider") return id.startsWith("us:") && secConfigured();
    return true;
  }) : [];
  if (request.method === "GET") {
    const alerts = await db.from("company_research_alerts").select(fields).eq("user_id", user.id)
      .eq("instrument_id", id).order("created_at", { ascending: false }).limit(100);
    if (alerts.error) return jsonError(503, "unavailable", "Alerts could not be loaded.");
    const ids = alerts.data.map((alert) => alert.id);
    if (!ids.length) return json({ alerts: [], events: [], monitoring, availableKinds });
    const events = await db.from("company_research_alert_events").select("id,title,url,occurred_at")
      .eq("user_id", user.id).in("alert_id", ids).order("occurred_at", { ascending: false }).order("id", { ascending: false }).limit(30);
    if (events.error) return jsonError(503, "unavailable", "Alert history could not be loaded.");
    return json({ alerts: alerts.data, events: events.data, monitoring, availableKinds });
  }

  const body = await request.json().catch(() => null);
  if (!body) return jsonError(400, "invalid", "Choose an alert and try again.");
  if (request.method === "DELETE") {
    if (typeof body.id !== "string" || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(body.id)) {
      return jsonError(400, "invalid", "Choose an alert to remove.");
    }
    const { error } = await db.from("company_research_alerts").delete().eq("id", body.id).eq("instrument_id", id).eq("user_id", user.id);
    return error ? jsonError(503, "unavailable", "The alert could not be removed.") : json({ ok: true });
  }

  const kind = body.kind as CompanyAlertKind;
  const price = kind === "price_above" || kind === "price_below";
  const needsThreshold = price || kind === "volume_above";
  if (!COMPANY_ALERT_KINDS.includes(kind) || (needsThreshold && (typeof body.threshold !== "number" ||
    !Number.isFinite(body.threshold) || body.threshold <= 0 || body.threshold > 1e15))) {
    return jsonError(400, "invalid", "Choose a supported rule and a positive threshold if required.");
  }
  if (!monitoring) return jsonError(503, "feature_disabled", "Scheduled checks are unavailable.");
  if (!availableKinds.includes(kind)) return jsonError(503, "feature_disabled", "No alert feed is configured for this rule and listing.");

  const { error } = await db.from("company_research_alerts").insert({
    user_id: user.id, instrument_id: id, kind, threshold: needsThreshold ? body.threshold : null, currency: price ? currency : null,
  });
  if (error?.code === "23514") return jsonError(409, "limit", "The alert limit was reached or the rule did not pass validation.");
  if (error?.code === "23505") return jsonError(409, "duplicate", "This alert already exists.");
  return error ? jsonError(503, "unavailable", "The alert could not be saved.") : json({ ok: true });
}

export const GET = handle;
export const POST = handle;
export const DELETE = handle;
