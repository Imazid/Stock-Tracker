import { SUPABASE_URL, SUPABASE_ANON_KEY } from "@/lib/env";

export const maxDuration = 60;

const services = {
  market: "market-workspace",
  trading: "trading-api",
  research: "ai-proxy",
  brokerage: "snaptrade-proxy",
  "private-markets": "private-markets",
} as const;

const privateMarketActions = new Set([
  "catalog", "discover", "research", "research_status", "research_runs", "reports", "report",
  "confirmed_holdings", "applications", "updates", "web_monitor_preferences", "save_web_monitor", "monitor_inbox", "monitor_digests",
]);

function failure(message: string, status: number) {
  return Response.json({ error: { message } }, { status, headers: { "Cache-Control": "no-store" } });
}

export async function POST(request: Request, context: {params: Promise<{service: string}>}) {
  const { service } = await context.params;
  if (!Object.hasOwn(services, service)) return failure("Unknown service.", 404);
  if (service === "research" && process.env.ENABLE_AI !== "true") return failure("The AI provider is awaiting configuration.", 503);
  if (service === "brokerage" && process.env.ENABLE_SNAPTRADE !== "true") return failure("The brokerage provider is awaiting configuration.", 503);
  const authorization = request.headers.get("authorization");
  const hasBearer = !!authorization?.match(/^Bearer [\w.-]+$/) && authorization.length <= 8192;
  if (service !== "private-markets" && !hasBearer) return failure("Sign in to continue.", 401);
  const url = SUPABASE_URL;
  const key = SUPABASE_ANON_KEY;
  if (!url || !key) return failure("Stock Tracker is awaiting backend configuration.", 503);

  const body = await request.text();
  if (body.length > 60_000) return failure("Request is too large.", 413);
  const parsed: unknown = await Promise.resolve().then(() => JSON.parse(body)).catch(() => null);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return failure("Invalid request.", 400);
  let publicCatalog = false;
  if (service === "private-markets") {
    const { action } = parsed as { action?: unknown };
    if (typeof action !== "string" || !privateMarketActions.has(action)) return failure("Unsupported Private Markets action.", 403);
    publicCatalog = action === "catalog";
    if ((action === "discover" || action === "research") && process.env.ENABLE_AI !== "true") {
      return failure("The AI provider is awaiting configuration.", 503);
    }
  }
  if (!publicCatalog && !hasBearer) {
    return failure("Sign in to continue.", 401);
  }
  if (service === "trading") {
    const input = parsed as {action?: string; mode?: string; order?: {mode?: string}; draft?: {mode?: string}};
    if ("fixture" in input || input.mode === "live" || input.order?.mode === "live" ||
      input.draft?.mode === "approvalRequired" || input.draft?.mode === "autonomousLive") {
      return failure("The workspace supports paper trading.", 403);
    }
  }
  if (service === "brokerage") {
    const input = parsed as {operation?: string; params?: {connectionType?: string}};
    const operations = ["status", "registerUser", "loginLink", "listBrokerages", "listAccounts", "accountPositions", "accountAllPositions", "accountActivities", "portfolioCash"];
    if (!operations.includes(input.operation ?? "") || (input.operation === "loginLink" && input.params?.connectionType !== "read")) {
      return failure("The web workspace supports read-only brokerage connections.", 403);
    }
  }
  // Existing Edge Functions verify the user's access token and enforce ownership and trading permissions.
  const idempotencyKey = request.headers.get("idempotency-key");
  try {
    const response = await fetch(`${url.replace(/\/$/, "")}/functions/v1/${services[service as keyof typeof services]}`, {
      method: "POST",
      headers: {
        ...(!publicCatalog && authorization ? { Authorization: authorization } : {}),
        apikey: key, "Content-Type": "application/json",
        ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
      },
      body,
      cache: "no-store",
      signal: AbortSignal.timeout(55_000),
    });
    return new Response(response.body, {
      status: response.status,
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
    });
  } catch {
    return failure("The service took too long to respond. Try again.", 504);
  }
}
