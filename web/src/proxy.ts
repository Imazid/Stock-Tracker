import type { NextRequest } from "next/server";
import { refreshSession } from "@/lib/supabase/proxy";

export function proxy(request: NextRequest) {
  return refreshSession(request);
}

export const config = {
  // Only workspace pages need the session refreshed.
  matcher: ["/((?!privacy(?:/|$)|terms(?:/|$)|api/|_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)"],
};
