import { useInfiniteQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Notice } from "@/components/ui/Notice";
import { SourceLink } from "./catalog";
import { dateLabel, groupedDecimal, privateMarkets, sourceHref } from "./private-data";

type Valuation = { id: string; value: string; valued_on: string; source: string; methodology: string; provider_event_at: string | null };
type ValuationPage = { items: Valuation[]; next_offset: number | null };

export function ValuationHistory({ owner, holdingID, currency, currentMarkID }: {
  owner: string; holdingID: string; currency: string; currentMarkID?: string;
}) {
  const history = useInfiniteQuery({
    queryKey: ["private-markets", owner, "valuation-history", holdingID],
    gcTime: 0, retry: false, initialPageParam: 0,
    queryFn: ({ signal, pageParam }) => privateMarkets<ValuationPage>("valuation_history",
      { owner, signal, holding_id: holdingID, offset: pageParam }),
    getNextPageParam: (page) => page.next_offset ?? undefined,
  });
  const marks = [...new Map(history.data?.pages.flatMap((page) => page.items.map((item) => [item.id, item] as const))).values()];

  return <div className="mt-3 space-y-3">
    {history.isPending && <p role="status">Loading valuation history…</p>}
    {history.error && <Notice tone="down">{history.error.message} <Button size="sm" onClick={() => void history.refetch()}>Retry valuations</Button></Notice>}
    {history.data && !marks.length && <p>No provider valuations recorded.</p>}
    {!!marks.length && <ul className="divide-y divide-border">
      {marks.map((mark) => <li key={mark.id} className="space-y-1 py-2.5">
        <p className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <strong className="font-medium tabular-nums text-text">{currency} {groupedDecimal(mark.value)}</strong>
          <span>Valued {dateLabel(mark.valued_on)}</span>
          {mark.id === currentMarkID && <span className="text-xs text-text-3">Used for carrying value</span>}
        </p>
        <p>{mark.methodology} · {sourceHref(mark.source) ? <SourceLink url={mark.source}>Read valuation source</SourceLink> : mark.source}</p>
        {mark.provider_event_at && <p className="text-xs text-text-3">Reported {dateLabel(mark.provider_event_at, "time")}</p>}
      </li>)}
    </ul>}
    {history.hasNextPage && <Button size="sm" disabled={history.isFetching} onClick={() => void history.fetchNextPage()}>
      {history.isFetchingNextPage ? "Loading…" : "Load older valuations"}
    </Button>}
  </div>;
}
