import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "npm:jose@6.2.12";
import { HttpError } from "../_shared/server/http.ts";

const issuer = "https://appleid.apple.com";
const appleKeys = createRemoteJWKSet(new URL(issuer + "/auth/keys"), { timeoutDuration: 5_000 });

interface AppleConfig {
  clientId: string;
  team?: string;
  keyId?: string;
  privateKey?: string;
}

export async function confirmAppleAccount(
  subject: string,
  code: string,
  config: AppleConfig,
  send: typeof fetch = fetch,
  keys = appleKeys,
): Promise<() => Promise<void>> {
  if (!config.team || !config.keyId || !config.privateKey) {
    throw new HttpError(503, "apple_unavailable", "Apple account deletion is temporarily unavailable.");
  }
  const key = await importPKCS8(config.privateKey.replaceAll("\\n", "\n"), "ES256");
  const clientSecret = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.keyId })
    .setIssuer(config.team).setSubject(config.clientId).setAudience(issuer)
    .setIssuedAt().setExpirationTime("5m").sign(key);
  function post(route: string, fields: Record<string, string>) {
    return send(issuer + route, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(8_000),
      body: new URLSearchParams({ client_id: config.clientId, client_secret: clientSecret, ...fields }),
    });
  }
  const response = await post("/auth/token", { code, grant_type: "authorization_code" });
  if (!response.ok) {
    await response.body?.cancel();
    throw new HttpError(502, "apple_verification_failed", "Apple could not verify this sign-in. Try again.");
  }
  const credentials = await response.json();
  if (typeof credentials.id_token !== "string" || typeof credentials.refresh_token !== "string" ||
      !credentials.refresh_token) {
    throw new HttpError(502, "apple_verification_failed", "Apple could not verify this sign-in. Try again.");
  }
  try {
    await jwtVerify(credentials.id_token, keys, {
      algorithms: ["RS256"], issuer, audience: config.clientId, subject, maxTokenAge: "5m",
      requiredClaims: ["exp", "iat", "sub"],
    });
  } catch {
    throw new HttpError(403, "apple_account_mismatch", "Use the Apple Account connected to your Stock Tracker account.");
  }
  const refreshToken: string = credentials.refresh_token;
  return async () => {
    const result = await post("/auth/revoke", { token: refreshToken, token_type_hint: "refresh_token" });
    await result.body?.cancel();
    if (!result.ok) {
      throw new HttpError(502, "apple_revocation_failed", "Apple could not revoke this connection. Try again.");
    }
  };
}
