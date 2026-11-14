"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useId, useState } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Notice } from "@/components/ui/Notice";
import { dateLabel, groupedDecimal, privateMarkets, dayInSydney, PrivateMarketsError } from "./private-data";

type ManualHolding = {
  id: string; name: string; assetClass: string; currency: string; units?: string; ownership?: string;
  shareClass?: string; lockupUntil?: string; commitment?: string; paid: string; returned: string;
  pendingCalls: string; exitedOn?: string;
  valuation?: { value: string; date: string; source: string; method: string };
  netGain?: string; realizedGain?: string; unrealizedGain?: string; multiple?: string; dpi?: string; xirr?: string;
  ownershipEvidence?: { excerptID: string; reviewedOn: string };
};
export type ManualPortfolio = { revision: string | null; snapshot: { updated_at: string; holdings: ManualHolding[] } | null };

export function manualPortfolioQuery(owner: string) {
  return {
    queryKey: ["private-markets", owner, "manual-portfolio"], gcTime: 0, retry: false as const,
    queryFn: ({ signal }: { signal: AbortSignal }) => privateMarkets<ManualPortfolio>("manual_portfolio", { owner, signal }),
  };
}

const ratio = new Intl.NumberFormat("en-AU", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const percent = new Intl.NumberFormat("en-AU", { style: "percent", maximumFractionDigits: 2 });

export function manualValuationIsStale(date: string, now: number) {
  return Date.parse(dayInSydney(now)) - Date.parse(dayInSydney(Date.parse(date))) > 90 * 86_400_000;
}

function OwnershipExcerpt({ owner, evidence }: { owner: string; evidence: NonNullable<ManualHolding["ownershipEvidence"]> }) {
  const regionID = useId();
  const [open, setOpen] = useState(false);
  return <div className="space-y-2 border-t border-border px-4 py-3 text-sm text-text-2">
    <Button size="sm" aria-controls={regionID} aria-expanded={open} onClick={() => setOpen(!open)}>
      {open ? "Close ownership excerpt" : "Open ownership excerpt"}
    </Button>
    <div id={regionID} hidden={!open}>
      {open && <OwnershipExcerptContent owner={owner} evidence={evidence} />}
    </div>
  </div>;
}

function OwnershipExcerptContent({ owner, evidence }: { owner: string; evidence: NonNullable<ManualHolding["ownershipEvidence"]> }) {
  const content = useQuery({
    queryKey: ["private-markets", owner, "documents", evidence.excerptID.toLowerCase()], gcTime: 0, retry: false, staleTime: 0,
    queryFn: ({ signal }) => privateMarkets<{ excerpt: string }>("document", { owner, signal, id: evidence.excerptID }),
  });
  if (content.isFetching || content.isPending) return <p role="status">Opening your Deal Room excerpt…</p>;
  if (content.error instanceof PrivateMarketsError && content.error.code === "NOT_FOUND") {
    return <p role="status">This excerpt is no longer available in your Deal Room.</p>;
  }
  if (content.error) return <Notice tone="down">{content.error.message} <Button size="sm" onClick={() => void content.refetch()}>Retry excerpt</Button></Notice>;
  return <div className="space-y-2">
    <p className="text-xs">Reviewed by you on {dateLabel(evidence.reviewedOn)}.</p>
    <p className="whitespace-pre-wrap break-words">{content.data.excerpt}</p>
  </div>;
}

function ManualHoldingCard({ owner, holding, now }: { owner: string; holding: ManualHolding; now: number }) {
  const { currency, valuation } = holding;
  const money = (value?: string) => value === undefined ? "Unavailable" : currency + " " + groupedDecimal(value);
  const values = [
    ["Remaining units", holding.units === undefined ? "Undisclosed" : groupedDecimal(holding.units)],
    ["Carrying value", money(valuation?.value)], ["Committed", money(holding.commitment)],
    ["Capital deployed", money(holding.paid)], ["Returned capital and proceeds", money(holding.returned)],
    ["Pending calls at publication", money(holding.pendingCalls)],
  ];
  const fund = ["Venture fund", "Private equity", "Syndicate or SPV"].includes(holding.assetClass);
  const performance = [
    ["Total gain or loss", money(holding.netGain)], ["Realised gain on sales", money(holding.realizedGain)],
    ["Unrealised gain", money(holding.unrealizedGain)],
    [fund ? "TVPI" : "MOIC", holding.multiple === undefined ? "Unavailable" : ratio.format(Number(holding.multiple)) + "×"],
    ...(fund ? [["DPI", holding.dpi === undefined ? "Unavailable" : ratio.format(Number(holding.dpi)) + "×"]] : []),
    ["XIRR", holding.xirr === undefined ? "Unavailable" : percent.format(Number(holding.xirr))],
  ];
  return <Card as="article" className="min-w-0 break-words">
    <CardHeader title={holding.name} subtitle={holding.assetClass} actions={<Badge>Self-reported</Badge>} />
    <div className="space-y-3 border-t border-border p-4 text-sm">
      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        {values.map(([label, value]) => <div key={label}>
          <dt className="text-xs text-text-3">{label}</dt><dd className="font-medium tabular-nums">{value}</dd>
        </div>)}
      </dl>
      {holding.exitedOn ? <p className="text-xs text-text-2">Exited {dateLabel(holding.exitedOn)}</p> : <>
        <p className="text-xs text-text-2">
          {holding.ownership !== undefined && `Ownership ${groupedDecimal(holding.ownership)}% · `}
          {holding.shareClass && `${holding.shareClass} · `}
          {holding.lockupUntil ? `Recorded lock-up through ${dateLabel(holding.lockupUntil)}.` : "Liquidity depends on the investment terms."}
        </p>
        {valuation && <div className="flex flex-wrap items-center gap-2">
          <p className="text-xs text-text-2">Valued {dateLabel(valuation.date)} · {valuation.method} · {valuation.source}</p>
          {manualValuationIsStale(valuation.date, now) && <Badge tone="warn">Stale valuation</Badge>}
        </div>}
      </>}
    </div>
    {holding.ownershipEvidence && <OwnershipExcerpt key={holding.ownershipEvidence.excerptID} owner={owner} evidence={holding.ownershipEvidence} />}
    <details className="border-t border-border px-4 py-3 text-sm">
      <summary className="cursor-pointer font-medium">Performance at publication</summary>
      <dl className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3">
        {performance.map(([label, value]) => <div key={label}>
          <dt className="text-xs text-text-3">{label}</dt><dd className="font-medium tabular-nums">{value}</dd>
        </div>)}
      </dl>
    </details>
  </Card>;
}

export function ManualPortfolioPanel({ owner }: { owner: string }) {
  const cache = useQueryClient();
  const options = manualPortfolioQuery(owner);
  const result = useQuery(options);
  const [removalRevision, setRemovalRevision] = useState<string | null>(null);
  const remove = useMutation({
    mutationFn: (revision: string) => privateMarkets<{ revision: string }>("remove_manual_portfolio", { owner, expected_revision: revision }),
    onSuccess: ({ revision }) => {
      cache.setQueryData<ManualPortfolio>(options.queryKey, { revision, snapshot: null });
      void cache.invalidateQueries({ queryKey: options.queryKey });
      setRemovalRevision(null);
    },
    onError: () => { void result.refetch(); setRemovalRevision(null); },
  });
  const snapshot = result.error ? null : result.data?.snapshot;
  const revision = result.data?.revision;
  return <section className="space-y-3">
    <div className="flex flex-wrap items-start justify-between gap-2">
      <div>
        <h2 className="font-semibold text-text">Self-reported holdings</h2>
        <p className="text-sm text-text-2">{snapshot
          ? `Snapshot published from iPhone ${dateLabel(snapshot.updated_at, "time")}.`
          : "Publish your current snapshot from My Private Portfolio on iPhone."}</p>
      </div>
      {snapshot && revision && !removalRevision && <Button size="sm" onClick={() => { remove.reset(); setRemovalRevision(revision); }}>Remove web snapshot</Button>}
    </div>
    {removalRevision && <Notice tone="warn">
      <p>Remove the published holdings from this web account?</p>
      <div className="mt-2 flex flex-wrap gap-2">
        <Button size="sm" variant="danger" disabled={remove.isPending || result.isFetching} onClick={() => remove.mutate(removalRevision)}>Confirm removal</Button>
        <Button size="sm" disabled={remove.isPending} onClick={() => setRemovalRevision(null)}>Cancel</Button>
      </div>
    </Notice>}
    {result.isPending && <p className="text-sm text-text-2" role="status">Checking for a web snapshot…</p>}
    {result.error && <Notice tone="down">{result.error.message} <Button size="sm" onClick={() => void result.refetch()}>Retry snapshot</Button></Notice>}
    {remove.error && <Notice tone="down">{remove.error.message}</Notice>}
    {remove.isSuccess && <p className="text-sm text-text-2" role="status">Web snapshot removed.</p>}
    {snapshot?.holdings.map((holding) => <ManualHoldingCard key={holding.id} owner={owner} holding={holding} now={result.dataUpdatedAt} />)}
  </section>;
}
