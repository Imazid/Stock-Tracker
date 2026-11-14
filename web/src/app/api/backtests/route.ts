import { jsonError, rateLimited } from "@/server/http/respond";
import { BacktestRequestError, decodeInputs, runBacktest } from "@/server/strategy/backtest";

// POST { spec, config?, window?, benchmark?, asOf? } → a full backtest on real history.
// Running a simulation is separate from saving the completed report to an account.
export async function POST(request: Request) {
  const limited = rateLimited(request, 20);
  if (limited) return limited;
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "invalid", "Send a JSON body.");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) return jsonError(400, "invalid", "Send a JSON object.");
  const now = Date.now();
  try {
    const inputs = decodeInputs(body as Record<string, unknown>, now);
    return Response.json(await runBacktest(inputs, now), { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof BacktestRequestError) return jsonError(error.status, error.code, error.message, error.details);
    throw error;
  }
}
