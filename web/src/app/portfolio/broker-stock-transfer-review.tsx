"use client";

import { useState } from "react";
import { useMutation } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Field, Input } from "@/components/ui/Field";
import { matchBrokerStockTransfers, type BrokerStockMatch, type BrokerStockMovement } from "@/lib/broker-stock-transfers";
import { incomeDay, incomeMinDay } from "@/lib/portfolio-income";
import { sydneyDate, type StockTransfer, type TransferHolding } from "@/lib/portfolio-transfers";
import { service } from "@/workspace/lib/backend";

type Account = { id: string };
type TransferPage = { activities: { stockTransfer?: BrokerStockMovement["stockTransfer"]; id: string; date: string }[];
  omitted: number; nextOffset: number | null };

async function readMovements(accountId: string, startDate: string, endDate: string) {
  const movements: BrokerStockMovement[] = [];
  let offset = 0;
  for (let page = 0; page < 20; page++) {
    const result = await service<TransferPage>("brokerage", {
      operation: "accountActivities", params: { accountId, startDate, endDate, offset, stockTransfersOnly: true },
    });
    if (result.omitted) throw new Error("Some transfer activity was unreadable. Narrow the dates or use both statements.");
    for (const row of result.activities) {
      if (row.stockTransfer?.accountId === accountId) movements.push({ id: row.id, date: row.date, stockTransfer: row.stockTransfer });
    }
    if (result.nextOffset === null) return movements;
    if (result.nextOffset <= offset) break;
    offset = result.nextOffset;
  }
  throw new Error("There is too much transfer activity for these dates. Try a shorter period.");
}

export function BrokerStockTransferReview({ holdings, transfers, busy, onReview }: {
  holdings: TransferHolding[]; transfers: StockTransfer[]; busy: boolean; onReview: (match: BrokerStockMatch) => void;
}) {
  const [open, setOpen] = useState(false);
  const [end, setEnd] = useState(() => sydneyDate(new Date().toISOString())!);
  const [start, setStart] = useState(() => sydneyDate(new Date(Date.now() - 89 * 86_400_000).toISOString())!);
  const today = sydneyDate(new Date().toISOString())!;
  const search = useMutation({
    mutationFn: async () => {
      if (!incomeDay(start) || !incomeDay(end) || start > end || end > today) throw new Error("Choose a valid date range.");
      const { registered } = await service<{ registered: boolean }>("brokerage", { operation: "status" });
      if (!registered) return { movements: [], accounts: 0 };
      const accounts = await service<Account[]>("brokerage", { operation: "listAccounts" });
      if (accounts.length < 2) return { movements: [], accounts: accounts.length };
      const movements: BrokerStockMovement[] = [];
      for (let index = 0; index < accounts.length; index += 3) {
        const batch = await Promise.all(accounts.slice(index, index + 3).map(({ id }) => readMovements(id, start, end)));
        for (const rows of batch) movements.push(...rows);
      }
      return { movements, accounts: accounts.length };
    },
  });
  const matches = search.data ? matchBrokerStockTransfers(search.data.movements, holdings) : [];
  const used = new Set(transfers.flatMap(({ snaptrade_reference: reference }) => reference
    ? [reference.sentId, reference.receivedId] : []));

  return <div className="space-y-3">
    <Button size="sm" aria-expanded={open} aria-controls="broker-stock-transfer-search" onClick={() => setOpen(!open)}>
      {open ? "Hide broker transfer search" : "Find transfers in linked accounts"}
    </Button>
    {open && <fieldset id="broker-stock-transfer-search" className="space-y-3 rounded-md border border-border p-3"
      disabled={search.isPending || busy}>
      <legend className="px-1 text-sm font-medium">Broker-reported stock transfers</legend>
      <p className="text-xs text-text-2">Find matching outgoing and incoming activity. Compare both reports with your statements before you save.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Broker activity start date" htmlFor="broker-transfer-start">
          <Input id="broker-transfer-start" type="date" min={incomeMinDay} max={end || today} value={start}
            onChange={(event) => { setStart(event.target.value); search.reset(); }} />
        </Field>
        <Field label="Broker activity end date" htmlFor="broker-transfer-end">
          <Input id="broker-transfer-end" type="date" min={start || incomeMinDay} max={today} value={end}
            onChange={(event) => { setEnd(event.target.value); search.reset(); }} />
        </Field>
      </div>
      <Button size="sm" onClick={() => search.mutate()}>{search.isPending ? "Checking accounts…" : "Search broker activity"}</Button>
      {search.isError && <p role="alert" className="text-xs text-down">{search.error.message}</p>}
      {search.data && matches.length === 0 && <p role="status" className="text-xs text-text-2">{search.data.accounts < 2
        ? "Link both brokerage accounts to search for a pair."
        : "No unambiguous pairs matched your synced holdings for these dates. You can record a transfer from statements below."}</p>}
      {matches.length > 0 && <ul className="divide-y divide-border">
        {matches.map((match) => {
          const { reference, source, destination } = match;
          const recorded = used.has(reference.sentId) || used.has(reference.receivedId);
          return <li key={reference.sentId} className="flex flex-wrap items-center justify-between gap-2 py-2">
            <div>
              <p className="text-sm">{reference.symbol} · {reference.shares} shares</p>
              <p className="text-xs text-text-2">{source.broker_account?.label} → {destination.broker_account?.label}</p>
              <p className="text-xs text-text-2">Broker reported {reference.sentOn} → {reference.receivedOn}</p>
            </div>
            <Button size="sm" disabled={recorded} onClick={() => onReview(match)}>{recorded ? "Already recorded" : "Review match"}</Button>
          </li>;
        })}
      </ul>}
    </fieldset>}
  </div>;
}
