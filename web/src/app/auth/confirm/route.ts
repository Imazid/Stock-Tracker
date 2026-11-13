import type { NextRequest } from "next/server";
import { safeReturnPath } from "@/lib/safe-return";
import { serverSupabase } from "@/lib/supabase/server";

function redirect(location: string) {
  return new Response(null, { status: 303, headers: { Location: location, "Cache-Control": "no-store" } });
}

// The default PKCE email redirects here with a code. A custom confirmation template can
// supply a token hash. Both store the session through the same server client.
export async function GET(request: NextRequest) {
  const url = request.nextUrl;
  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type");
  const next = safeReturnPath(url.searchParams.get("next"));
  const supabase = await serverSupabase();
  if (supabase) {
    if (code) {
      const flowId = url.searchParams.get("sb_flow_id");
      const { error } = await supabase.auth.exchangeCodeForSession(code, flowId ? { flowId } : undefined);
      if (!error) return redirect(next);
    } else if (tokenHash && (type === "email" || type === "signup" || type === "magiclink" || type === "invite")) {
      const { error } = await supabase.auth.verifyOtp({ type, token_hash: tokenHash });
      if (!error) return redirect(next);
    }
  }
  return redirect(`/login?${new URLSearchParams({ error: "confirm", next })}`);
}
