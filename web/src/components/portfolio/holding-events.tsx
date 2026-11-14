"use client";

import { useId, useState } from "react";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { getJSON } from "@/lib/api";
import { dateTime } from "@/lib/format";
import type { PortfolioEventGroup, PortfolioEventKind, PortfolioEventsResponse } from "@/lib/portfolio-events";
import styles from "./holding-events.module.css";

const labels: Record<PortfolioEventKind, { title: string; empty: string }> = {
  earnings: { title: "Expected earnings", empty: "No expected dates found in the next 30 days." },
  news: { title: "Recent headlines", empty: "No linked headlines found in the last seven days." },
  filings: { title: "Recent SEC filings", empty: "No selected filing types found in the last 30 days." },
};

function EventGroup({ kind, group }: { kind: PortfolioEventKind; group: PortfolioEventGroup }) {
  const { title, empty } = labels[kind];
  const message = group.status === "not_applicable" ? "No eligible listings in your holdings."
    : group.status === "restricted" ? "This data source is unavailable on this site."
    : group.status === "unavailable" ? "The provider couldn’t check these listings."
    : group.items.length === 0 ? empty : undefined;
  return <div>
    <h3>{title}</h3>
    {group.eligible > 0 && <p>{group.checked} of {group.eligible} eligible listings checked.</p>}
    {message && <p>{message}</p>}
    {group.items.length > 0 && <ul>
      {group.items.map(({ instrumentId, symbol, event }) => <li key={`${instrumentId}:${event.id}`}>
        <Link href={`/markets/${encodeURIComponent(instrumentId)}`} prefetch={false}>{symbol}</Link>
        <span aria-hidden="true"> · </span>
        <a href={event.evidence.url} target="_blank" rel="noreferrer">{event.title}</a>
        <p>{kind === "earnings" ? <time dateTime={event.date}>{event.date}</time>
          : <time dateTime={event.evidence.publishedAt ?? event.date}>{dateTime(event.evidence.publishedAt ?? event.date)}</time>}
          {" · "}{event.publisher || event.evidence.provider}
          {kind === "earnings" && event.evidence.retrievedAt && <> · Retrieved {dateTime(event.evidence.retrievedAt)}</>}</p>
      </li>)}
    </ul>}
  </div>;
}

export function HoldingEvents({ userId, overview = false }: { userId: string; overview?: boolean }) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const query = useQuery({
    queryKey: ["portfolio-events", userId], enabled: open, staleTime: 5 * 60_000, retry: false,
    queryFn: async ({ signal }) => {
      const result = await getJSON<PortfolioEventsResponse>("/api/portfolio/events", signal);
      if (result.owner !== userId) throw new Error("The account changed while loading events.");
      return result;
    },
  });
  return <section className={styles.panel} data-overview={overview ? "" : undefined} aria-labelledby={id}>
    <details onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary id={id}>Earnings, news and filings for holdings</summary>
      {open && <div className={styles.body}>
        {query.isPending ? <p role="status">Checking holding events…</p>
          : query.isError ? <p role="status">Couldn’t load holding events. <button type="button" onClick={() => void query.refetch()}>Retry</button></p>
          : query.data && <>
            <p>Checked {dateTime(query.data.asOf)}. Expected earnings dates may change.</p>
            {query.data.holdingsTruncated && <p>Coverage counts use the first 200 open holdings by ticker.</p>}
            <div className={styles.groups}>
              {Object.entries(labels).map(([key]) => <EventGroup key={key} kind={key as PortfolioEventKind} group={query.data.groups[key as PortfolioEventKind]} />)}
            </div>
          </>}
      </div>}
    </details>
  </section>;
}
