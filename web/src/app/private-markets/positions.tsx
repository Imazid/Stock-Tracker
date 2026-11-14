"use client";

import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Notice } from "@/components/ui/Notice";
import { SourceLink } from "./catalog";
import { InvestorProfileCard } from "./investor-profile";
import {
  amount, dateLabel, privateMarkets, providerName, dayInSydney, type Application, type PortfolioHolding, type PortfolioPage,
} from "./private-data";
import { privatePositionPerformance } from "./private-performance";

const percent = new Intl.NumberFormat("en-AU", { style: "percent", maximumFractionDigits: 2 });
const ratio = new Intl.NumberFormat("en-AU", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

function LedgerSection({ title, children }: { title: string; children: ReactNode }) {
  return <section>
    <h3 className="font-medium text-text">{title}</h3>
    <ul className="mt-1 space-y-1">{children}</ul>
  </section>;
}

function HoldingCard({ holding, asOf }: { holding: PortfolioHolding; asOf: number }) {
  const { currency } = holding;
  const { exited, mark, stale, metrics, completeActivity, fund } = privatePositionPerformance(holding, dayInSydney(asOf), asOf);
  const acquisition = holding.settled_on
    ? `Settled ${dateLabel(holding.settled_on)} · ${holding.settlement_source ?? "Provider confirmation"}`
    : "Provider confirmation";
  const units = holding.remaining_units ?? holding.units;
  const capital = [
    ["Committed", amount(holding.committed_amount, currency)], ["Settled", amount(holding.settled_amount, currency)],
    ["Remaining units", units == null ? "Undisclosed" : String(units)],
    ["Carrying value", exited ? amount(0, currency) : mark ? amount(mark.value, currency) : "Unavailable"],
  ];
  const money = (value: number | null) => value === null ? "Unavailable" : amount(value, currency);
  const multiple = (value: number | null) => value === null ? "Unavailable" : `${ratio.format(value)}×`;
  const performance = metrics ? [
    ["Capital deployed", money(metrics.paid)],
    ["Returned capital and proceeds", money(metrics.returned)],
    ["Uncalled commitment", money(metrics.uncalled)],
    ["Pending calls", money(metrics.pending)],
    ["Total gain or loss", money(metrics.netGain)],
    ["Realised gain on sales", money(metrics.realized)],
    ["Unrealised gain", money(metrics.unrealized)],
    [metrics.multipleLabel, multiple(metrics.multiple)],
    ...(fund ? [["DPI", multiple(metrics.dpi)]] : []),
    ["XIRR", metrics.xirr === null ? "Unavailable" : percent.format(metrics.xirr)],
  ] : [];
  return (
    <Card as="article" className="break-words">
      <CardHeader title={holding.name} subtitle={`${providerName(holding.commitment.provider)} · ${holding.asset_class.replaceAll("_", " ")}`}
        actions={<Badge tone={exited ? "neutral" : "primary"}>{exited ? "Exited" : "Provider confirmed"}</Badge>} />
      <div className="space-y-2 border-t border-border p-4 text-sm">
        <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {capital.map(([label, value]) => <div key={label}>
            <dt className="text-xs text-text-3">{label}</dt><dd className="break-words font-medium tabular-nums text-text">{value}</dd>
          </div>)}
        </dl>
        <p className="text-xs text-text-2">{acquisition}</p>
        {holding.last_disposition_on === null && holding.ownership_percent != null &&
          <p className="text-xs text-text-2">Reported ownership {percent.format(holding.ownership_percent / 100)}</p>}
        {holding.commitment.provider_reference && <p className="break-words text-xs text-text-3">Provider reference {holding.commitment.provider_reference}</p>}
        {mark && <div className="flex flex-wrap items-center gap-2">
          <p className="text-xs text-text-2">Valued {dateLabel(mark.valued_on)} · {mark.methodology} · {mark.source}</p>
          {stale && <Badge tone="warn">Stale valuation</Badge>}
        </div>}
        {exited && <p className="text-xs text-text-2">Exit recorded {dateLabel(holding.last_disposition_on)} · {holding.exit_source}</p>}
        {!exited && <p className="text-xs text-text-2">Private holding · Liquidity depends on the investment terms.</p>}
      </div>
      <details className="border-t border-border px-4 py-3 text-[13px] text-text-2">
        <summary className="cursor-pointer font-medium text-text">Performance</summary>
        {metrics ? <div className="mt-3 space-y-3">
          <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            {performance.map(([label, value]) => <div key={label}>
              <dt className="text-xs text-text-3">{label}</dt><dd className="font-medium tabular-nums text-text">{value}</dd>
            </div>)}
          </dl>
          {!exited && metrics.netGain === null && <p className="text-xs">Returns need a valuation dated on or after all recorded settled activity.</p>}
        </div> : <p className="mt-2 text-xs">{completeActivity
          ? "Performance needs a dated opening settlement from the provider."
          : "Performance requires a complete activity history. This view shows up to 100 records per category."}</p>}
      </details>
      {!!(holding.calls.length || holding.cancelled_calls.length || holding.distributions.length || holding.dispositions.length) &&
        <details className="border-t border-border px-4 py-3 text-[13px] text-text-2">
          <summary className="cursor-pointer font-medium text-text">Capital activity</summary>
          <div className="mt-3 space-y-3">
            {!!holding.calls.length && <LedgerSection title="Capital calls">{holding.calls.slice(0, 100).map((call) => (
              <li key={call.id}>{amount(call.amount, currency)} · {call.settled_on ? `Paid ${dateLabel(call.settled_on)}` : `Due ${dateLabel(call.due_on)}`} · {call.source}</li>
            ))}</LedgerSection>}
            {!!holding.cancelled_calls.length && <LedgerSection title="Cancelled calls">{holding.cancelled_calls.map((call) => (
              <li key={call.id}>{amount(call.amount, currency)} · Cancelled {dateLabel(call.cancelled_at)} · {call.cancellation_source}</li>
            ))}</LedgerSection>}
            {!!holding.distributions.length && <LedgerSection title="Distributions">{holding.distributions.slice(0, 100).map((record) => (
              <li key={record.id}>{amount(record.amount, currency)} · {dateLabel(record.received_on)} · {record.source}</li>
            ))}</LedgerSection>}
            {!!holding.dispositions.length && <LedgerSection title="Settled sales">{holding.dispositions.slice(0, 100).map((sale) => (
              <li key={sale.id}>{sale.sold_units} units · {amount(sale.net_proceeds, currency)} · {dateLabel(sale.settled_on)} · {sale.source}</li>
            ))}</LedgerSection>}
          </div>
        </details>}
    </Card>
  );
}

const applicationLabels: Record<string, string> = {
  handoff: "Awaiting provider", application_received: "Application received", withdrawal_requested: "Withdrawal requested",
  withdrawn: "Withdrawn", rejected: "Rejected", confirmed: "Ownership confirmed", cancelled: "Cancelled",
};

const withdrawalHelp: Record<string, string> = {
  birchal: "https://help.birchal.com/en/articles/1709077-how-do-i-cancel-my-investment",
  onmarket: "https://www.onmarket.com.au/help-faq/equity-crowdfunding-investing-and-allocations/how-do-i-cancel-my-application/",
};

function ApplicationCard({ item }: { item: Application }) {
  const name = item.offer?.round?.company?.name ?? providerName(item.provider);
  const canReviewWithdrawal = item.status === "application_received" || item.status === "withdrawal_requested";
  const timeline = [
    ["Terms acknowledged", item.acknowledged_at], ["Application received", item.provider_received_at],
    ["Cooling-off ends", item.cooling_off_ends_at], ["Supplementary notice", item.supplementary_notice_at],
    ["Supplementary withdrawal ends", item.supplementary_withdrawal_ends_at], ["Withdrawal requested", item.withdrawal_requested_at],
    ["Withdrawal declined", item.withdrawal_declined_at], ["Withdrawal confirmed", item.withdrawn_at], ["Ownership confirmed", item.confirmed_at],
  ].filter(([, date]) => date);
  return <Card as="article" className="break-words">
    <CardHeader title={name} subtitle={[item.offer?.round?.stage, providerName(item.provider)].filter(Boolean).join(" · ")}
      actions={<Badge>{applicationLabels[item.status] ?? "Provider status unavailable"}</Badge>} />
    <div className="space-y-3 border-t border-border p-4 text-[13px] text-text-2">
      <dl className="grid grid-cols-2 gap-2">
        <div><dt className="text-text-3">Requested</dt><dd>{amount(item.requested_amount, item.currency)}</dd></div>
        <div><dt className="text-text-3">Provider amount</dt><dd>{amount(item.provider_application_amount, item.currency)}</dd></div>
      </dl>
      {item.provider_reference && <p className="break-words">Provider reference {item.provider_reference}</p>}
      <dl className="space-y-1 text-xs">
        {timeline.map(([label, date]) => <div key={label} className="flex flex-wrap gap-x-2">
          <dt className="font-medium text-text">{label}</dt><dd>{dateLabel(date, "time")}</dd>
        </div>)}
      </dl>
      {item.supplementary_document_url && <SourceLink url={item.supplementary_document_url}>Supplementary disclosure</SourceLink>}
      {canReviewWithdrawal && <div className="space-y-1">
        {item.status === "withdrawal_requested" && <p>Awaiting the provider’s decision. Check your provider account for refund information.</p>}
        {!item.cooling_off_ends_at && !item.supplementary_withdrawal_ends_at && <p>Check your provider account for withdrawal deadlines.</p>}
        {withdrawalHelp[item.provider] && <SourceLink url={withdrawalHelp[item.provider]}>Provider withdrawal instructions</SourceLink>}
      </div>}
    </div>
  </Card>;
}

export function Positions({ owner }: { owner: string }) {
  const holdings = useInfiniteQuery({
    queryKey: ["private-markets", owner, "holdings"], gcTime: 0, retry: false, initialPageParam: 0,
    queryFn: ({ signal, pageParam }) => privateMarkets<PortfolioPage>("confirmed_holdings", { owner, signal, offset: pageParam }),
    getNextPageParam: (page) => page.next_offset ?? undefined,
  });
  const applications = useQuery({
    queryKey: ["private-markets", owner, "applications"], gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ applications: Application[] }>("applications", { owner, signal }),
  });
  const positions = holdings.data?.pages.flatMap((page) => page.holdings) ?? [];
  const records = applications.data?.applications ?? [];

  return <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(18rem,0.65fr)]">
    <section className="min-w-0 space-y-3">
      <div>
        <h2 className="font-semibold text-text">My Private Portfolio</h2>
        <p className="text-[13px] text-text-2">Provider-confirmed holdings. Manual holdings and imported AngelList statements are stored on the iPhone.</p>
      </div>
      {holdings.isPending && <p className="text-sm text-text-2" role="status">Loading holdings…</p>}
      {holdings.error && <Notice tone="down">{holdings.error.message} <Button size="sm" onClick={() => void holdings.refetch()}>Retry holdings</Button></Notice>}
      {holdings.data && !positions.length && <Card><EmptyState title="No provider-confirmed holdings" /></Card>}
      {positions.map((item) => <HoldingCard key={item.id} holding={item} asOf={holdings.dataUpdatedAt} />)}
      {holdings.hasNextPage && <Button size="sm" disabled={holdings.isFetchingNextPage} onClick={() => void holdings.fetchNextPage()}>
        {holdings.isFetchingNextPage ? "Loading…" : "Load more holdings"}
      </Button>}
    </section>
    <section className="min-w-0 space-y-3">
      <InvestorProfileCard owner={owner} />
      <div>
        <h2 className="font-semibold text-text">Applications</h2>
        <p className="text-[13px] text-text-2">Application status and notices reported by your provider.</p>
      </div>
      {applications.isPending && <p className="text-sm text-text-2" role="status">Loading applications…</p>}
      {applications.error && <Notice tone="down">{applications.error.message} <Button size="sm" onClick={() => void applications.refetch()}>Retry applications</Button></Notice>}
      {applications.data && !records.length && <Card><EmptyState title="No recorded applications" /></Card>}
      {records.map((item) => <ApplicationCard key={item.id} item={item} />)}
    </section>
  </div>;
}
