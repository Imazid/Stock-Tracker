import { accessToken } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";

export async function verifyAuthenticator(owner: string, code: string, signal?: AbortSignal) {
  const auth = browserSupabase()?.auth;
  if (!auth || !await accessToken(owner)) throw Error("Open the form again for your current account.");
  signal?.throwIfAborted();
  const { data, error } = await auth.mfa.listFactors();
  if (error) throw error;
  const factor = data?.totp.find((item) => item.status === "verified");
  if (!factor) throw Error("Couldn’t find a verified authenticator for this account.");
  if (!await accessToken(owner)) throw Error("Open the form again for your current account.");
  signal?.throwIfAborted();
  const challenge = await auth.mfa.challenge({ factorId: factor.id });
  if (challenge.error) throw Error("Couldn’t start authenticator verification. Try again.");
  if (!await accessToken(owner)) throw Error("Open the form again for your current account.");
  signal?.throwIfAborted();
  const reply = await auth.mfa.verify({ factorId: factor.id, challengeId: challenge.data.id, code });
  signal?.throwIfAborted();
  if (reply.error) throw Error("That code couldn’t be verified. Check your authenticator and try again.");
}
