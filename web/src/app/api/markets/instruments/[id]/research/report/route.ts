import { json, jsonError, rateLimited } from "@/server/http/respond";
import { BadInstrumentError, parseInstrumentID } from "@/server/market/instruments";
import { companyReport } from "@/server/research/report";

export const runtime = "nodejs";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const limited = rateLimited(request, 20);
  if (limited) return limited;
  try {
    const instrument = parseInstrumentID((await params).id);
    if (instrument.venue === "crypto") return jsonError(400, "invalid", "Choose a company or fund listing.");
    return json(await companyReport(instrument), 15);
  } catch (error) {
    if (error instanceof BadInstrumentError || error instanceof URIError) return jsonError(400, "invalid", error.message);
    return jsonError(503, "unavailable", "The company report could not be loaded.");
  }
}
