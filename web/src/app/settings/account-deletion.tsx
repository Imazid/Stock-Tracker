"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useId, useRef, useState } from "react";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input } from "@/components/ui/Field";
import { accessToken } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";
import { verifyAuthenticator } from "@/lib/supabase/verify-authenticator";

export function AccountDeletion({ owner, email, usesApple, onDeleted }: {
  owner: string; email?: string; usesApple: boolean; onDeleted: (owner: string) => void;
}) {
  const cache = useQueryClient();
  const passwordID = useId();
  const codeID = useId();
  const submitting = useRef(false);
  const [open, setOpen] = useState(false);
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [verify, setVerify] = useState(false);
  const [appleRequired, setAppleRequired] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    if (open && !busy) document.getElementById(verify ? codeID : passwordID)?.focus();
  }, [open, busy, verify, codeID, passwordID]);

  function close() {
    setOpen(false);
    setPassword("");
    setCode("");
    setVerify(false);
    setError("");
  }

  async function remove() {
    if (submitting.current || !password || (verify && !/^\d{6}$/.test(code))) return;
    submitting.current = true;
    setBusy(true);
    setError("");
    try {
      if (verify) {
        await verifyAuthenticator(owner, code);
        setVerify(false);
      }
      const token = await accessToken(owner);
      if (!token) throw new Error("Sign in again to delete your account.");
      const response = await fetch("/api/workspace-service/account-deletion", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ confirm: true, password }),
        cache: "no-store",
      });
      const data = await response.json().catch(() => null);
      if (!response.ok || data?.deleted !== true) {
        if (data?.error?.code === "step_up_required") {
          setVerify(true);
          setError("Verify your authenticator code before deleting your account.");
          return;
        }
        if (data?.error?.code === "apple_required") {
          close();
          setAppleRequired(true);
          return;
        }
        throw new Error(typeof data?.error?.message === "string" ? data.error.message :
          "Account deletion could not be confirmed. Sign in again to check your account.");
      }
      close();
      const auth = browserSupabase()?.auth;
      const current = await auth?.getSession().catch(() => null);
      if (current?.data.session?.user.id === owner) {
        await auth?.signOut({ scope: "local" }).catch(() => {});
      }
      if (!current?.data.session || current.data.session.user.id === owner) cache.clear();
      try { localStorage.removeItem(`st:portfolio-visit:${owner}`); } catch { /* storage is optional */ }
      onDeleted(owner);
    } catch (failure) {
      setPassword("");
      setError(failure instanceof Error ? failure.message : "Account deletion could not be confirmed. Try again.");
    } finally {
      submitting.current = false;
      setCode("");
      setBusy(false);
    }
  }

  return <Card id="delete-account" className="scroll-mt-20">
    <CardHeader title="Delete account" />
    <div className="space-y-3 border-t border-border p-4 text-sm text-text-2">
      <p>Permanently delete your Stock Tracker account and its synced data, including your portfolio, watchlists, and Private Markets records.</p>
      {usesApple || appleRequired
        ? <p>To delete an account connected to Apple, use Settings → Account → Delete Account in the iPhone app.</p>
        : open ? <form className="space-y-3" onSubmit={(event) => {
          event.preventDefault();
          void remove();
        }}>
          <p>Enter your password to delete {email ?? "this account"}.</p>
          <p>Manage active Apple subscriptions and records held by brokers or investment providers with those services.</p>
          <input type="text" name="username" autoComplete="username" value={email ?? ""} readOnly hidden />
          <Field label="Current password" htmlFor={passwordID}>
            <Input id={passwordID} type="password" name="password" autoComplete="current-password" required maxLength={1024}
              disabled={busy} value={password} onChange={(event) => setPassword(event.target.value)} />
          </Field>
          {verify && <Field label="Deletion authenticator code" htmlFor={codeID}>
            <Input id={codeID} type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={6} required
              disabled={busy} value={code} onChange={(event) => setCode(event.target.value.replace(/\D/g, ""))} />
          </Field>}
          {error && <p role="alert" className="text-down">{error}</p>}
          {busy && <p role="status">{verify ? "Verifying and deleting account…" : "Checking your account…"}</p>}
          <div className="flex flex-wrap gap-2">
            <Button size="sm" type="submit" variant="danger" disabled={busy || !password || (verify && code.length !== 6)}>
              Permanently delete account
            </Button>
            <Button size="sm" disabled={busy} onClick={close}>Cancel account deletion</Button>
          </div>
        </form> : <div className="flex flex-wrap gap-2">
          <Button size="sm" variant="danger" onClick={() => setOpen(true)}>Delete my account</Button>
          <ButtonLink href="#account-data" size="sm">Export account data</ButtonLink>
        </div>}
    </div>
  </Card>;
}
