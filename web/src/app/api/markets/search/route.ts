import type { NextRequest } from "next/server";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { search } from "@/server/market/service";

export async function GET(request: NextRequest) {
  const limited = rateLimited(request);
  if (limited) return limited;
  const q = request.nextUrl.searchParams.get("q") ?? "";
  if (q.length > 64) return jsonError(400, "invalid", "That search is too long.");
  return json(await search(q), 30);
}
