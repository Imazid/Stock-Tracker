"use client";

import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { StrategySpec } from "@engine/strategy.ts";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input } from "@/components/ui/Field";
import { practiceCall } from "@/hooks/practice";
import { useSession } from "@/lib/session";
import { uuid } from "@/lib/uuid";

export function StartAgent({ spec, valid }: { spec: StrategySpec; valid: boolean }) {
  const session = useSession();
  const cache = useQueryClient();
  const [budget, setBudget] = useState("10000");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [created, setCreated] = useState("");
  const [attempt, setAttempt] = useState<{ fingerprint: string; key: string }>();

  return (
    <Card>
      <CardHeader title="Start a practice agent" subtitle="Each proposed trade waits for your approval. The agent uses simulated cash." />
      <div className="space-y-3 border-t border-border p-4">
        {session.status === "signedOut" && <ButtonLink href="/login?next=/strategies">Sign in</ButtonLink>}
        {session.status === "unconfigured" && <p className="text-sm text-text-3">Accounts are unavailable.</p>}
        {session.status === "signedIn" && (
          <form className="space-y-3" onSubmit={async (event) => {
            event.preventDefault();
            if (!valid || busy) return;
            const draft = { name: spec.title, mode: "paper", spec, budget: Number(budget), reviewEachPaperTrade: true };
            const fingerprint = JSON.stringify(draft);
            const key = attempt?.fingerprint === fingerprint ? attempt.key : uuid();
            setAttempt({ fingerprint, key });
            setError("");
            setBusy(true);
            try {
              const reply = await practiceCall<{ agent: { name: string } }>("createAgent", { draft }, key);
              setCreated(reply.agent.name);
              setAttempt(undefined);
              await cache.invalidateQueries({ queryKey: ["practice", session.user.id] });
            } catch (failure) {
              setError(failure instanceof Error ? failure.message : "The agent couldn’t be started.");
            } finally {
              setBusy(false);
            }
          }}>
            <Field label="Practice budget" htmlFor="agent-budget">
              <Input id="agent-budget" type="number" min="1" max="10000000" step="0.01" value={budget} required onChange={(e) => setBudget(e.target.value)} />
            </Field>
            <Button type="submit" variant="primary" disabled={!valid || busy}>{busy ? "Starting…" : "Start practice agent"}</Button>
          </form>
        )}
        {error && <p role="alert" className="text-sm text-down">{error}</p>}
        {created && <div className="flex flex-wrap items-center gap-3"><p role="status" className="text-sm">{created} is active.</p><ButtonLink href="/agents" size="sm">Open Agent Studio</ButtonLink></div>}
      </div>
    </Card>
  );
}
