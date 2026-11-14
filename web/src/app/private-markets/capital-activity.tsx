"use client";

import { useInfiniteQuery } from "@tanstack/react-query";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Notice } from "@/components/ui/Notice";
import { SourceLink } from "./catalog";
import { dateLabel, privateMarkets, providerName, sourceHref, type CapitalActivityItem } from "./private-data";

type Section = "calls" | "history";
type CapitalActivityPage = { items: CapitalActivityItem[]; next_offset: number | null };

const statusLabels = {
  upcoming: "Upcoming", overdue: "Overdue", paid: "Paid", cancelled: "Cancelled", distribution: "Distribution",
};

function formattedAmount(currency: string, amount: string) {
  // Preserve the ledger's decimal amount without converting large values to a binary float.
  const [whole, fraction] = amount.split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${currency} ${grouped}${fraction ? "." + fraction : ""}`;
}

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
      <p className="break-words font-medium tabular-nums">{formattedAmount(item.currency, item.amount)}</p>
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

export function CapitalActivity({ owner }: { owner: string }) {
  return <section aria-labelledby="capital-activity-heading" className="space-y-4">
    <div>
      <h2 id="capital-activity-heading" className="font-semibold text-text">Capital Calls &amp; Distributions</h2>
      <p className="text-sm text-text-2">Activity from provider-confirmed holdings. Dates use Sydney time and amounts use the original currency.</p>
    </div>
    <div className="grid items-start gap-4 lg:grid-cols-2">
      <CapitalActivityList owner={owner} section="calls" title="Outstanding capital calls" empty="No outstanding capital calls" />
      <CapitalActivityList owner={owner} section="history" title="Capital history" empty="No confirmed capital activity" />
    </div>
  </section>;
}
