"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { Badge } from "@/components/ui/Badge";
import { useQuote } from "@/hooks/market";
import { money } from "@/lib/format";
import type { InstrumentView } from "@/lib/market-types";
import { ChangePill } from "./Change";
import { Sparkline } from "./Sparkline";

/** One instrument with its live price. A failed quote says so instead of showing a number. */
export function InstrumentRow({ instrument, trailing, spark = true }: { instrument: Pick<InstrumentView, "id" | "symbol" | "name" | "venueShort">; trailing?: ReactNode; spark?: boolean }) {
  const { data, isLoading, isError } = useQuote(instrument.id);
  const q = data?.quote;
  return (
    <li className="group flex items-center gap-3 px-4 py-2.5 hover:bg-surface-2">
      <Link href={`/markets/${encodeURIComponent(instrument.id)}`} className="flex min-w-0 flex-1 items-center gap-3">
        <span aria-hidden className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-surface-3 text-[11px] font-semibold text-text-2">
          {instrument.symbol.slice(0, 3)}
        </span>
        <span className="min-w-0 flex-1">
          <span className="flex items-center gap-1.5"><span className="truncate text-sm font-semibold text-text">{instrument.symbol}</span><Badge>{instrument.venueShort}</Badge></span>
          <span className="block truncate text-xs text-text-3">{instrument.name}</span>
        </span>
        {spark ? <Sparkline id={instrument.id} baseline={q?.previousClose} className="hidden sm:block" /> : null}
        <span className="flex w-28 shrink-0 flex-col items-end gap-0.5 text-right">
          {isLoading ? <span className="skeleton h-4 w-20" /> : isError || !q ? (
            <span className="text-xs text-text-3">No live price</span>
          ) : (
            <>
              <span className="tabular text-sm font-medium text-text">{money(q.last, q.currency)}</span>
              <span className="flex items-center gap-1">
                {q.stale ? <Badge tone="warn" title={q.staleReason}>Stale</Badge> : null}
                <ChangePill changePct={q.changePct} />
              </span>
            </>
          )}
        </span>
      </Link>
      {trailing}
    </li>
  );
}
