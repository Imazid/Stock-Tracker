"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { Segmented } from "@/components/ui/Segmented";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";

export function LoginView() {
  const session = useSession();
  const router = useRouter();
  const params = useSearchParams();
  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(params.get("error") === "confirm" ? "That confirmation link didn't work. It may have expired — sign in or request a new one." : null);
  const [info, setInfo] = useState<string | null>(null);

  useEffect(() => {
    if (session.status === "signedIn") router.replace("/");
  }, [session.status, router]);

  if (session.status === "unconfigured") {
    return <div className="mx-auto max-w-md pt-10"><Card><EmptyState title="Accounts aren't configured" body="This deployment has no Supabase project. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY, then reload. Market data works without an account." /></Card></div>;
  }

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const supabase = browserSupabase();
    if (!supabase) return;
    setBusy(true);
    setError(null);
    setInfo(null);
    try {
      if (mode === "signin") {
        const { error: err } = await supabase.auth.signInWithPassword({ email, password });
        if (err) throw err;
        router.replace("/");
      } else {
        const { data, error: err } = await supabase.auth.signUp({ email, password, options: { emailRedirectTo: `${window.location.origin}/auth/confirm` } });
        if (err) throw err;
        if (data.session) router.replace("/");
        else setInfo("Check your email to confirm your account, then sign in.");
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mx-auto max-w-sm pt-6 md:pt-12">
      <h1 className="mb-1 text-xl font-semibold tracking-tight">{mode === "signin" ? "Sign in" : "Create your account"}</h1>
      <p className="mb-5 text-[13px] text-text-2">The same account as the Stock Tracker iPhone app.</p>
      <Card className="p-4">
        <Segmented label="Sign in or create an account" value={mode} onChange={(m) => { setMode(m); setError(null); setInfo(null); }} className="mb-4 w-full [&>button]:flex-1"
          options={[{ value: "signin", label: "Sign in" }, { value: "signup", label: "Create account" }]} />
        <form onSubmit={submit} className="flex flex-col gap-3">
          <Field label="Email" htmlFor="email"><Input id="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
          <Field label="Password" htmlFor="password" hint={mode === "signup" ? "At least 8 characters." : undefined}>
            <Input id="password" type="password" autoComplete={mode === "signin" ? "current-password" : "new-password"} required minLength={mode === "signup" ? 8 : undefined} value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
          {error ? <Notice tone="down">{error}</Notice> : null}
          {info ? <Notice>{info}</Notice> : null}
          <Button type="submit" variant="primary" disabled={busy} className="mt-1">{busy ? "Please wait…" : mode === "signin" ? "Sign in" : "Create account"}</Button>
        </form>
      </Card>
    </div>
  );
}
