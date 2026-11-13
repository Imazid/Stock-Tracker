"use client";

import Link from "next/link";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { KeyRound } from "lucide-react";
import { backend } from "../lib/backend";
import { message } from "../lib/models";

export default function Auth({ mode, onDone }: { mode: "login" | "mfa"; onDone: () => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [flow, setFlow] = useState<"password"|"email">("password");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const emailCode = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (sent) emailCode.current?.focus();
  }, [sent]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy || !backend) return;
    setBusy(true); setError("");
    try {
      if (mode === "mfa") {
        const { data, error } = await backend.auth.mfa.listFactors();
        if (error) throw error;
        const factor = data.totp[0];
        if (!factor) throw new Error("An authenticator factor is required.");
        const result = await backend.auth.mfa.challengeAndVerify({ factorId: factor.id, code });
        if (result.error) throw result.error;
      } else if (flow === "password") {
        const result = await backend.auth.signInWithPassword({ email, password });
        if (result.error) throw result.error;
      } else if (sent) {
        const result = await backend.auth.verifyOtp({ email, token: code, type: "email" });
        if (result.error) throw result.error;
      } else {
        const next = `/${window.location.hash}`;
        const emailRedirectTo = `${window.location.origin}/auth/confirm?${new URLSearchParams({ next })}`;
        const result = await backend.auth.signInWithOtp({ email, options: { shouldCreateUser: false, emailRedirectTo } });
        if (result.error) throw result.error;
        setSent(true);
        return;
      }
      onDone();
    } catch (failure) { setError(message(failure)); }
    finally { setBusy(false); }
  }

  return <form className="form" onSubmit={submit}>
    <div className="auth-note"><KeyRound size={19}/><p>{mode === "mfa" ? "Enter the six-digit code from your authenticator app." : "Use the email address associated with your Stock Tracker account."}</p></div>
    {mode === "login" && <label>Email<input data-dialog-focus type="email" autoComplete="email" value={email} onChange={e => setEmail(e.target.value)} required disabled={sent}/></label>}
    {mode === "login" && flow === "password" && <label>Password<input type="password" autoComplete="current-password" value={password} onChange={e => setPassword(e.target.value)} required/></label>}
    {(mode === "mfa" || sent) && <label>{mode === "mfa" ? "Authenticator code" : "Email code"}<input ref={emailCode} data-dialog-focus={mode === "mfa" || undefined} inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6,10}" value={code} onChange={e => setCode(e.target.value)} required/></label>}
    {sent && <p className="muted">Check your email for a sign-in link or code.</p>}
    {error && <p className="error" role="alert">{error}</p>}
    {!backend && <p className="error">Account services are awaiting configuration.</p>}
    <button className="button primary" disabled={busy || !backend}>{busy ? "Please wait…" : mode === "mfa" ? "Verify" : flow === "password" ? "Sign in" : sent ? "Verify code" : "Email me a sign-in link"}</button>
    {mode === "login" && <button type="button" disabled={busy} className="text-button" onClick={() => { setFlow(flow === "password" ? "email" : "password"); setError(""); setSent(false); setCode(""); }}>{flow === "password" ? "Use an email sign-in link" : "Use my password"}</button>}
    {mode === "login" && <Link className="text-button" href="/login?mode=signup">Create a Stock Tracker account</Link>}
  </form>;
}
