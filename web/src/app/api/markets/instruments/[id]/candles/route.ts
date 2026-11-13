import type { NextRequest } from "next/server";
import { CHART_RANGES, type ChartRange } from "@/lib/market-types";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { BadInstrumentError, parseInstrumentID } from "@/server/market/instruments";
import { getCandles, NoDataError } from "@/server/market/service";

// `range` picks the window; the bar size follows from it (5m for 1D … 1wk for 5Y). An explicit
// `interval` is accepted only when it matches what the range uses, so a caller can't ask for
// a combination we don't serve and get something else silently.
export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const limited = rateLimited(request);
  if (limited) return limited;
  const range = (request.nextUrl.searchParams.get("range") ?? "6M").toUpperCase() as ChartRange;
  if (!CHART_RANGES.includes(range)) return jsonError(400, "invalid", `range must be one of ${CHART_RANGES.join(", ")}.`);
  try {
    const instrument = parseInstrumentID((await params).id);
    const view = await getCandles(instrument, range);
    const interval = request.nextUrl.searchParams.get("interval");
    if (interval && interval !== view.interval) {
      return jsonError(400, "invalid", `The ${range} range is served in ${view.interval} bars.`, { interval: view.interval });
    }
    return json(view);
  } catch (error) {
    if (error instanceof BadInstrumentError) return jsonError(400, "invalid", error.message);
    if (error instanceof NoDataError) return jsonError(502, "no_data", error.message, { reasons: error.reasons });
    throw error;
  }
}
