import { decodeStrategySpec, ruleLines, validate, warmupBars } from "@engine/strategy.ts";
import { jsonError, rateLimited } from "@/server/http/respond";

// POST { spec } → the validator's verdict. The same validator runs on the phone, the server
// and in backtests; an AI-drafted strategy gets no special trust.
export async function POST(request: Request) {
  const limited = rateLimited(request, 120);
  if (limited) return limited;
  const body = (await request.json().catch(() => undefined)) as { spec?: unknown } | undefined;
  try {
    const spec = decodeStrategySpec(body?.spec);
    const issues = validate(spec);
    return Response.json({ valid: !issues.some((i) => i.severity === "error"), issues, ruleLines: ruleLines(spec), warmupBars: warmupBars(spec) });
  } catch (error) {
    return jsonError(422, "invalid", error instanceof Error ? error.message : "The strategy couldn't be read.");
  }
}
