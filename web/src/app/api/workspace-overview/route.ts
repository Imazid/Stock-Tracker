import { SUPABASE_URL, SUPABASE_ANON_KEY } from "@/lib/env";

const symbols = new Set(["SPY", "QQQ", "AAPL", "NVDA", "MSFT", "BTC", "ETH", "SOL", "BHP", "CBA"]);
const ranges = new Set(["1D", "1W", "1M", "3M", "1Y"]);

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const symbol = params.get("symbol") ?? "SPY";
  const range = params.get("range") ?? "1M";
  if (!symbols.has(symbol) || !ranges.has(range)) return Response.json({ error: "Unknown market or time range." }, { status: 400 });
  const url = SUPABASE_URL;
  const key = SUPABASE_ANON_KEY;
  const secret = process.env.WORKSPACE_OVERVIEW_SECRET;
  if (!url || !key || !secret) return Response.json({ error: "Market data is awaiting configuration." }, { status: 503 });
  try {
    const response = await fetch(`${url.replace(/\/$/, "")}/functions/v1/market-workspace`, {
      method: "POST",
      headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json", "X-Workspace-Overview-Secret": secret },
      body: JSON.stringify({ action: "featured", symbol, range }),
      next: { revalidate: 90 },
    });
    const result = await response.json();
    if (response.ok && result.ok) {
      return Response.json(result.data, { headers: { "Cache-Control": "private, max-age=90" } });
    }
  } catch {
    // Provider failures must never be shown as a quote or a flat chart.
  }
  return Response.json({ error: "Market data is temporarily unavailable." }, { status: 503 });
}
