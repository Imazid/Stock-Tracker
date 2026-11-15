import { assertEquals } from "jsr:@std/assert@1";
import { createRemoteJWKSet, customFetch, exportJWK, exportPKCS8, generateKeyPair, jwtVerify, SignJWT } from "npm:jose@6.2.12";
import { HttpError } from "../_shared/server/http.ts";
import { confirmAppleAccount } from "../account-deletion/apple.ts";
import { type AccountDeletionDependencies, deleteAccount } from "../account-deletion/handler.ts";

function request(body: unknown, method = "POST") {
  return new Request("https://example.test/account-deletion", { method, body: JSON.stringify(body) });
}

function fixture() {
  const calls: string[] = [];
  const deps: AccountDeletionDependencies = {
    owner: () => Promise.resolve({ id: "owner", email: "owner@example.test", needsMFA: false }),
    confirmPassword(owner, password) {
      calls.push("password:" + owner.id);
      if (password !== "test-password") return Promise.reject(new HttpError(403, "incorrect_password", "Try again."));
      return Promise.resolve();
    },
    confirmApple(subject) {
      calls.push("apple identity:" + subject);
      return Promise.resolve(() => {
        calls.push("revoke Apple");
        return Promise.resolve();
      });
    },
    disconnectBroker(id) { calls.push("broker:" + id); return Promise.resolve(true); },
    deleteUser(id) { calls.push("delete:" + id); return Promise.resolve(); },
  };
  return { deps, calls };
}

Deno.test("account deletion cannot take an owner from the body or proceed with a wrong password", async () => {
  const { deps, calls } = fixture();
  assertEquals((await deleteAccount(request({ confirm: true, password: "test-password", userId: "other" }), deps)).status, 400);
  assertEquals((await deleteAccount(request({ confirm: true, password: "wrong" }), deps)).status, 403);
  assertEquals(calls, ["password:owner"]);
  const result = await deleteAccount(request({ confirm: true, password: "test-password" }), deps);
  assertEquals(await result.json(), { deleted: true, brokerDeletionQueued: true });
  assertEquals(calls, ["password:owner", "password:owner", "broker:owner", "delete:owner"]);
});

Deno.test("account deletion keeps the account if authentication, MFA or broker cleanup fails", async () => {
  const { deps, calls } = fixture();
  const body = { confirm: true, password: "test-password" };
  assertEquals((await deleteAccount(request(body, "PUT"), deps)).status, 405);
  const missing = { ...deps, owner: () => Promise.reject(new HttpError(401, "unauthenticated", "Sign in.")) };
  assertEquals((await deleteAccount(request(body), missing)).status, 401);
  const mfa = { ...deps, owner: () => Promise.resolve({ id: "owner", needsMFA: true }) };
  assertEquals((await deleteAccount(request(body), mfa)).status, 403);
  const brokerOffline = { ...deps, disconnectBroker: () => Promise.reject(new HttpError(503, "broker_unavailable", "Retry.")) };
  assertEquals((await deleteAccount(request(body), brokerOffline)).status, 503);
  assertEquals(calls, ["password:owner"]);
});

Deno.test("Apple account deletion revokes the matched Apple authorization before deleting the account", async () => {
  const { deps, calls } = fixture();
  deps.owner = () => Promise.resolve({ id: "owner", appleSubject: "apple-owner", needsMFA: false });
  assertEquals((await deleteAccount(request({ confirm: true, password: "test-password" }), deps)).status, 400);
  assertEquals(calls, []);
  const body = { confirm: true, appleCode: "single-use-code" };
  const appleOffline = { ...deps, confirmApple: () =>
    Promise.resolve(() => Promise.reject(new HttpError(502, "apple_revocation_failed", "Retry."))) };
  assertEquals((await deleteAccount(request(body), appleOffline)).status, 502);
  assertEquals(calls, ["broker:owner"]);
  assertEquals((await deleteAccount(request(body), deps)).status, 200);
  assertEquals(calls.slice(1), ["apple identity:apple-owner", "broker:owner", "revoke Apple", "delete:owner"]);
});

Deno.test("Apple code exchange checks the signed subject and revokes the returned refresh token", async () => {
  const appleOrigin = "https://appleid.apple.com";
  const apple = await generateKeyPair("RS256");
  const client = await generateKeyPair("ES256", { extractable: true });
  const publicJwk = { ...await exportJWK(apple.publicKey), kid: "test-apple-key", alg: "RS256" };
  const appleKeys = createRemoteJWKSet(new URL(appleOrigin + "/auth/keys"), {
    [customFetch]: () => Promise.resolve(Response.json({ keys: [publicJwk] })),
  });
  const config = { clientId: "test.app", team: "test-team", keyId: "test-key", privateKey: await exportPKCS8(client.privateKey) };
  const idToken = await new SignJWT({}).setProtectedHeader({ alg: "RS256", kid: publicJwk.kid })
    .setIssuer(appleOrigin).setSubject("matched").setAudience(config.clientId)
    .setIssuedAt().setExpirationTime("5m").sign(apple.privateKey);
  const paths: string[] = [];
  const send: typeof fetch = async (input, init) => {
    paths.push(String(input));
    const fields = init?.body as URLSearchParams;
    assertEquals(fields.get("client_id"), config.clientId);
    await jwtVerify(fields.get("client_secret")!, client.publicKey, {
      audience: appleOrigin, issuer: config.team, subject: config.clientId, algorithms: ["ES256"],
    });
    if (String(input).endsWith("/auth/token")) {
      assertEquals(fields.get("code"), "signed-code");
      return Response.json({ id_token: idToken, refresh_token: "apple-refresh" });
    }
    assertEquals(fields.get("token_type_hint"), "refresh_token");
    assertEquals(fields.get("token"), "apple-refresh");
    return new Response(null, { status: 200 });
  };
  const revoke = await confirmAppleAccount("matched", "signed-code", config, send, appleKeys);
  await revoke();
  try {
    await confirmAppleAccount("other", "signed-code", config, send, appleKeys);
    throw new Error("Wrong identity was accepted");
  } catch (error) {
    assertEquals((error as HttpError).code, "apple_account_mismatch");
  }
  assertEquals(paths, [appleOrigin + "/auth/token", appleOrigin + "/auth/revoke", appleOrigin + "/auth/token"]);
});
