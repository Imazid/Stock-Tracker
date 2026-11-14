import { json, jsonError, rateLimited } from "@/server/http/respond";
import { BadInstrumentError, parseInstrumentID } from "@/server/market/instruments";
import { getQuote, NoDataError } from "@/server/market/service";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const limited = rateLimited(request);
  if (limited) return limited;
  try {
    const instrument = parseInstrumentID((await params).id, { allowIndex: true });
    return json(await getQuote(instrument));
  } catch (error) {
    if (error instanceof BadInstrumentError) return jsonError(400, "invalid", error.message);
    if (error instanceof NoDataError) return jsonError(502, "no_data", error.message, { reasons: error.reasons });
    throw error;
  }
}
