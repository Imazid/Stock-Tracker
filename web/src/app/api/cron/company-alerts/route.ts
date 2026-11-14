import { timingSafeEqual } from "node:crypto";
import { json, jsonError } from "@/server/http/respond";
import { runCompanyAlerts } from "@/server/research/alerts";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;

export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET || process.env.COMPANY_ALERT_CRON_SECRET;
  const header = request.headers.get("authorization");
  const received = Buffer.from(header ?? "");
  const expected = Buffer.from(`Bearer ${secret ?? ""}`);
  if (!secret || received.length !== expected.length || !timingSafeEqual(received, expected)) {
    return jsonError(401, "unauthenticated", "Scheduler authorization required.");
  }
  try {
    const result = await runCompanyAlerts();
    if (result.completed < result.claimed) {
      console.warn("Incomplete company alert batch", result);
      return jsonError(503, "unavailable", "Some alert rules could not be recorded.");
    }
    return json(result);
  } catch {
    return jsonError(503, "unavailable", "The alert batch could not be processed.");
  }
}
