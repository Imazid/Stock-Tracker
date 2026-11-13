import { alpacaConfigured } from "@/server/market/alpaca";

// Which integrations this deployment has configured — booleans only, never a value.
export async function GET() {
  return Response.json({
    accounts: Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY),
    alpacaData: alpacaConfigured(),
    coingeckoKey: Boolean(process.env.COINGECKO_API_KEY),
    assistant: false,
    assistantKey: Boolean(process.env.ANTHROPIC_API_KEY),
    liveTrading: false,
  }, { headers: { "Cache-Control": "no-store" } });
}
