"use client";

import { useRef, useState } from "react";
import type { OrderPreview } from "@engine/state.ts";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input } from "@/components/ui/Field";
import { PageHeader } from "@/components/ui/PageHeader";
import { usePractice, practiceCall } from "@/hooks/practice";
import { useSearch } from "@/hooks/market";
import { money } from "@/lib/format";
import type { InstrumentView } from "@/lib/market-types";
import { uuid } from "@/lib/uuid";

export function PaperView() {
  const { session, query } = usePractice();
  const [portfolioName, setPortfolioName] = useState("");
  const [startingCash, setStartingCash] = useState("10000");
  const [currency, setCurrency] = useState("USD");
  const [portfolioId, setPortfolioId] = useState("");
  const [search, setSearch] = useState("");
  const [asset, setAsset] = useState<InstrumentView>();
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [quantity, setQuantity] = useState("");
  const [review, setReview] = useState<{ preview: OrderPreview; order: Record<string, unknown>; key: string }>();
  const [feedback, setFeedback] = useState("");
  const createAttempt = useRef<{ fingerprint: string; key: string } | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const results = useSearch(asset ? "" : search);
  const accounts = query.data?.ledgers.filter((ledger) => ledger.kind === "manualPaper") ?? [];
  const selected = accounts.find((account) => account.id === portfolioId) ?? accounts[0];

  async function perform(work: () => Promise<void>) {
    setBusy(true);
    setFeedback("");
    try { await work(); } catch (error) { setFeedback(error instanceof Error ? error.message : "The request failed."); }
    finally { setBusy(false); }
  }

  return (
    <div className="mx-auto max-w-4xl space-y-5">
      <PageHeader title="Paper Trading" description="Use simulated cash with market prices. Practice orders stay inside Stock Tracker." />
      {session.status === "signedOut" ? <Card><EmptyState title="Sign in to use practice trading" actions={<ButtonLink href="/login?next=/paper" variant="primary">Sign in</ButtonLink>} /></Card>
        : session.status === "unconfigured" ? <Card><EmptyState title="Accounts are unavailable" /></Card>
        : session.status === "loading" || query.isPending ? <div className="skeleton h-24" role="status" aria-label="Loading practice account" />
        : query.isError ? <Card><EmptyState title="Couldn’t load practice trading" tone="down" actions={<Button onClick={() => void query.refetch()}>Retry</Button>} /></Card>
        : <>
          <Card>
            <CardHeader title="Practice portfolios" />
            {accounts.length > 0 && (
              <ul className="divide-y divide-border border-t border-border">
                {accounts.map((account) => <li key={account.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                  <span className="font-medium">{account.name}</span>
                  <span className="text-sm text-text-2">{money(account.cash, account.currency)} available · {account.positions.length} positions</span>
                </li>)}
              </ul>
            )}
            <form className="grid gap-3 border-t border-border p-4 sm:grid-cols-[1fr_1fr_auto]" onSubmit={(event) => {
              event.preventDefault();
              void perform(async () => {
                const draft = { name: portfolioName.trim(), startingCash: Number(startingCash), currency };
                const fingerprint = JSON.stringify(draft);
                const key = createAttempt.current?.fingerprint === fingerprint ? createAttempt.current.key : uuid();
                createAttempt.current = { fingerprint, key };
                const result = await practiceCall<{ ledger: { id: string } }>("createPortfolio", draft, key);
                createAttempt.current = undefined;
                await query.refetch();
                setPortfolioId(result.ledger.id);
                setReview(undefined);
                setPortfolioName("");
              });
            }}>
              <Field label="Portfolio name" htmlFor="practice-name"><Input id="practice-name" value={portfolioName} required maxLength={60} onChange={(e) => setPortfolioName(e.target.value)} /></Field>
              <Field label="Starting cash" htmlFor="practice-cash"><Input id="practice-cash" type="number" min="1" max="10000000" step="0.01" value={startingCash} required onChange={(e) => setStartingCash(e.target.value)} /></Field>
              <Field label="Currency" htmlFor="practice-currency"><select id="practice-currency" className="h-9 rounded-lg border border-border bg-surface-2 px-2" value={currency} onChange={(e) => setCurrency(e.target.value)}><option>USD</option><option>AUD</option></select></Field>
              <Button type="submit" disabled={busy || !portfolioName.trim()}>Create practice portfolio</Button>
            </form>
          </Card>
          {selected && <Card>
            <CardHeader title="Practice order" />
            {review ? (
              <div className="space-y-3 border-t border-border p-4">
                <p className="font-medium">Review {side} · {review.preview.quantity} {review.preview.instrument.symbol}</p>
                <p className="text-sm text-text-2">Estimated value {money(review.preview.estimatedValue, review.preview.currency)} · Fees {money(review.preview.estimatedFee, review.preview.currency)}</p>
                {review.preview.willQueueUntilOpen && <p className="text-sm text-text-2">The order will wait for the market to open.</p>}
                {review.preview.risk.checks.filter((check) => check.status === "failed").map((check, index) => <p key={index} className="text-sm text-down">{check.detail}</p>)}
                <div className="flex flex-wrap gap-2">
                  <Button disabled={busy} onClick={() => { setReview(undefined); setFeedback(""); }}>Edit order</Button>
                  <Button variant="primary" disabled={busy || !review.preview.canSubmit} onClick={() => void perform(async () => {
                    const result = await practiceCall<{ accepted: boolean; summary?: string; status?: string; order?: { status: string } }>("placeOrder", { order: review.order }, review.key);
                    const status = result.order?.status ?? result.status;
                    setFeedback(result.accepted ? `Practice order ${status ?? "accepted"}.` : result.summary ?? "The practice order was refused.");
                    setReview(undefined);
                    await query.refetch();
                  })}>Confirm practice order</Button>
                </div>
              </div>
            ) : (
              <form className="space-y-3 border-t border-border p-4" onSubmit={(event) => {
                event.preventDefault();
                if (!asset || !selected || asset.currency !== selected.currency) return;
                void perform(async () => {
                  const key = uuid();
                  const instrument = { symbol: asset.symbol, name: asset.name, assetClass: asset.assetClass, venue: asset.venue, currency: asset.currency };
                  const order = { clientOrderID: key, ledgerID: selected.id, instrument, side, quantity: Number(quantity), mode: "paper" };
                  const { preview } = await practiceCall<{ preview: OrderPreview }>("previewOrder", { order });
                  setReview({ preview, order, key });
                });
              }}>
                <div className="grid gap-3 sm:grid-cols-3">
                  <Field label="Practice portfolio" htmlFor="order-portfolio"><select id="order-portfolio" className="h-9 rounded-lg border border-border bg-surface-2 px-2" value={selected.id} onChange={(e) => setPortfolioId(e.target.value)}>{accounts.map((account) => <option key={account.id} value={account.id}>{account.name} · {account.currency}</option>)}</select></Field>
                  <Field label="Side" htmlFor="practice-side"><select id="practice-side" className="h-9 rounded-lg border border-border bg-surface-2 px-2" value={side} onChange={(e) => setSide(e.target.value === "sell" ? "sell" : "buy")}><option value="buy">Buy</option><option value="sell">Sell</option></select></Field>
                  <Field label="Quantity" htmlFor="practice-quantity"><Input id="practice-quantity" type="number" min="0.00000001" step="any" required value={quantity} onChange={(e) => setQuantity(e.target.value)} /></Field>
                </div>
                <Field label="Find an asset" htmlFor="practice-asset"><Input id="practice-asset" value={search} onChange={(e) => { setSearch(e.target.value); setAsset(undefined); }} /></Field>
                {asset ? <p className="text-sm text-text-2">{asset.name} · {asset.currency}{asset.currency !== selected.currency ? ` · Choose a ${asset.currency} portfolio` : ""}</p>
                  : (results.data?.results.length ?? 0) > 0 && <ul className="divide-y divide-border rounded-lg border border-border">{results.data?.results.slice(0, 5).map((item) => <li key={item.id}><button type="button" className="w-full px-3 py-2 text-left text-sm hover:bg-surface-2" onClick={() => { setAsset(item); setSearch(item.symbol); }}>{item.symbol} · {item.name} · {item.currency}</button></li>)}</ul>}
                <Button type="submit" variant="primary" disabled={busy || !asset || asset.currency !== selected.currency}>Review order</Button>
              </form>
            )}
          </Card>}
          {feedback && <p role="status" className="rounded-lg border border-border bg-surface p-3 text-sm">{feedback}</p>}
          {!!query.data?.orders.length && <Card><CardHeader title="Recent practice orders" /><ul className="divide-y divide-border border-t border-border">
            {query.data.orders.slice().reverse().slice(0, 15).map((order) => <li key={order.id} className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm">
              <span className="capitalize">{order.side} {order.quantity} {order.instrument.symbol}</span>
              <span>{order.status}</span>
              {(order.status === "accepted" || order.status === "partiallyFilled") && <Button size="sm" disabled={busy} onClick={() => void perform(async () => { await practiceCall("cancelOrder", { orderID: order.id }, uuid()); await query.refetch(); })}>Cancel</Button>}
            </li>)}
          </ul></Card>}
        </>}
    </div>
  );
}
