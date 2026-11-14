"use client";

import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { ClipboardList } from "lucide-react";
import { useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageHeader } from "@/components/ui/PageHeader";
import { Segmented } from "@/components/ui/Segmented";
import { ago } from "@/lib/format";
import { describeOmsError, OmsError, Orders } from "@/lib/oms-client";
import { useSession } from "@/lib/session";
import { GROUP_LABEL, GROUP_OF, STATUS_LABEL, STATUS_TONE, type StatusGroup } from "./status";

export function OrdersView() {
  const session = useSession();
  const [filter, setFilter] = useState<"all" | StatusGroup>("all");
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const list = useQuery({ queryKey: ["intents", userId], queryFn: () => Orders.list("all", userId), enabled: Boolean(userId), retry: false, refetchInterval: 15_000 });
  const header = <PageHeader title="Orders" description="Orders sent to a connected provider. Each one is drafted, risk-checked and approved by you before anything is submitted — and only ever to a paper environment in this build." />;

  if (session.status === "unconfigured") return <div className="mx-auto max-w-5xl">{header}<Card><EmptyState title="Accounts aren't configured" body="Order routing needs a signed-in account." /></Card></div>;
  if (session.status === "signedOut") return <div className="mx-auto max-w-5xl">{header}<Card><EmptyState icon={<ClipboardList className="h-5 w-5" />} title="Sign in to see your orders" actions={<ButtonLink href="/login" variant="primary" size="sm">Sign in</ButtonLink>} /></Card></div>;

  if (list.error instanceof OmsError && list.error.code === "not_deployed") {
    return <div className="mx-auto max-w-5xl">{header}<Card><EmptyState icon={<ClipboardList className="h-5 w-5" />} tone="warn" title="Order routing isn't deployed yet"
      body="The broker-orders function isn't running on this backend. When it is, drafted orders, approvals, submissions and fills show up here." /></Card></div>;
  }

  const intents = list.data?.intents ?? [];
  const counts = intents.reduce<Record<string, number>>((acc, i) => ({ ...acc, [GROUP_OF[i.status]]: (acc[GROUP_OF[i.status]] ?? 0) + 1 }), {});
  const shown = filter === "all" ? intents : intents.filter((i) => GROUP_OF[i.status] === filter);

  return (
    <div className="mx-auto max-w-5xl">
      {header}
      <div className="mb-3 overflow-x-auto">
        <Segmented label="Filter orders" value={filter} onChange={setFilter} options={[
          { value: "all", label: `All${intents.length ? ` · ${intents.length}` : ""}` },
          ...(Object.keys(GROUP_LABEL) as StatusGroup[]).map((g) => ({ value: g, label: `${GROUP_LABEL[g]}${counts[g] ? ` · ${counts[g]}` : ""}` })),
        ]} />
      </div>
      <Card>
        {list.isLoading || session.status === "loading" ? <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <div key={i} className="skeleton h-12" />)}</div>
          : list.isError ? (() => { const e = describeOmsError(list.error); return <EmptyState tone="down" title={e.title} body={e.body} actions={<Button size="sm" onClick={() => list.refetch()}>Try again</Button>} />; })()
            : shown.length === 0 ? <EmptyState icon={<ClipboardList className="h-5 w-5" />} title={filter === "all" ? "No orders yet" : `Nothing in “${GROUP_LABEL[filter as StatusGroup]}”`} body="Orders start from Buy or Sell on an instrument page, once a practice account is connected." />
              : (
                <div className="overflow-x-auto">
                  <table className="w-full text-left text-[13px]">
                    <thead className="border-b border-border text-xs text-text-3"><tr>{["Asset", "Side", "Type", "Size", "Account", "Status", "Updated"].map((h) => <th key={h} scope="col" className="px-4 py-2.5 font-medium">{h}</th>)}</tr></thead>
                    <tbody className="divide-y divide-border">
                      {shown.map((i) => (
                        <tr key={i.id} className="hover:bg-surface-2">
                          <td className="px-4 py-2.5 font-medium"><Link href={`/orders/${i.id}`} className="hover:underline">{i.symbol}</Link></td>
                          <td className={`px-4 py-2.5 font-medium ${i.side === "buy" ? "text-up" : "text-down"}`}>{i.side.toUpperCase()}</td>
                          <td className="px-4 py-2.5 text-text-2">{i.type.replace("_", " ")} · {i.timeInForce.toUpperCase()}</td>
                          <td className="tabular px-4 py-2.5">{i.quantity ? `${i.quantity} units` : `${i.notional} ${i.estimate.currency}`}</td>
                          <td className="px-4 py-2.5"><Badge tone={i.environment === "live" ? "live" : "warn"}>{i.provider} {i.environment}</Badge></td>
                          <td className="px-4 py-2.5"><Badge tone={STATUS_TONE[i.status]}>{STATUS_LABEL[i.status]}</Badge></td>
                          <td className="px-4 py-2.5 text-xs text-text-3">{ago(i.transitions[i.transitions.length - 1]?.at ?? i.createdAt)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
      </Card>
    </div>
  );
}
