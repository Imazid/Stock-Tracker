import type { NextRequest } from "next/server";
import { maxSearchLength, parseSearchFilters, searchAssetType, searchMarket } from "@/lib/market-search";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { search } from "@/server/market/service";

export async function GET(request: NextRequest) {
  const limited = rateLimited(request);
  if (limited) return limited;
  const params = request.nextUrl.searchParams;
  const q = params.get("q") ?? "";
  const assetType = params.get("assetType");
  const market = params.get("market");
  if (q.length > maxSearchLength) return jsonError(400, "invalid", "That search is too long.");
  if ((assetType !== null && !searchAssetType(assetType)) || (market !== null && !searchMarket(market))) {
    return jsonError(400, "invalid", "Choose a supported asset type and market.");
  }
  const filters = parseSearchFilters(assetType, market);
  return json(await search(q, { filters, includeIndexes: params.get("indexes") === "1" || filters.assetType === "indexes" }), 30);
}
