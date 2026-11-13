// Who is calling, and whether they have proved it strongly enough.
//
// The user id always comes from the caller's own access token, checked with the auth
// server — never from the request body. The token itself is never logged or stored.

import { HttpError } from "./http.ts";

export interface Caller {
  userID: string;
  /** How the session was authenticated: aal1 (one factor) or aal2 (MFA verified). */
  aal: "aal1" | "aal2";
  /** Whether the person has an MFA factor they have verified. */
  hasVerifiedFactor: boolean;
}

export interface AuthEnvironment {
  /** The project's API address (SUPABASE_URL). */
  url: string | undefined;
  /** The public anon key (SUPABASE_ANON_KEY), needed to reach the auth server through the gateway. */
  anonKey: string | undefined;
  fetch?: typeof fetch;
}

function bearerToken(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  if (!match) throw new HttpError(401, "unauthenticated", "Sign in to use trading.");
  return match[1];
}

function claims(token: string): Record<string, unknown> {
  const part = token.split(".")[1];
  if (!part) return {};
  try {
    const padded = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    const value = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))));
    return typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

/**
 * Checks the caller's token with the auth server (signature, expiry and that the session
 * still exists) and returns who they are. The claims are read only after that check passes.
 */
export async function authenticate(request: Request, env: AuthEnvironment): Promise<Caller> {
  const token = bearerToken(request);
  if (!env.url || !env.anonKey) throw new HttpError(503, "unavailable", "Sign-in can't be checked right now.");
  let response: Response;
  try {
    response = await (env.fetch ?? fetch)(`${env.url.replace(/\/+$/, "")}/auth/v1/user`, {
      headers: { authorization: `Bearer ${token}`, apikey: env.anonKey },
      signal: AbortSignal.timeout(8_000),
    });
  } catch {
    throw new HttpError(503, "unavailable", "Sign-in can't be checked right now.");
  }
  if (response.status === 401 || response.status === 403) {
    await response.body?.cancel().catch(() => {});
    throw new HttpError(401, "unauthenticated", "Your session has ended. Sign in again.");
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw new HttpError(503, "unavailable", "Sign-in can't be checked right now.");
  }
  const user = await response.json().catch(() => null) as Record<string, unknown> | null;
  const payload = claims(token);
  const userID = typeof user?.id === "string" ? user.id.toLowerCase() : "";
  // A real person's token: it names them, and it is not the anon or service key.
  if (userID === "" || payload.sub !== user?.id || payload.role !== "authenticated") {
    throw new HttpError(401, "unauthenticated", "Sign in to use trading.");
  }
  const factors = Array.isArray(user?.factors) ? user.factors as Record<string, unknown>[] : [];
  return {
    userID,
    aal: payload.aal === "aal2" ? "aal2" : "aal1",
    hasVerifiedFactor: factors.some((factor) => factor?.status === "verified"),
  };
}

/**
 * Step-up: releasing the kill switch, loosening a risk limit and anything that asks for
 * live trading need an MFA-verified session once the person has a verified factor.
 * Returns the reason the caller must step up, or undefined when they may go ahead.
 */
export function stepUpProblem(caller: Caller): string | undefined {
  if (!caller.hasVerifiedFactor) return undefined;
  if (caller.aal === "aal2") return undefined;
  return "Confirm it's you with your authenticator code, then try again.";
}

export function requireStepUp(caller: Caller): void {
  const problem = stepUpProblem(caller);
  if (problem) throw new HttpError(403, "step_up_required", problem, { requiredAal: "aal2" });
}
