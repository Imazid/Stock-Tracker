import { timingSafeEqual } from "node:crypto";
import { json, jsonError } from "@/server/http/respond";
import { runCompanyAlerts } from "@/server/research/alerts";

export const runtime = "nodejs";
export const maxDuration = 120;

export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET;
  const header = request.headers.get("authorization");
  const received = Buffer.from(header ?? "");
  const expected = Buffer.from(`Bearer ${secret ?? ""}`);
  if (!secret || received.length !== expected.length || !timingSafeEqual(received, expected)) {
    return jsonError(401, "unauthenticated", "Scheduler authorization required.");
  }
  try {
    return json(await runCompanyAlerts());
  } catch {
    return jsonError(503, "unavailable", "The alert batch could not be processed.");
  }
}
