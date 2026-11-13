import { StrategyParser } from "@studio/parser.ts";
import { ruleLines, validate } from "@engine/strategy.ts";
import { jsonError, rateLimited } from "@/server/http/respond";

// POST { text } → a draft strategy from plain English, using the deterministic parser (no
// language model): fixed rules map phrases to indicators, symbols and limits, and everything
// it assumed is listed. The draft still has to pass the validator before it can run.
export async function POST(request: Request) {
  const limited = rateLimited(request, 60);
  if (limited) return limited;
  const body = (await request.json().catch(() => undefined)) as { text?: unknown } | undefined;
  const text = typeof body?.text === "string" ? body.text.trim() : "";
  if (text === "") return jsonError(400, "invalid", "Describe the strategy in a sentence or two.");
  if (text.length > 1_000) return jsonError(400, "invalid", "Keep the description under 1,000 characters.");
  const parsed = StrategyParser.parse(text);
  return Response.json({ ...parsed, issues: validate(parsed.draft.spec), ruleLines: ruleLines(parsed.draft.spec) }, { headers: { "Cache-Control": "no-store" } });
}
