import { type NextRequest, NextResponse } from "next/server";
import { safeReturnPath } from "@/lib/safe-return";
import { serverSupabase } from "@/lib/supabase/server";

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
      if (!error) return NextResponse.redirect(new URL(next, url.origin));
    } else if (tokenHash && (type === "email" || type === "signup" || type === "magiclink" || type === "invite")) {
      const { error } = await supabase.auth.verifyOtp({ type, token_hash: tokenHash });
      if (!error) return NextResponse.redirect(new URL(next, url.origin));
    }
  }
  const login = new URL("/login", url.origin);
  login.searchParams.set("error", "confirm");
  login.searchParams.set("next", next);
  return NextResponse.redirect(login);
}
