import { createServerClient } from "@supabase/ssr";
import { type NextRequest, NextResponse } from "next/server";
import { SUPABASE_ANON_KEY, SUPABASE_URL, supabaseConfigured } from "@/lib/env";

/**
 * Refreshes the Supabase session cookie on every request (the @supabase/ssr pattern), so a
 * long-open tab doesn't silently drop its sign-in. Pages still re-check the user themselves;
 * this is not an authorisation layer.
 */
export async function refreshSession(request: NextRequest): Promise<NextResponse> {
  let response = NextResponse.next({ request });
  if (!supabaseConfigured) return response;
  const supabase = createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(cookies) {
        for (const { name, value } of cookies) request.cookies.set(name, value);
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookies) response.cookies.set(name, value, options);
      },
    },
  });
  // getClaims() validates the JWT; it also triggers the refresh when the access token expired.
  try {
    await supabase.auth.getClaims();
  } catch {
    // An unreachable auth server must not take the whole site down.
  }
  return response;
}
