import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { dateTime, money } from "@/lib/format";
import { usePortfolioBrokerage } from "@/hooks/portfolio-brokerage";

export function BrokerCash({ userId }: { userId: string }) {
  const [open, setOpen] = useState(false);
  const cash = usePortfolioBrokerage(userId, open);
  return <Card id="brokerage-balances">
    <CardHeader title="Brokerage cash" subtitle="Cash reported by each linked investment account in its original currency." />
    <div className="space-y-3 border-t border-border px-4 py-3">
      <div className="flex flex-wrap gap-2">
        <Button size="sm" aria-expanded={open} aria-controls="broker-cash-balances" onClick={() => setOpen(!open)}>
          {open ? "Hide balances" : "Show cash balances"}
        </Button>
        {open && cash.data && <Button size="sm" disabled={cash.isFetching} onClick={() => void cash.refetch()}>Check balances</Button>}
      </div>
      {open && <div id="broker-cash-balances" className="space-y-3">
        {cash.isFetching && <p role="status" className="text-sm text-text-2">Checking cash balances…</p>}
        {cash.isError && <div role="alert" className="space-y-2">
          <p className="text-sm text-text-2">{cash.data ? "The balance check failed. Showing the previous result." : "Couldn’t load brokerage cash."}</p>
          {!cash.data && <Button size="sm" onClick={() => void cash.refetch()}>Try again</Button>}
        </div>}
        {cash.data?.accounts.length === 0 && <p className="text-sm text-text-2">No linked investment accounts with open status.</p>}
        {Boolean(cash.data?.duplicatesSkipped) && <p className="text-xs text-text-2">Duplicate connections identified by the broker are shown once.</p>}
        {cash.data?.accounts.length ? <ul aria-label="Cash by account" className="divide-y divide-border">
          {cash.data.accounts.map((account) => <li key={account.id} className="space-y-1.5 py-2">
            <div>
              <p className="break-words text-sm font-semibold">{account.label}{account.paper ? " · Paper account" : ""}</p>
              <p className="text-xs text-text-3">
                {account.status === "disconnected" && "Disconnected · "}
                {account.status === "unavailable" && "Unavailable · "}
                {account.syncedAt ? `Last balance sync ${dateTime(account.syncedAt)}` : "Balance sync time unavailable"}
              </p>
            </div>
            {account.netValue && <p className="text-sm">Reported net value <strong className="tabular">{money(Number(account.netValue.amount), account.netValue.currency)}</strong></p>}
            {account.balances.length ? <dl className="space-y-1">
              {account.balances.map(({ currency, amount, buyingPower }) => <div key={currency} className="flex flex-wrap justify-between gap-x-2 text-sm">
                <dt>{currency}</dt>
                <dd className="tabular text-right">{amount === null ? "Unavailable" : money(Number(amount), currency)}
                  {buyingPower != null && <span className="block text-xs text-text-3">Buying power {money(Number(buyingPower), currency)}</span>}</dd>
              </div>)}
            </dl> : <p className="text-sm text-text-2">Cash balance unavailable.</p>}
            {account.incomplete && <p className="text-xs text-text-2">Some balance amounts are unavailable.</p>}
          </li>)}
        </ul> : null}
        {cash.data?.accounts.length ? <p className="text-xs text-text-3">SnapTrade cash can include money-market funds. Holdings exposure and saved returns use their own records.</p> : null}
      </div>}
    </div>
  </Card>;
}
