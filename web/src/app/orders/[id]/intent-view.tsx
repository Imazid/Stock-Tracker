"use client";

import type { OrderIntentView } from "@oms/api.ts";
import Link from "next/link";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, CheckCircle2, CircleAlert, MinusCircle, XCircle } from "lucide-react";
import { useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Notice } from "@/components/ui/Notice";
import { dateTime } from "@/lib/format";
import { describeOmsError, newIdempotencyKey, OmsError, Orders } from "@/lib/oms-client";
import { useNow } from "@/hooks/useNow";
import { useSession } from "@/lib/session";
import { STATUS_LABEL, STATUS_TONE } from "../status";

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[150px_1fr] gap-3 px-4 py-2 text-[13px]">
      <dt className="text-text-3">{label}</dt>
      <dd className="min-w-0 text-text">{children}</dd>
    </div>
  );
}

function CheckIcon({ status }: { status: string }) {
  if (status === "passed") return <CheckCircle2 aria-label="Passed" className="h-4 w-4 shrink-0 text-up" />;
  if (status === "failed") return <XCircle aria-label="Failed" className="h-4 w-4 shrink-0 text-down" />;
  if (status === "warning") return <CircleAlert aria-label="Warning" className="h-4 w-4 shrink-0 text-warn" />;
  return <MinusCircle aria-label="Not applicable" className="h-4 w-4 shrink-0 text-text-3" />;
}

export function IntentView({ id }: { id: string }) {
  const session = useSession();
  const client = useQueryClient();
  const now = useNow();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const intent = useQuery({ queryKey: ["intent", id], queryFn: () => Orders.get(id), enabled: Boolean(userId), retry: false, refetchInterval: 10_000 });
  // One idempotency key per button press target, so a double click can't act twice.
  const [keys] = useState(() => ({ riskCheck: newIdempotencyKey(), approve: newIdempotencyKey(), reject: newIdempotencyKey(), submit: newIdempotencyKey(), cancel: newIdempotencyKey(), reconcile: newIdempotencyKey() }));
  const act = useMutation({
    mutationFn: (a: "riskCheck" | "approve" | "reject" | "submit" | "cancel" | "reconcile") => {
      const view = intent.data!.intent;
      if (a === "approve") return Orders.act({ action: "approve", intentID: view.id, intentHash: view.intentHash }, keys.approve);
      return Orders.act({ action: a, intentID: view.id } as Parameters<typeof Orders.act>[0], keys[a]);
    },
    onSuccess: (data) => {
      client.setQueryData(["intent", id], data);
      client.invalidateQueries({ queryKey: ["intents"] });
    },
  });

  if (session.status !== "signedIn") {
    return <EmptyState title={session.status === "unconfigured" ? "Accounts aren't configured" : "Sign in to see this order"} />;
  }
  if (intent.isLoading) return <div className="mx-auto max-w-4xl space-y-3"><div className="skeleton h-8 w-48" /><div className="skeleton h-80" /></div>;
  if (intent.isError) {
    const e = describeOmsError(intent.error);
    return <div className="mx-auto max-w-4xl"><Card><EmptyState tone={intent.error instanceof OmsError && intent.error.code === "not_deployed" ? "warn" : "down"} title={e.title} body={e.body} /></Card></div>;
  }
  const v: OrderIntentView = intent.data!.intent;
  const ccy = v.estimate.currency;
  const riskPassed = v.risk?.result === "pass";
  const err = act.isError ? describeOmsError(act.error) : null;
  const approvalExpired = v.approval ? Date.parse(v.approval.expiresAt) < now : false;

  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/orders" className="mb-3 inline-flex items-center gap-1 text-xs text-text-2 hover:text-text"><ArrowLeft aria-hidden className="h-3.5 w-3.5" />Orders</Link>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <h1 className="text-xl font-semibold tracking-tight"><span className={v.side === "buy" ? "text-up" : "text-down"}>{v.side.toUpperCase()}</span> {v.symbol}</h1>
        <Badge tone={STATUS_TONE[v.status]}>{STATUS_LABEL[v.status]}</Badge>
        <Badge tone={v.environment === "live" ? "live" : "warn"}>{v.environment === "live" ? "LIVE — real money" : `${v.environment.toUpperCase()} — no real money`}</Badge>
      </div>

      <div className="grid gap-5 lg:grid-cols-[1fr_320px]">
        <div className="flex min-w-0 flex-col gap-5">
          <Card>
            <CardHeader title="What you're approving" subtitle={`Approval covers exactly this order (fingerprint ${v.intentHash.slice(0, 12)}…). Any change needs a new approval.`} />
            <dl className="divide-y divide-border border-t border-border">
              <Row label="Asset">{v.symbol} <span className="text-text-3">({v.assetClass === "crypto" ? "crypto pair" : "US equity"})</span></Row>
              <Row label="Side"><span className={v.side === "buy" ? "text-up" : "text-down"}>{v.side === "buy" ? "Buy" : "Sell"}</span></Row>
              <Row label="Account">{v.provider} · {v.environment}</Row>
              <Row label="Order type">{v.type.replace("_", " ")} · {v.timeInForce.toUpperCase()}</Row>
              <Row label={v.quantity ? "Quantity" : "Amount"}>{v.quantity ?? `${v.notional} ${ccy}`}</Row>
              {v.limitPrice ? <Row label="Limit price">{v.limitPrice} {ccy}</Row> : null}
              {v.stopPrice ? <Row label="Stop price">{v.stopPrice} {ccy}</Row> : null}
              <Row label="Quote currency">{ccy}</Row>
              <Row label="Estimated value">{v.estimate.notional ? `${v.estimate.notional} ${ccy}` : "—"}</Row>
              <Row label="Estimated fees">{v.estimate.fee ? `${v.estimate.fee} ${v.estimate.feeCurrency ?? ccy}` : "—"}</Row>
              <Row label="Price used">{v.risk ? <>{v.risk.price.value} {v.risk.price.currency} · {v.risk.price.source} · {dateTime(v.risk.price.observedAt)} <Badge tone={v.risk.price.status === "real_time" ? "up" : "warn"}>{v.risk.price.status.replace("_", "-")}</Badge></> : "Not checked yet"}</Row>
              <Row label="Drafted by">{v.origin.kind === "manual" ? "You" : <>Agent <span className="font-mono text-xs">{v.origin.agentID.slice(0, 8)}</span></>}</Row>
              {v.origin.kind === "agent" ? <Row label="Agent's reasoning"><span className="whitespace-pre-wrap text-text-2">{v.origin.rationale}</span> <span className="block text-[11px] text-text-3">Model-written explanation — not a verified forecast.</span></Row> : null}
              <Row label="Draft expires">{dateTime(v.expiresAt)}</Row>
              {v.approval ? <Row label="Approval">Approved {dateTime(v.approval.approvedAt)} ({v.approval.aal === "aal2" ? "with MFA" : "password only"}) · expires {dateTime(v.approval.expiresAt)}{v.approval.consumedAt ? ` · used ${dateTime(v.approval.consumedAt)}` : ""}{approvalExpired && !v.approval.consumedAt ? <Badge tone="warn" className="ml-1">expired</Badge> : null}</Row> : null}
              <Row label="Client order id"><span className="font-mono text-xs">{v.clientOrderID}</span></Row>
            </dl>
          </Card>

          <Card>
            <CardHeader title="Risk checks" subtitle={v.risk ? `Policy v${v.risk.policyVersion} · ${dateTime(v.risk.evaluatedAt)} · re-run at submission` : "Run before approval; run again automatically when submitting."}
              actions={v.risk ? <Badge tone={riskPassed ? "up" : "down"}>{riskPassed ? "Passed" : "Failed"}</Badge> : null} />
            {v.risk ? (
              <ul className="divide-y divide-border border-t border-border">
                {v.risk.checks.map((c) => <li key={c.id} className="flex gap-2.5 px-4 py-2 text-[13px]"><CheckIcon status={c.status} /><span className="min-w-0"><span className="font-medium text-text">{c.id}</span> <span className="text-text-2">{c.detail}</span></span></li>)}
              </ul>
            ) : <p className="border-t border-border px-4 py-3 text-xs text-text-3">Not checked yet.</p>}
            {v.risk && v.risk.reasonCodes.length ? <p className="border-t border-border px-4 py-2 text-xs text-down">Reasons: {v.risk.reasonCodes.join(", ")}</p> : null}
          </Card>
        </div>

        <div className="flex flex-col gap-5">
          <Card>
            <CardHeader title="Next step" />
            <div className="flex flex-col gap-2 border-t border-border p-4">
              {v.status === "draft" ? <Button variant="primary" onClick={() => act.mutate("riskCheck")} disabled={act.isPending}>Run risk check</Button> : null}
              {(v.status === "risk_checked" || v.status === "awaiting_approval") && riskPassed ? (
                <>
                  <Button variant={v.side === "buy" ? "buy" : "sell"} onClick={() => act.mutate("approve")} disabled={act.isPending}>Approve this {v.side}</Button>
                  <p className="text-[11px] text-text-3">Approving doesn&apos;t send it yet. Submission re-checks the price, your limits and the kill switch first.</p>
                </>
              ) : null}
              {(v.status === "risk_checked" || v.status === "awaiting_approval") && !riskPassed ? <Notice tone="down">The risk checks failed, so this order can&apos;t be approved. Change it and draft again.</Notice> : null}
              {v.status === "approved" ? <Button variant="primary" onClick={() => act.mutate("submit")} disabled={act.isPending || approvalExpired}>Submit to {v.provider} {v.environment}</Button> : null}
              {["draft", "risk_checked", "awaiting_approval", "approved"].includes(v.status) ? <Button variant="ghost" onClick={() => act.mutate("reject")} disabled={act.isPending}>Reject</Button> : null}
              {["submitted", "partially_filled"].includes(v.status) ? <Button variant="danger" onClick={() => act.mutate("cancel")} disabled={act.isPending}>Request cancel</Button> : null}
              {["submitted", "partially_filled", "reconciliation_required", "submitting"].includes(v.status) ? <Button onClick={() => act.mutate("reconcile")} disabled={act.isPending}>Check status with broker</Button> : null}
              {v.status === "reconciliation_required" ? <Notice tone="warn" title="Waiting on the broker">The broker&apos;s answer was unclear, so this order is being checked before anything else happens. It is never resent automatically.</Notice> : null}
              {["filled", "rejected", "expired", "cancelled", "failed"].includes(v.status) ? <p className="text-xs text-text-3">This order is finished.</p> : null}
              {err ? <Notice tone="down" title={err.title}>{err.body}</Notice> : null}
            </div>
          </Card>
          {v.brokerOrder ? (
            <Card>
              <CardHeader title="At the broker" />
              <dl className="divide-y divide-border border-t border-border">
                <Row label="Order id"><span className="font-mono text-xs">{v.brokerOrder.providerOrderID}</span></Row>
                <Row label="Status">{v.brokerOrder.status.replace("_", " ")}</Row>
                <Row label="Filled">{v.brokerOrder.filledQuantity}{v.brokerOrder.averageFillPrice ? ` @ ${v.brokerOrder.averageFillPrice} ${ccy}` : ""}</Row>
              </dl>
            </Card>
          ) : null}
          <Card>
            <CardHeader title="History" />
            <ol className="space-y-2 border-t border-border px-4 py-3">
              {v.transitions.map((t, i) => (
                <li key={i} className="text-xs"><Badge tone={STATUS_TONE[t.to]}>{STATUS_LABEL[t.to]}</Badge> <span className="text-text-3">{dateTime(t.at)}</span>{t.note ? <span className="block pl-1 pt-0.5 text-text-2">{t.note}</span> : null}</li>
              ))}
            </ol>
          </Card>
        </div>
      </div>
    </div>
  );
}
