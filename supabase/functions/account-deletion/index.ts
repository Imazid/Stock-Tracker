import { createClient } from "npm:@supabase/supabase-js@2.49.4";
import { decodeJwt } from "npm:jose@6.2.12";
import { HttpError } from "../_shared/server/http.ts";
import { SealedSnapTradeStore } from "../_shared/secure/credentials.ts";
import { credentialTable, serviceClient } from "../_shared/secure/edge.ts";
import { parseKeyring } from "../_shared/secure/envelope.ts";
import { handleSnapTradeRequest } from "../_shared/snaptrade/proxy.ts";
import { confirmAppleAccount } from "./apple.ts";
import { deleteAccount } from "./handler.ts";

const env = (name: string) => Deno.env.get(name);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve((request) => {
  const admin = serviceClient();
  return deleteAccount(request, {
    async owner(req) {
      const token = /^Bearer\s+(\S+)$/i.exec(req.headers.get("authorization") ?? "")?.[1];
      if (!token) throw new HttpError(401, "unauthenticated", "Sign in to continue.");
      const { data, error } = await admin.auth.getUser(token);
      if (error && ![400, 401, 403, 404].includes(error.status ?? 0)) {
        throw new HttpError(503, "unavailable", "Sign-in could not be checked. Try again.");
      }
      const user = data?.user;
      if (!user) throw new HttpError(401, "unauthenticated", "Sign in to continue.");
      const claims = decodeJwt(token);
      if (claims.sub !== user.id || claims.role !== "authenticated" ||
          typeof claims.session_id !== "string" || !uuid.test(claims.session_id)) {
        throw new HttpError(401, "unauthenticated", "Sign in to continue.");
      }
      const active = await admin.rpc("account_deletion_session_active", { p_user: user.id, p_session: claims.session_id });
      if (active.error) throw active.error;
      if (!active.data) throw new HttpError(401, "unauthenticated", "Your session ended. Sign in again.");
      const apple = user.identities?.find((identity) => identity.provider === "apple");
      const subject = apple?.identity_data?.sub;
      if (apple && (typeof subject !== "string" || subject.length === 0)) {
        throw new HttpError(503, "apple_unavailable", "The linked Apple Account could not be verified.");
      }
      return {
        id: user.id,
        email: user.email,
        appleSubject: typeof subject === "string" ? subject : undefined,
        needsMFA: claims.aal !== "aal2" && user.factors?.some((factor) => factor.status === "verified") === true,
      };
    },
    async confirmPassword(owner, password) {
      if (!owner.email) throw new HttpError(403, "password_unavailable", "This account has no email sign-in to confirm.");
      const auth = createClient(env("SUPABASE_URL") ?? "", env("SUPABASE_ANON_KEY") ?? "", {
        auth: { persistSession: false, autoRefreshToken: false },
      }).auth;
      const { data, error } = await auth.signInWithPassword({ email: owner.email, password });
      if (error?.status === 429) throw new HttpError(429, "rate_limited", "Wait a moment before trying again.");
      if (error && ![400, 401, 403, 404, 422].includes(error.status ?? 0)) {
        throw new HttpError(503, "unavailable", "Sign-in could not be checked. Try again.");
      }
      if (data?.session) await auth.signOut({ scope: "local" }).catch(() => {});
      if (error || data?.user?.id !== owner.id) {
        throw new HttpError(403, "incorrect_password", "The password did not match this account.");
      }
    },
    confirmApple(subject, code) {
      return confirmAppleAccount(subject, code, {
        clientId: "Cubeplay.Stock-Tracker",
        team: env("ACCOUNT_DELETION_APPLE_TEAM_ID"),
        keyId: env("ACCOUNT_DELETION_APPLE_KEY_ID"),
        privateKey: env("ACCOUNT_DELETION_APPLE_PRIVATE_KEY"),
      });
    },
    async disconnectBroker(userId) {
      const table = credentialTable(admin);
      if (!await table.findActive(userId, "snaptrade_user", "snaptrade")) return false;
      const keyring = await parseKeyring(env("CREDENTIAL_KEKS"), env("CREDENTIAL_ACTIVE_KEK"));
      const store = new SealedSnapTradeStore(table, keyring);
      const result = await handleSnapTradeRequest(userId, { operation: "deleteUser" }, {
        config: { clientId: env("SNAPTRADE_CLIENT_ID") ?? "", consumerKey: env("SNAPTRADE_CONSUMER_KEY") ?? "",
          timeoutMs: 8_000 },
        store, fetch, now: Date.now,
      });
      if (result.status === 404) {
        await store.remove(userId);
        return false;
      }
      if (result.status >= 200 && result.status < 300) return true;
      if (!await table.findActive(userId, "snaptrade_user", "snaptrade")) return false;
      throw new HttpError(503, "broker_unavailable", "Your broker connection could not be removed. Try again.");
    },
    async deleteUser(userId) {
      const { error } = await admin.auth.admin.deleteUser(userId);
      if (error && error.status !== 404) throw error;
    },
  });
});
