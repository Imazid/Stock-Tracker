"use client";

import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { policyIssues, standardPolicy } from "@engine/risk.ts";
import type { AgentDraft } from "@engine/state.ts";
import type { StrategySpec } from "@engine/strategy.ts";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Input } from "@/components/ui/Field";
import { practiceCall } from "@/hooks/practice";
import { useSession } from "@/lib/session";
import { uuid } from "@/lib/uuid";

export function StartAgent({ spec, valid, parsedDraft }: { spec: StrategySpec; valid: boolean; parsedDraft?: AgentDraft }) {
  const session = useSession();
  const cache = useQueryClient();
  const [budget, setBudget] = useState(String(parsedDraft?.budget ?? 10_000));
  const [positionLimit, setPositionLimit] = useState(String(parsedDraft?.maxPositionPct ?? 10));
  const [interval, setInterval] = useState(String(parsedDraft?.schedule.intervalMinutes ?? 60));
  const [risk, setRisk] = useState(() => ({
    dailyLoss: String(parsedDraft?.riskPolicy?.maxDailyLossPct ?? 3),
    drawdown: String(parsedDraft?.riskPolicy?.maxDrawdownPct ?? 15),
  }));
  const canStart = parsedDraft?.mode === undefined || parsedDraft.mode === "paper";
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
            if (!valid || busy || !canStart) return;
            const amount = Number(budget), position = Number(positionLimit);
            const policy = standardPolicy(amount, position, spec.universe.length > 0 && spec.universe.every(asset => asset.assetClass === "crypto"), spec.universe[0]?.currency);
            policy.maxPositionPct = position;
            policy.maxDailyLossPct = Number(risk.dailyLoss);
            policy.maxDrawdownPct = Number(risk.drawdown);
            const invalid = policyIssues(policy)[0];
            if (invalid) { setError(invalid); return; }
            const draft = { name: spec.title, mode: "paper", spec, budget: amount, maxPositionPct: position,
              riskPolicy: policy, schedule: { intervalMinutes: Number(interval) }, reviewEachPaperTrade: true };
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
            <Field label="Maximum position (%)" htmlFor="agent-position">
              <Input id="agent-position" type="number" min="0.01" max="100" step="0.01" value={positionLimit} required onChange={(e) => setPositionLimit(e.target.value)} />
            </Field>
            <Field label="Check every (minutes)" htmlFor="agent-interval">
              <Input id="agent-interval" type="number" min="5" max="10080" step="1" value={interval} required onChange={(e) => setInterval(e.target.value)} />
            </Field>
            <Field label="Daily loss limit (%)" htmlFor="agent-loss">
              <Input id="agent-loss" type="number" min="0.01" max="100" step="0.01" value={risk.dailyLoss} required onChange={(e) => setRisk({ ...risk, dailyLoss: e.target.value })} />
            </Field>
            <Field label="Drawdown limit (%)" htmlFor="agent-drawdown">
              <Input id="agent-drawdown" type="number" min="0.01" max="100" step="0.01" value={risk.drawdown} required onChange={(e) => setRisk({ ...risk, drawdown: e.target.value })} />
            </Field>
            {!canStart && <p className="text-sm text-text-2">This draft requests {parsedDraft?.mode === "signals" ? "signals" : "research only"}. Review and activate that mode in the iPhone Agent Studio.</p>}
            <Button type="submit" variant="primary" disabled={!valid || busy || !canStart}>{busy ? "Starting…" : "Start practice agent"}</Button>
          </form>
        )}
        {error && <p role="alert" className="text-sm text-down">{error}</p>}
        {created && <div className="flex flex-wrap items-center gap-3"><p role="status" className="text-sm">{created} is active.</p><ButtonLink href="/agents" size="sm">Open Agent Studio</ButtonLink></div>}
      </div>
    </Card>
  );
}
