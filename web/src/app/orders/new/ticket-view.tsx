"use client";

import type { BrokerOrderType, BrokerTimeInForce } from "@brokers/types.ts";
import type { OrderIntentInput } from "@oms/api.ts";
import { useMutation } from "@tanstack/react-query";
import { useRouter, useSearchParams } from "next/navigation";
import { useState } from "react";
import { MarketChip, SourceLine } from "@/components/market/DataChips";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { Segmented } from "@/components/ui/Segmented";
import { useQuote } from "@/hooks/market";
import { providerAssetClass, useOrderPath } from "@/hooks/oms";
import { money } from "@/lib/format";
import { describeOmsError, newIdempotencyKey, Orders } from "@/lib/oms-client";

const DECIMAL = /^\d+(\.\d+)?$/;

/** The provider's own symbol for a listing: Alpaca "BTC/USD", Coinbase "BTC-USD", stocks bare. */
function providerSymbol(provider: string, venue: string, symbol: string): string {
  if (venue !== "crypto") return symbol;
  return provider === "coinbase" ? `${symbol}-USD` : `${symbol}/USD`;
}

export function TicketView() {
  const params = useSearchParams();
  const router = useRouter();
  const id = params.get("instrument") ?? undefined;
  const quote = useQuote(id, { refetchMs: 10_000 });
  const instrument = quote.data?.instrument;
  const path = useOrderPath(instrument);
  const [side, setSide] = useState<"buy" | "sell">(params.get("side") === "sell" ? "sell" : "buy");
  const [connectionID, setConnectionID] = useState<string>("");
  // A ticket the assistant prepared arrives as query parameters; it only fills the form.
  const prefill = (key: string) => {
    const v = params.get(key);
    return v !== null && DECIMAL.test(v) ? v : "";
  };
  const fromAssistant = params.get("origin") === "assistant";
  const [type, setType] = useState<BrokerOrderType>(params.get("type") === "limit" ? "limit" : "market");
  const [tif, setTif] = useState<BrokerTimeInForce>("day");
  const [sizeMode, setSizeMode] = useState<"quantity" | "notional">(prefill("notional") ? "notional" : "quantity");
  const [size, setSize] = useState(prefill("quantity") || prefill("notional"));
  const [limit, setLimit] = useState(prefill("limit"));
  const [stop, setStop] = useState("");
  const [key] = useState(newIdempotencyKey);

  const connection = path.connections.find((c) => c.id === connectionID) ?? path.connections[0];
  const cls = instrument ? providerAssetClass(instrument) : undefined;
  const cap = connection?.capabilities.orders.find((o) => o.assetClass === cls);
  const tifs = cap?.timeInForce[type] ?? [];
  const effectiveTif = tifs.includes(tif) ? tif : tifs[0];
  const notionalAllowed = Boolean(cap?.notional);

  const problems: string[] = [];
  {
    const out = problems;
    if (!DECIMAL.test(size) || Number(size) <= 0) out.push(sizeMode === "quantity" ? "Enter a quantity." : "Enter an amount.");
    if ((type === "limit" || type === "stop_limit") && (!DECIMAL.test(limit) || Number(limit) <= 0)) out.push("Enter a limit price.");
    if ((type === "stop" || type === "stop_limit") && (!DECIMAL.test(stop) || Number(stop) <= 0)) out.push("Enter a stop price.");
    if (!effectiveTif) out.push("This order type isn't available here.");
  }

  const draft = useMutation({
    mutationFn: async () => {
      const intent: OrderIntentInput = {
        connectionID: connection!.id,
        symbol: providerSymbol(connection!.provider, instrument!.venue, instrument!.symbol),
        assetClass: cls!, side, type, timeInForce: effectiveTif!,
        ...(sizeMode === "quantity" ? { quantity: size } : { notional: size }),
        ...(type === "limit" || type === "stop_limit" ? { limitPrice: limit } : {}),
        ...(type === "stop" || type === "stop_limit" ? { stopPrice: stop } : {}),
        origin: { kind: "manual" },
      };
      const drafted = await Orders.act({ action: "draft", intent }, key);
      const checked = await Orders.act({ action: "riskCheck", intentID: drafted.intent.id });
      return checked.intent;
    },
    onSuccess: (intent) => router.push(`/orders/${intent.id}`),
  });

  if (!id) return <EmptyState title="Pick an instrument first" body="Open an instrument from Markets and use Buy or Sell." actions={<ButtonLink href="/markets">Markets</ButtonLink>} />;
  if (path.loading || quote.isLoading) return <div className="mx-auto max-w-xl space-y-3"><div className="skeleton h-8 w-40" /><div className="skeleton h-96" /></div>;
  if (!path.available || !instrument || !connection || !cap) {
    return <div className="mx-auto max-w-xl"><Card><EmptyState tone="warn" title="No order path for this instrument"
      body="Orders need order routing deployed and a connected practice (paper) account that can trade this asset class. Nothing can be sent from here right now."
      actions={<><ButtonLink href="/connections">Connections</ButtonLink>{id ? <ButtonLink href={`/markets/${encodeURIComponent(id)}`}>Back</ButtonLink> : null}</>} /></Card></div>;
  }
  const q = quote.data?.quote;
  const err = draft.isError ? describeOmsError(draft.error) : null;

  return (
    <div className="mx-auto max-w-xl">
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <h1 className="text-xl font-semibold tracking-tight">Order ticket · {instrument.symbol}</h1>
        <Badge tone="warn">{connection.environment.toUpperCase()} — no real money</Badge>
      </div>
      {fromAssistant ? (
        <Notice className="mb-4" title="Filled in by the assistant">
          Check every field. Nothing has been sent: reviewing drafts the order, the risk engine checks it, and only you can approve it.
        </Notice>
      ) : null}
      <Card>
        <CardHeader title={q ? money(q.last, q.currency) : "No live price"} subtitle={q ? <SourceLine source={q.source} currency={q.currency} observedAt={q.observedAt} stale={q.stale} staleReason={q.staleReason} /> : undefined}
          actions={quote.data ? <MarketChip market={quote.data.market} /> : null} />
        <form className="grid gap-4 border-t border-border px-4 py-4" onSubmit={(e) => { e.preventDefault(); if (problems.length === 0) draft.mutate(); }}>
          <Segmented label="Side" value={side} onChange={setSide} className="w-full [&>button]:flex-1" options={[{ value: "buy", label: "Buy" }, { value: "sell", label: "Sell" }]} />
          <Field label="Account" htmlFor="t-account"><Select id="t-account" value={connection.id} onChange={(e) => setConnectionID(e.target.value)}>
            {path.connections.map((c) => <option key={c.id} value={c.id}>{c.label} · {c.environment}</option>)}</Select></Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Order type" htmlFor="t-type"><Select id="t-type" value={type} onChange={(e) => setType(e.target.value as BrokerOrderType)}>
              {cap.orderTypes.map((t) => <option key={t} value={t}>{t.replace("_", " ")}</option>)}</Select></Field>
            <Field label="Time in force" htmlFor="t-tif"><Select id="t-tif" value={effectiveTif ?? ""} onChange={(e) => setTif(e.target.value as BrokerTimeInForce)}>
              {tifs.map((t) => <option key={t} value={t}>{t.toUpperCase()}</option>)}</Select></Field>
          </div>
          <div className="grid gap-2">
            {notionalAllowed ? <Segmented label="Size by" value={sizeMode} onChange={setSizeMode} options={[{ value: "quantity", label: "Quantity" }, { value: "notional", label: `Amount (${instrument.currency})` }]} /> : null}
            <Field label={sizeMode === "quantity" ? (cap.fractional ? "Quantity (fractions allowed)" : "Quantity (whole units)") : `Amount in ${instrument.currency}`} htmlFor="t-size">
              <Input id="t-size" inputMode="decimal" value={size} onChange={(e) => setSize(e.target.value.trim())} placeholder={sizeMode === "quantity" ? "e.g. 1" : "e.g. 100"} /></Field>
          </div>
          {type === "limit" || type === "stop_limit" ? <Field label={`Limit price (${instrument.currency})`} htmlFor="t-limit"><Input id="t-limit" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value.trim())} /></Field> : null}
          {type === "stop" || type === "stop_limit" ? <Field label={`Stop price (${instrument.currency})`} htmlFor="t-stop"><Input id="t-stop" inputMode="decimal" value={stop} onChange={(e) => setStop(e.target.value.trim())} /></Field> : null}
          {connection.capabilities.notes.length ? <ul className="list-disc space-y-0.5 pl-4 text-[11px] text-text-3">{connection.capabilities.notes.map((n) => <li key={n}>{n}</li>)}</ul> : null}
          {err ? <Notice tone="down" title={err.title}>{err.body}</Notice> : null}
          <Button type="submit" variant={side === "buy" ? "buy" : "sell"} disabled={problems.length > 0 || draft.isPending}>
            {draft.isPending ? "Drafting and checking…" : `Review ${side} order`}
          </Button>
          <p className="text-[11px] text-text-3">{problems[0] ?? "Next: the risk check runs, then you review and approve. Nothing is sent until you approve and submit."}</p>
        </form>
      </Card>
    </div>
  );
}
