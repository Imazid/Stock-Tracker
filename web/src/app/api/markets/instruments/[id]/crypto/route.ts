import { SUPABASE_ANON_KEY, SUPABASE_URL } from "@/lib/env";
import { json, jsonError, rateLimited } from "@/server/http/respond";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const limited = rateLimited(request, 30);
  if (limited) return limited;

  const { id } = await params;
  const match = /^crypto:([A-Z0-9]{1,16})$/.exec(id);
  if (!match) return jsonError(404, "unsupported_crypto", "Research is unavailable for this token.");
  const secret = process.env.WORKSPACE_OVERVIEW_SECRET;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !secret) {
    return jsonError(503, "crypto_unavailable", "Token research is awaiting configuration.");
  }

  try {
    const response = await fetch(`${SUPABASE_URL.replace(/\/$/, "")}/functions/v1/market-workspace`, {
      method: "POST",
      headers: {
        apikey: SUPABASE_ANON_KEY,
        "Content-Type": "application/json",
        "X-Workspace-Overview-Secret": secret,
      },
      body: JSON.stringify({ action: "cryptoFacts", symbol: match[1] }),
      signal: AbortSignal.timeout(9_000),
      next: { revalidate: 60 },
    });
    const envelope = await response.json();
    if (response.ok && envelope.ok && envelope.data?.symbol === match[1]) return json(envelope.data, 60);
    if (response.status === 404 && envelope.error?.code === "unsupported_crypto") {
      return jsonError(404, "unsupported_crypto", "Research is unavailable for this token.");
    }
  } catch {
    // Token research is independent of the price, chart and order entry.
  }
  return jsonError(503, "crypto_unavailable", "CoinGecko token research is temporarily unavailable.");
}
