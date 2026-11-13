import { alpacaConfigured } from "@/server/market/alpaca";

// Which integrations this deployment has configured — booleans only, never a value.
export async function GET() {
  return Response.json({
    accounts: Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY),
    alpacaData: alpacaConfigured(),
    coingeckoKey: Boolean(process.env.COINGECKO_API_KEY),
    // The assistant is built; it runs when the server has a key (and accounts, outside local dev).
    assistant: Boolean(process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN),
    liveTrading: false,
  }, { headers: { "Cache-Control": "no-store" } });
}
