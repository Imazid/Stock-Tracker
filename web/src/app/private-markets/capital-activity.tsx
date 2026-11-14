"use client";

import { useState } from "react";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Notice } from "@/components/ui/Notice";
import { SourceLink } from "./catalog";
import { accountHoldingsQuery } from "./account-holdings";
import { manualPortfolioQuery } from "./manual-portfolio";
import { dateLabel, dayInSydney, groupedDecimal, privateMarkets, providerName, sourceHref, type CapitalActivityItem } from "./private-data";

type Section = "calls" | "history";
type CapitalActivityPage = { items: CapitalActivityItem[]; next_offset: number | null };

const statusLabels = {
  contribution: "Contribution", upcoming: "Upcoming", overdue: "Overdue", paid: "Paid", cancelled: "Cancelled", distribution: "Distribution", sale: "Settled sale",
};

function CapitalActivityList({ owner, section, title, empty }: { owner: string; section: Section; title: string; empty: string }) {
  const activity = useInfiniteQuery({
    queryKey: ["private-markets", owner, "capital-activity", section],
    gcTime: 0, retry: false, initialPageParam: 0,
    queryFn: ({ pageParam, signal }) => privateMarkets<CapitalActivityPage>("capital_activity", { owner, section, offset: pageParam, signal }),
    getNextPageParam: (page) => page.next_offset ?? undefined,
  });
  const items = [...new Map(activity.data?.pages.flatMap((page) => page.items.map((item) =>
    [`${item.status}:${item.id}`, item] as const))).values()];

  return <Card className="min-w-0">
    <CardHeader title={title} actions={
      <Button size="sm" disabled={activity.isFetching} onClick={() => void activity.refetch()}>Refresh</Button>
    } />
    {activity.isPending && <p role="status" className="border-t border-border p-4 text-sm text-text-2">Loading capital activity…</p>}
    {activity.error && <div className="border-t border-border p-4">
      <Notice tone="down">{activity.error.message}</Notice>
    </div>}
    {activity.data && !items.length && <EmptyState title={empty} className="border-t border-border" />}
    <ul>{items.map((item) => <li key={`${item.status}:${item.id}`} className="space-y-1 border-t border-border p-4 text-sm">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <h3 className="min-w-0 break-words font-medium text-text">{item.holding_name}</h3>
        <Badge tone={item.status === "overdue" ? "warn" : item.status === "distribution" ? "up" : "neutral"}>
          {statusLabels[item.status]}
        </Badge>
      </div>
      <p className="break-words font-medium tabular-nums">{item.currency} {groupedDecimal(item.amount)}</p>
      <p className="text-xs text-text-2">
        {providerName(item.provider)} · {section === "calls" ? "Due " : ""}{dateLabel(item.occurred_on)}
        {section === "history" && item.due_on && ` · Originally due ${dateLabel(item.due_on)}`}
      </p>
      <p className="break-words text-xs text-text-2">
        {sourceHref(item.source) ? <SourceLink url={item.source}>Read provider source</SourceLink> : item.source}
      </p>
    </li>)}</ul>
    {activity.hasNextPage && <div className="border-t border-border p-4">
      <Button size="sm" disabled={activity.isFetching} onClick={() => void activity.fetchNextPage()}>
        {activity.isFetchingNextPage ? "Loading…" : section === "calls" ? "Load more calls" : "Load more activity"}
      </Button>
    </div>}
  </Card>;
}

function ManualCapitalActivity({ owner }: { owner: string }) {
  const activity = useQuery(manualPortfolioQuery(owner));
  const account = useQuery(accountHoldingsQuery(owner));
  const [limit, setLimit] = useState(25);
  const snapshot = activity.error ? null : activity.data?.snapshot;
  const today = dayInSydney(Math.max(activity.dataUpdatedAt, account.dataUpdatedAt));
  const published = snapshot?.holdings.flatMap((holding) => (holding.capitalActivity ?? []).map((record) => ({
    ...record, holdingId: holding.id, name: holding.name, currency: holding.currency, origin: "snapshot",
  }))) ?? [];
  const shared = (account.error ? [] : account.data?.holdings ?? []).filter((holding) => !holding.providerMatch)
    .flatMap((holding) => [...(holding.cashFlows ?? []), ...(holding.sales ?? [])].map((record) => ({
      ...record, holdingId: holding.id, name: holding.name, currency: holding.currency, origin: "account",
    })));
  const records = [...shared, ...published];
  const pending = records.filter((record) => record.status === "pending").sort((a, b) => a.date.localeCompare(b.date));
  const history = records.filter((record) => record.status !== "pending").sort((a, b) => b.date.localeCompare(a.date));
  const ordered = [...pending, ...history];

  return <Card as="section" aria-label="Self-reported capital activity">
    <CardHeader title="Self-reported capital activity" subtitle={snapshot
      ? `Snapshot published from iPhone ${dateLabel(snapshot.updated_at, "time")}.`
      : shared.length ? "Cash flows recorded in your account holdings." : "Include capital activity when publishing your portfolio snapshot on iPhone."} actions={
      <Button size="sm" disabled={activity.isFetching || account.isFetching} onClick={() => { void activity.refetch(); void account.refetch(); }}>Refresh</Button>
    } />
    {(activity.isPending || account.isPending) && <p role="status" className="border-t border-border p-4 text-sm text-text-2">Checking for self-reported capital activity…</p>}
    {activity.error && <div className="border-t border-border p-4"><Notice tone="down">{activity.error.message}</Notice></div>}
    {account.error && <div className="border-t border-border p-4"><Notice tone="down">{account.error.message}</Notice></div>}
    {snapshot && !ordered.length && <EmptyState title="No self-reported capital activity in this snapshot" className="border-t border-border" />}
    <ul>{ordered.slice(0, limit).map((record) => {
      const status = record.status === "pending" ? (record.date < today ? "overdue" : "upcoming") : record.status;
      return <li key={`${record.origin}:${record.holdingId}:${record.id}`} className="space-y-1 border-t border-border p-4 text-sm">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <h3 className="min-w-0 break-words font-medium text-text">{record.name}</h3>
          <Badge tone={status === "overdue" ? "warn" : "neutral"}>{statusLabels[status]}</Badge>
        </div>
        <p className="break-words font-medium tabular-nums">{record.currency} {groupedDecimal(record.amount)}</p>
        <p className="text-xs text-text-2">{record.status === "pending" ? "Due " : ""}{dateLabel(record.date)}</p>
        {record.resolutionSource && <p className="break-words text-xs text-text-2">{record.resolutionSource}</p>}
        {record.dueOn && <p className="text-xs text-text-2">Originally due {dateLabel(record.dueOn)}</p>}
        <p className="break-words text-xs text-text-2">{record.source}</p>
      </li>;
    })}</ul>
    {ordered.length > limit && <div className="border-t border-border p-4">
      <Button size="sm" onClick={() => setLimit((count) => count + 25)}>Load more self-reported activity</Button>
    </div>}
  </Card>;
}

export function CapitalActivity({ owner }: { owner: string }) {
  return <section aria-labelledby="capital-activity-heading" className="space-y-4">
    <div>
      <h2 id="capital-activity-heading" className="font-semibold text-text">Capital Activity</h2>
      <p className="text-sm text-text-2">Provider records use Sydney dates. Amounts stay in their original currency.</p>
    </div>
    <div className="grid items-start gap-4 lg:grid-cols-2">
      <CapitalActivityList owner={owner} section="calls" title="Outstanding capital calls" empty="No outstanding capital calls" />
      <CapitalActivityList owner={owner} section="history" title="Capital history" empty="No confirmed capital activity" />
    </div>
    <ManualCapitalActivity owner={owner} />
  </section>;
}
