import { VENUES } from "@engine/market.ts";
import { ISSUER_LOOKUP_LIMIT } from "@/lib/issuer-classification";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { issuerClassifications } from "@/server/portfolio/issuer-classifications";

export async function GET(request: Request) {
  const limited = rateLimited(request);
  if (limited) return limited;
  const ids = [...new Set(new URL(request.url).searchParams.getAll("id"))];
  if (!ids.length || ids.length > ISSUER_LOOKUP_LIMIT || ids.some((id) => {
    const [venue, symbol, extra] = id.split(":");
    return extra !== undefined || !VENUES.some((value) => value === venue) || !/^[A-Z0-9][A-Z0-9.\-&]{0,19}$/.test(symbol ?? "");
  })) return jsonError(400, "invalid_instruments", `Choose up to ${ISSUER_LOOKUP_LIMIT} supported listing identifiers.`);
  const result = await issuerClassifications(ids);
  return json(result, result.limited ? 0 : 300);
}
