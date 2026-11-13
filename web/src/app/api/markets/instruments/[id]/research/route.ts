import { RESEARCH_SECTIONS, type ResearchSection } from "@/lib/research-types";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { BadInstrumentError, parseInstrumentID } from "@/server/market/instruments";
import { getResearch, parseFilters, ResearchInputError } from "@/server/research/service";

export const runtime = "nodejs";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const limited = rateLimited(request, 60);
  if (limited) return limited;
  const search = new URL(request.url).searchParams;
  const section = (search.get("section") ?? "overview") as ResearchSection;
  if (!RESEARCH_SECTIONS.includes(section)) return jsonError(400, "invalid", "Choose a supported research section.");
  try {
    const instrument = parseInstrumentID((await params).id);
    return json(await getResearch(instrument, section, parseFilters(search)), 15);
  } catch (error) {
    if (error instanceof ResearchInputError || error instanceof BadInstrumentError || error instanceof URIError) {
      return jsonError(400, "invalid", error.message);
    }
    console.error("Company research request failed", error instanceof Error ? error.name : "Unknown");
    return jsonError(503, "unavailable", "Company research could not be loaded.");
  }
}
