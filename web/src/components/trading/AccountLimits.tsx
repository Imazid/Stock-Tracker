"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { accountLimitIssues, type AccountLimits as Limits } from "@engine/risk.ts";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input } from "@/components/ui/Field";
import { practiceCall, PracticeError } from "@/hooks/practice";
import { browserSupabase } from "@/lib/supabase/client";

export function AccountLimits({ owner }: { owner: string }) {
  const query = useQuery({
    queryKey: ["practice-limits", owner],
    queryFn: () => practiceCall<{ limits: Limits }>("accountLimits", {}, undefined, owner),
    retry: false,
  });
  return (
    <Card id="account-practice-limits">
      <CardHeader title="Account practice limits" />
      <div className="border-t border-border p-4 text-sm text-text-2">
        {query.data ? <LimitForm key={owner} owner={owner} limits={query.data.limits} />
          : query.isError ? <div className="space-y-2"><p role="status">Couldn’t load your account limits.</p><Button size="sm" onClick={() => void query.refetch()}>Retry</Button></div>
          : <p role="status">Loading account limits…</p>}
      </div>
    </Card>
  );
}

function LimitForm({ owner, limits }: { owner: string; limits: Limits }) {
  const cache = useQueryClient();
  const [edits, setEdits] = useState<Partial<Record<keyof Limits, string>>>({});
  const [saved, setSaved] = useState(false);
  const [stepUp, setStepUp] = useState(false);
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const exposure = edits.maxSymbolExposurePct ?? String(limits.maxSymbolExposurePct);
  const dailyBuys = edits.maxTotalDailyNotional ?? String(limits.maxTotalDailyNotional);
  const save = useMutation({
    mutationFn: async (verify: boolean) => {
      if (verify) {
        const auth = browserSupabase()?.auth;
        if (!auth || (await auth.getSession()).data.session?.user.id !== owner) throw Error("Open the form again for your current account.");
        const { data, error } = await auth.mfa.listFactors();
        if (error) throw error;
        const factor = data.totp.find((item) => item.status === "verified");
        if (!factor) throw Error("No verified authenticator is available. Check the security settings for your account.");
        if ((await auth.getSession()).data.session?.user.id !== owner) throw Error("Open the form again for your current account.");
        const reply = await auth.mfa.challengeAndVerify({ factorId: factor.id, code });
        if (reply.error) throw Error("That code couldn’t be verified. Check your authenticator and try again.");
      }
      const requested = { maxSymbolExposurePct: Number(exposure), maxTotalDailyNotional: Number(dailyBuys) };
      const issue = accountLimitIssues(requested)[0];
      if (issue) throw Error(issue);
      const changes = {
        ...(edits.maxSymbolExposurePct !== undefined && requested.maxSymbolExposurePct !== limits.maxSymbolExposurePct
          ? { maxSymbolExposurePct: requested.maxSymbolExposurePct } : {}),
        ...(edits.maxTotalDailyNotional !== undefined && requested.maxTotalDailyNotional !== limits.maxTotalDailyNotional
          ? { maxTotalDailyNotional: requested.maxTotalDailyNotional } : {}),
      };
      return practiceCall<{ limits: Limits }>("updateAccountLimits", { limits: changes }, undefined, owner);
    },
    onSuccess: (reply) => {
      cache.setQueryData(["practice-limits", owner], reply);
      void cache.invalidateQueries({ queryKey: ["practice", owner] });
      setEdits({});
      setStepUp(false);
      setCode("");
      setSaved(true);
    },
    onError: (error) => {
      if (error instanceof PracticeError && error.code === "step_up_required") setStepUp(true);
      setError(error.message);
      setCode("");
    },
  });
  const changed = Number(exposure) !== limits.maxSymbolExposurePct || Number(dailyBuys) !== limits.maxTotalDailyNotional;

  return (
    <form className="space-y-3" onSubmit={(event) => {
      event.preventDefault();
      if (!changed || save.isPending || (stepUp && !/^\d{6}$/.test(code))) return;
      setError("");
      setSaved(false);
      save.mutate(stepUp);
    }}>
      <p>Limits apply when agents buy. The daily limit counts filled buys and sells across practice portfolios in the same currency. Manual buys show a concentration warning.</p>
      <fieldset disabled={save.isPending} className="grid gap-3 sm:grid-cols-2">
        <Field label="Maximum exposure to one asset (%)" htmlFor="practice-exposure">
          <Input id="practice-exposure" type="number" min="0" max="100" step="any" inputMode="decimal" required value={exposure}
            onChange={(event) => { setEdits({ ...edits, maxSymbolExposurePct: event.target.value }); setSaved(false); setError(""); }} />
        </Field>
        <Field label="Daily agent buy limit per currency" htmlFor="practice-daily-buys">
          <Input id="practice-daily-buys" type="number" min="0" step="any" inputMode="decimal" required value={dailyBuys}
            onChange={(event) => { setEdits({ ...edits, maxTotalDailyNotional: event.target.value }); setSaved(false); setError(""); }} />
        </Field>
        {stepUp && <Field label="Authenticator code" htmlFor="practice-limit-code">
          <Input id="practice-limit-code" autoComplete="one-time-code" inputMode="numeric" maxLength={6} value={code}
            onChange={(event) => setCode(event.target.value.replace(/\D/g, ""))} />
        </Field>}
      </fieldset>
      <div className="flex flex-wrap gap-2">
        <Button type="submit" variant="primary" disabled={!changed || save.isPending || (stepUp && code.length !== 6)}>
          {save.isPending ? "Saving…" : stepUp ? "Verify and save limits" : "Save limits"}
        </Button>
        {stepUp && <Button type="button" disabled={save.isPending} onClick={() => { setStepUp(false); setCode(""); setError(""); }}>
          Back to limits
        </Button>}
      </div>
      {error && <p role="alert" className="text-down">{error}</p>}
      {saved && <p role="status">Account practice limits saved.</p>}
    </form>
  );
}
