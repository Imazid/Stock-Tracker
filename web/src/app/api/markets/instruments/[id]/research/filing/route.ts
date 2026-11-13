import { json, jsonError, rateLimited } from "@/server/http/respond";
import { BadInstrumentError, parseInstrumentID } from "@/server/market/instruments";
import { filingPassages } from "@/server/research/documents";
import { parseFilters, ResearchInputError } from "@/server/research/service";

export const runtime = "nodejs";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const limited = rateLimited(request, 30);
  if (limited) return limited;
  const search = new URL(request.url).searchParams;
  try {
    const { query, archive } = parseFilters(search);
    if (!query) throw new ResearchInputError("Enter keywords to search within the filing.");
    const instrument = parseInstrumentID((await params).id);
    return json(await filingPassages(instrument, search.get("accession") ?? "", query, archive), 60);
  } catch (error) {
    if (error instanceof ResearchInputError || error instanceof BadInstrumentError || error instanceof URIError) return jsonError(400, "invalid", error.message);
    return jsonError(503, "unavailable", "The filing text could not be retrieved. Open the original filing to read it.");
  }
}
