import type { NextRequest } from "next/server";
import { ASSET_RISK_RANGES, assetRisk, type AssetRiskRange } from "@/lib/asset-risk";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { BadInstrumentError, parseInstrumentID } from "@/server/market/instruments";
import { getCandles, NoDataError } from "@/server/market/service";

export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const limited = rateLimited(request);
  if (limited) return limited;
  const range = (request.nextUrl.searchParams.get("range") ?? "3M").toUpperCase() as AssetRiskRange;
  if (!ASSET_RISK_RANGES.includes(range)) return jsonError(400, "invalid", "Choose 3M, 6M or 1Y.");
  try {
    const instrument = parseInstrumentID((await params).id, { allowIndex: true });
    const result = assetRisk(await getCandles(instrument, range), Date.now());
    if (!result) return jsonError(404, "insufficient_history", "At least two completed daily closes are needed.");
    return json(result);
  } catch (error) {
    if (error instanceof BadInstrumentError) return jsonError(400, "invalid", error.message);
    if (error instanceof NoDataError) return jsonError(502, "no_data", "Daily price history is temporarily unavailable.");
    throw error;
  }
}
