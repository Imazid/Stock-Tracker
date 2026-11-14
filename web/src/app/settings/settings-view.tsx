"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { applyTheme, readTheme, type ThemeChoice } from "@/components/shell/theme";
import { AccountLimits } from "@/components/trading/AccountLimits";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { Segmented } from "@/components/ui/Segmented";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";
import { AccountDeletion } from "./account-deletion";
import { AccountExport } from "./account-export";

export function SettingsView() {
  const [deletedOwner, setDeletedOwner] = useState<string | null>(null);
  const [theme, setTheme] = useState<ThemeChoice>("dark");
  const deletionNotice = useRef<HTMLParagraphElement>(null);
  const session = useSession();
  const showDeleted = deletedOwner && (session.status === "signedOut" ||
    (session.status === "signedIn" && session.user.id === deletedOwner));
  const router = useRouter();
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setTheme(readTheme());
  }, []);
  useEffect(() => {
    if (showDeleted) deletionNotice.current?.focus();
  }, [showDeleted]);

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Settings" />
      <div className="flex flex-col gap-5">
        {showDeleted && <p role="status" tabIndex={-1} ref={deletionNotice}
          className="rounded-lg border border-border bg-surface-2 p-4 text-sm text-text">Your Stock Tracker account was deleted.</p>}
        <Card>
          <CardHeader title="Appearance" subtitle="Saved in this browser" />
          <div className="border-t border-border px-4 py-4">
            <Segmented label="Theme" value={theme} onChange={(t) => { setTheme(t); applyTheme(t); }}
              options={[{ value: "dark", label: "Dark" }, { value: "light", label: "Light" }, { value: "system", label: "Match system" }]} />
          </div>
        </Card>
        <Card>
          <CardHeader title="Account" />
          <div className="border-t border-border px-4 py-4 text-[13px]">
            {session.status === "unconfigured" ? <p className="text-text-2">Accounts aren&apos;t configured for this deployment.</p>
              : session.status === "signedIn" ? (
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div><p className="font-medium text-text">{session.user.email}</p><p className="text-xs text-text-3">Signed in · two-factor: {session.session.user.factors?.some((f) => f.status === "verified") ? "on" : "off"}</p></div>
                  <Button size="sm" onClick={async () => { await browserSupabase()?.auth.signOut(); router.push("/"); }}>Sign out</Button>
                </div>
              ) : session.status === "signedOut" ? <ButtonLink href="/login" variant="primary" size="sm">Sign in</ButtonLink> : <div className="skeleton h-8 w-48" />}
          </div>
        </Card>
        {session.status === "signedIn" && <AccountExport key={`export-${session.user.id}`} owner={session.user.id} />}
        {session.status === "signedIn" && <AccountLimits key={`limits-${session.user.id}`} owner={session.user.id} />}
        <Card>
          <CardHeader title="Trading environment" />
          <div className="space-y-3 border-t border-border px-4 py-4 text-[13px] text-text-2">
            <p>This build has <strong className="text-text">no live trading</strong>. The header shows <span className="font-semibold text-warn">PRACTICE</span> on every page. Orders can only go to a provider&apos;s paper environment, after a risk check and your explicit approval.</p>
            <Notice>Live execution stays off until it&apos;s switched on server-side, after the regulatory review and provider approvals are complete. Nothing in this browser can turn it on.</Notice>
          </div>
        </Card>
        {session.status === "signedIn" && <AccountDeletion key={`deletion-${session.user.id}`} owner={session.user.id}
          email={session.user.email} usesApple={session.user.identities?.some(({ provider }) => provider === "apple") === true}
          onDeleted={(owner) => { setDeletedOwner(owner); router.refresh(); }} />}
      </div>
    </div>
  );
}
