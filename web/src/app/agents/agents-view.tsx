"use client";

import { useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageHeader } from "@/components/ui/PageHeader";
import { practiceCall, usePractice } from "@/hooks/practice";
import { dateTime, money } from "@/lib/format";
import { uuid } from "@/lib/uuid";

const time = (ms: number) => dateTime(new Date(ms).toISOString());

export function AgentsView() {
  const { session, query } = usePractice();
  const [busy, setBusy] = useState("");
  const [feedback, setFeedback] = useState("");
  const agents = query.data?.agents ?? [];
  const proposals = query.data?.proposals.filter((proposal) => proposal.status === "pending") ?? [];
  const runs = query.data?.runs.slice().reverse().slice(0, 12) ?? [];

  async function act(action: string, id: string, proposal = false) {
    setBusy(id);
    setFeedback("");
    try {
      const reply = await practiceCall<{ accepted?: boolean; summary?: string }>(action, { [proposal ? "proposalID" : "agentID"]: id }, uuid());
      if (reply.accepted === false) setFeedback(reply.summary ?? "The proposal was blocked.");
      await query.refetch();
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "The agent action failed.");
    } finally {
      setBusy("");
    }
  }

  return (
    <div className="mx-auto max-w-4xl space-y-5">
      <PageHeader title="Agent Studio" description="Review practice proposals and inspect what your agents did." />
      {session.status === "signedOut" ? <Card><EmptyState title="Sign in to manage your agents" actions={<ButtonLink href="/login?next=/agents" variant="primary">Sign in</ButtonLink>} /></Card>
        : session.status === "unconfigured" ? <Card><EmptyState title="Accounts are unavailable" /></Card>
        : session.status === "loading" || query.isPending ? <div className="skeleton h-24" role="status" aria-label="Loading agents" />
        : query.isError ? <Card><EmptyState title="Couldn’t load agents" tone="down" actions={<Button onClick={() => void query.refetch()}>Retry</Button>} /></Card>
        : <>
          <Card>
            <CardHeader title="Agents" actions={<ButtonLink href="/strategies" size="sm">Strategy Studio</ButtonLink>} />
            {agents.length ? <ul className="divide-y divide-border border-t border-border">
              {agents.map((agent) => <li key={agent.id} className="flex flex-wrap justify-between gap-3 px-4 py-3">
                <div className="space-y-1">
                  <div className="flex items-center gap-2"><span className="font-medium">{agent.name}</span><Badge>{agent.status}</Badge></div>
                  <p className="text-xs text-text-2">{agent.mode === "paper" ? "Practice" : agent.mode === "researchOnly" ? "Research" : "Signals"} · Every {agent.schedule.intervalMinutes} min{agent.lastRunAt ? ` · Last run ${time(agent.lastRunAt)}` : ""}</p>
                  {agent.lastError && <p className="text-xs text-down">{agent.lastError}</p>}
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button size="sm" disabled={!!busy || agent.status !== "active"} onClick={() => void act("runAgent", agent.id)}>Run now</Button>
                  {agent.status !== "stopped" && <Button size="sm" disabled={!!busy} onClick={() => void act(agent.status === "active" ? "pauseAgent" : "resumeAgent", agent.id)}>{agent.status === "active" ? "Pause" : "Resume"}</Button>}
                </div>
              </li>)}
            </ul> : <EmptyState title="No agents yet" body="Build a strategy and start a practice agent in Strategy Studio." />}
          </Card>
          <Card>
            <CardHeader title="Proposals awaiting review" />
            {proposals.length ? <ul className="divide-y divide-border border-t border-border">
              {proposals.map((proposal) => {
                const currency = proposal.instrument.currency;
                return <li key={proposal.id} className="space-y-2 px-4 py-3">
                  <p className="font-medium">{proposal.headline}</p>
                  <p className="text-sm text-text-2 capitalize">{proposal.side} {proposal.quantity} {proposal.instrument.symbol} · {money(proposal.notional, currency)} · Estimated fee {money(proposal.estimatedFee, currency)}</p>
                  <p className="text-xs text-text-3">Signal {time(proposal.signalBarTime)} · Expires {time(proposal.expiresAt)}</p>
                  {proposal.risk.checks.filter((check) => check.status === "warning" || check.status === "failed").map((check) => <p key={check.id} className="text-xs text-warn">{check.detail}</p>)}
                  <div className="flex flex-wrap gap-2">
                    <Button size="sm" disabled={!!busy} onClick={() => void act("rejectProposal", proposal.id, true)}>Decline</Button>
                    <Button size="sm" variant="primary" disabled={!!busy} onClick={() => void act("approveProposal", proposal.id, true)}>Approve practice proposal</Button>
                  </div>
                </li>;
              })}
            </ul> : <EmptyState title="No proposals awaiting review" />}
          </Card>
          {feedback && <p role="status" className="rounded-lg border border-border bg-surface p-3 text-sm">{feedback}</p>}
          <Card>
            <CardHeader title="Recent runs" />
            {runs.length ? <ul className="divide-y divide-border border-t border-border">
              {runs.map((run) => <li key={run.id} className="px-4 py-3">
                <details>
                  <summary className="cursor-pointer text-sm">
                    {agents.find((agent) => agent.id === run.agentID)?.name ?? "Agent"} · {run.status} · {time(run.startedAt)}
                  </summary>
                  <ul className="mt-2 space-y-1 pl-4 text-xs text-text-2">
                    {run.steps.map((step, index) => <li key={index}>{step.title} · {step.detail}</li>)}
                  </ul>
                </details>
              </li>)}
            </ul> : <EmptyState title="No recorded runs yet" />}
          </Card>
        </>}
    </div>
  );
}
