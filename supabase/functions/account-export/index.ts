import { decodeJwt } from "npm:jose@6.2.12";
import { errorResponse, jsonResponse, readJson, serviceClient } from "../_shared/secure/edge.ts";
import { accountRecords, accountSections, parseAccountPage } from "./records.ts";

const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;

Deno.serve(async (request) => {
  if (request.method !== "POST") return errorResponse(405, "METHOD_NOT_ALLOWED", "Use POST.");
  const token = /^Bearer\s+(\S+)$/i.exec(request.headers.get("Authorization") ?? "")?.[1];
  const signedOut = () => errorResponse(401, "UNAUTHENTICATED", "Sign in again to export your account.");
  if (!token) return signedOut();

  try {
    const admin = serviceClient();
    const { data, error } = await admin.auth.getUser(token);
    if (error && ![400, 401, 403, 404].includes(error.status ?? 0)) throw error;
    const user = data?.user;
    if (!user || user.is_anonymous) return signedOut();
    const claims = decodeJwt(token);
    if (claims.sub !== user.id || claims.role !== "authenticated" ||
      typeof claims.session_id !== "string" || !uuid.test(claims.session_id)) return signedOut();
    const active = await admin.rpc("account_deletion_session_active", { p_user: user.id, p_session: claims.session_id });
    if (active.error) throw active.error;
    if (active.data !== true) return signedOut();
    if (claims.aal !== "aal2" && user.factors?.some((factor) => factor.status === "verified")) {
      return errorResponse(403, "MFA_REQUIRED", "Verify your authenticator before exporting your account.");
    }

    let body: Record<string, unknown>;
    try {
      const value = await readJson(request, 2_000);
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
      body = value as Record<string, unknown>;
      if (Object.keys(body).some((key) => key !== "section" && key !== "offset")) throw new Error();
    } catch {
      return errorResponse(400, "INVALID_EXPORT", "Choose an account export section and page.");
    }
    if (body.section === undefined && body.offset === undefined) return jsonResponse(200, { sections: accountSections });
    const page = parseAccountPage(body.section, body.offset);
    if (!page) return errorResponse(400, "INVALID_EXPORT", "Choose an account export section and page.");
    if (page.id === "account") {
      return jsonResponse(200, { records: [{
        id: user.id,
        email: user.email,
        created_at: user.created_at,
        email_confirmed_at: user.email_confirmed_at,
        last_sign_in_at: user.last_sign_in_at,
        sign_in_providers: [...new Set(user.identities?.map(({ provider }) => provider) ?? [])],
        authenticator_enabled: user.factors?.some((factor) => factor.status === "verified") ?? false,
      }], next_offset: null });
    }
    return jsonResponse(200, await accountRecords(admin, user.id, page.id, page.start));
  } catch (error) {
    console.error("account export failed", error instanceof Error ? error.name : (error as { code?: string })?.code ?? "database error");
    return errorResponse(503, "EXPORT_UNAVAILABLE", "Account records could not be read. Try again.");
  }
});
