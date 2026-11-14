"use client";

import { useState } from "react";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import type { AgentActivityDetail, AgentActivityPage, AgentActivityRow } from "@engine/activity.ts";
import { proposalStatusDisplayName } from "@engine/agent.ts";
import { orderStatusDisplayName } from "@engine/orders.ts";
import { riskCheckTitle } from "@engine/risk.ts";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { practiceCall } from "@/hooks/practice";
import { dateTime, money, plainNumber } from "@/lib/format";

const time = (ms: number) => dateTime(new Date(ms).toISOString());
const outcomeLabel = { ok: "Passed", info: "Info", warning: "Warning", blocked: "Blocked", failed: "Failed" } as const;
const riskLabel = { passed: "Passed", warning: "Warning", failed: "Failed", notApplicable: "Not applicable" } as const;

export function AgentTimeline({ userID, agents }: { userID: string; agents: { id: string; name: string }[] }) {
  const [filter, setFilter] = useState("");
  const [open, setOpen] = useState("");
  const activity = useInfiniteQuery({
    queryKey: ["agentActivity", userID, filter],
    initialPageParam: undefined as string | undefined,
    queryFn: async ({ pageParam }) => (await practiceCall<{ page: AgentActivityPage }>("agentActivity", {
      agentID: filter || undefined, before: pageParam,
    })).page,
    getNextPageParam: (last) => last.nextCursor,
    refetchInterval: 30_000,
  });
  const runs = activity.data?.pages.flatMap((page) => page.runs) ?? [];

  return (
    <Card id="agent-activity">
      <CardHeader title="Agent activity timeline" />
      <div className="flex flex-wrap items-center gap-2 px-4 pb-3 text-sm">
        <label htmlFor="activity-agent">Filter by agent</label>
        <select id="activity-agent" value={filter} onChange={(event) => { setFilter(event.target.value); setOpen(""); }}
          className="min-h-9 max-w-full rounded-lg border border-border bg-surface-2 px-2 text-text">
          <option value="">All agents</option>
          {agents.map((agent) => <option key={agent.id} value={agent.id}>{agent.name}</option>)}
        </select>
      </div>
      {activity.isPending ? <p role="status" className="px-4 pb-4 text-sm text-text-2">Loading activity…</p>
        : activity.isError && !activity.data ? <EmptyState title="Couldn’t load activity" tone="down" actions={<Button onClick={() => void activity.refetch()}>Retry</Button>} />
        : runs.length ? <ul className="divide-y divide-border border-t border-border">
          {runs.map((run) => <TimelineRun key={run.id} run={run} userID={userID} open={open === run.id}
            toggle={() => setOpen(open === run.id ? "" : run.id)} />)}
        </ul> : <EmptyState title="No recorded runs yet" />}
      {activity.hasNextPage && <div className="space-y-2 p-4">
        {activity.isFetchNextPageError && <p role="status" className="text-sm text-down">Couldn’t load older activity.</p>}
        <Button disabled={activity.isFetching} onClick={() => void activity.fetchNextPage()}>
          {activity.isFetchingNextPage ? "Loading…" : "Load older runs"}
        </Button>
      </div>}
    </Card>
  );
}

function TimelineRun({ userID, run, open, toggle }: { userID: string; run: AgentActivityRow; open: boolean; toggle: () => void }) {
  const audit = useQuery({
    queryKey: ["agentActivityDetail", userID, run.id], enabled: open,
    queryFn: async () => (await practiceCall<{ detail: AgentActivityDetail }>("agentActivityDetail", { runID: run.id })).detail,
    refetchInterval: 30_000,
  });
  return <li className="px-4 py-3">
    <button aria-expanded={open} aria-controls={`run-${run.id}`} className="w-full space-y-1 text-left" onClick={toggle}>
      <span className="flex flex-wrap items-center gap-2 text-sm font-medium">
        {run.agentName}<Badge tone={run.status === "failed" ? "down" : "neutral"} className="capitalize">{run.status}</Badge>
      </span>
      <span className="block text-xs text-text-2">{time(run.startedAt)} · {run.trigger === "manual" ? "Manual check" : "Scheduled check"} · Version {run.strategyVersion}</span>
      {run.summary && <span className="block text-sm text-text-2">{run.summary}</span>}
    </button>
    <div id={`run-${run.id}`} hidden={!open}>
      {open && (audit.isPending ? <p role="status" className="mt-3 text-sm text-text-2">Loading decision evidence…</p>
        : audit.isError && !audit.data ? <div className="mt-3 space-y-2"><p role="status" className="text-sm text-down">Couldn’t load this run.</p><Button size="sm" onClick={() => void audit.refetch()}>Retry</Button></div>
        : audit.data && <RunEvidence detail={audit.data} />)}
    </div>
  </li>;
}

function RunEvidence({ detail }: { detail: AgentActivityDetail }) {
  const { run, signals, proposals, orders, fills, reviews } = detail;
  return <div className="mt-3 space-y-4 border-l border-border pl-3 text-sm">
    <div className="space-y-1 text-xs text-text-2"><p>Finished {time(run.finishedAt)}</p><p className="break-all">Run ID {run.id}</p></div>
    {run.steps.length > 0 && <section className="space-y-2">
      <h3 className="font-medium">Decision evidence</h3>
      <ol className="space-y-2">
        {run.steps.map((step) => <li key={step.id} className="space-y-1">
          <p className="flex flex-wrap items-center gap-2"><Badge tone={step.outcome === "blocked" || step.outcome === "failed" ? "down" : step.outcome === "warning" ? "warn" : "neutral"}>{outcomeLabel[step.outcome]}</Badge>{step.title}</p>
          {step.detail && <p className="text-text-2">{step.detail}</p>}
          {step.evidence.length > 0 && <ul className="space-y-1 pl-3 text-xs text-text-2">
            {step.evidence.map((item, index) => <li key={index}>{item.label} · {item.value}{item.passed === undefined ? "" : item.passed ? " · Met" : " · Not met"}</li>)}
          </ul>}
        </li>)}
      </ol>
    </section>}
    {signals.length > 0 && <section className="space-y-2">
      <h3 className="font-medium">Market data used</h3>
      <ul className="space-y-1 text-text-2">{signals.map((signal) => <li key={signal.id}>
        {signal.instrument.symbol} · {signal.provenance.source}{signal.provenance.kind === "fixture" ? " (test data)" : signal.provenance.delaySeconds ? ` (${signal.provenance.delaySeconds}s delay)` : ""} · Bar dated {time(signal.barTime)} · Close {money(signal.close, signal.instrument.currency)}
      </li>)}</ul>
    </section>}
    {proposals.length > 0 && <section className="space-y-2">
      <h3 className="font-medium">Proposals and approval</h3>
      <ul className="space-y-3">{proposals.map((proposal) => {
        const review = reviews.find((event) => event.proposalID === proposal.id);
        return <li key={proposal.id} className="space-y-1">
          <p className="flex flex-wrap items-center gap-2"><span className="capitalize">{proposal.side} {plainNumber(proposal.quantity, 8)} {proposal.instrument.symbol}</span><Badge>{proposalStatusDisplayName(proposal.status)}</Badge></p>
          <p className="text-text-2">{money(proposal.notional, proposal.instrument.currency)} · Proposed {time(proposal.createdAt)}</p>
          {review && <p>{review.kind === "proposalApproved" ? "You approved" : "You declined"} · {time(review.time)}</p>}
          {!review && proposal.orderID && <p>Submitted under the agent’s practice permissions</p>}
          {proposal.resolutionNote && <p className="text-text-2">{proposal.resolutionNote}</p>}
          <p className="break-all text-xs text-text-2">Proposal ID {proposal.id}</p>
          <details>
            <summary className="w-fit cursor-pointer text-text-2">Risk checks · {time(proposal.risk.evaluatedAt)}</summary>
            <ul className="space-y-1 py-1 pl-3 text-xs text-text-2">{proposal.risk.checks.map((check) => <li key={check.id}>{riskCheckTitle(check.id)} · {riskLabel[check.status]} · {check.detail}</li>)}</ul>
          </details>
        </li>;
      })}</ul>
    </section>}
    {orders.length > 0 && <section className="space-y-2">
      <h3 className="font-medium">Practice orders and fills</h3>
      <ul className="space-y-3">{orders.map((order) => <li key={order.id} className="space-y-1">
        <p className="flex flex-wrap items-center gap-2"><span className="capitalize">{order.side} {plainNumber(order.quantity, 8)} {order.instrument.symbol}</span><Badge>{orderStatusDisplayName(order.status)}</Badge></p>
        <p className="text-text-2">Updated {time(order.updatedAt)}{order.statusNote && ` · ${order.statusNote}`}</p>
        <p className="break-all text-xs text-text-2">Order ID {order.id}</p>
        <ul className="space-y-1 pl-3">{fills.filter((fill) => fill.orderID === order.id).map((fill) => <li key={fill.id} className="text-xs text-text-2">
          <p>{plainNumber(fill.quantity, 8)} filled at {money(fill.price, fill.instrument.currency)} · Fee {money(fill.fee, fill.instrument.currency)} · {time(fill.time)}</p>
          <p className="break-all">Fill ID {fill.id}</p>
        </li>)}</ul>
      </li>)}</ul>
    </section>}
  </div>;
}
