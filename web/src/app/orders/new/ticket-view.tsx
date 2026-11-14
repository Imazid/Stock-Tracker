"use client";

import type { BrokerOrderType, BrokerTimeInForce } from "@brokers/types.ts";
import type { OrderIntentInput } from "@oms/api.ts";
import { useMutation } from "@tanstack/react-query";
import { useRouter, useSearchParams } from "next/navigation";
import { useRef, useState } from "react";
import { MarketChip, SourceLine } from "@/components/market/DataChips";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { Segmented } from "@/components/ui/Segmented";
import { useInstrument, useQuote } from "@/hooks/market";
import { providerAssetClass, useOrderPath } from "@/hooks/oms";
import { money } from "@/lib/format";
import { accessToken, useSession } from "@/lib/session";
import { describeOmsError, newIdempotencyKey, OmsError, Orders } from "@/lib/oms-client";

const DECIMAL = /^(?:0|[1-9]\d{0,19})(?:\.\d{1,18})?$/;

/** The provider's own symbol for a listing: Alpaca "BTC/USD", Coinbase "BTC-USD", stocks bare. */
function providerSymbol(provider: string, venue: string, symbol: string): string {
  if (venue !== "crypto") return symbol;
  return provider === "coinbase" ? `${symbol}-USD` : `${symbol}/USD`;
}

export function TicketView() {
  const params = useSearchParams();
  const router = useRouter();
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const id = params.get("instrument") ?? undefined;
  const quote = useQuote(id, { refetchMs: 10_000 });
  const listing = useInstrument(id);
  const instrument = listing.data?.instrument ?? quote.data?.instrument;
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
  const pendingDraft = useRef<{ request: string; key: string } | null>(null);

  const connection = path.connections.find((c) => c.id === connectionID) ?? path.connections[0];
  const cls = instrument ? providerAssetClass(instrument) : undefined;
  const cap = connection?.capabilities.orders.find((o) => o.assetClass === cls);
  const tifs = cap?.timeInForce[type] ?? [];
  const effectiveTif = tifs.includes(tif) ? tif : tifs[0];
  const notionalAllowed = Boolean(cap?.notional && type === "market" && (connection?.provider !== "alpaca" || cls !== "us_equity" || effectiveTif === "day"));
  const fractionalAllowed = Boolean(cap?.fractional && (connection?.provider !== "alpaca" || cls !== "us_equity" || effectiveTif === "day"));
  const effectiveSizeMode = notionalAllowed ? sizeMode : "quantity";
  const changeType = (value: BrokerOrderType) => {
    if (sizeMode === "notional" && value !== "market") { setSizeMode("quantity"); setSize(""); }
    setType(value);
  };
  const changeTif = (value: BrokerTimeInForce) => {
    if (sizeMode === "notional" && connection?.provider === "alpaca" && cls === "us_equity" && value !== "day") {
      setSizeMode("quantity"); setSize("");
    }
    setTif(value);
  };

  const problems: string[] = [];
  {
    const out = problems;
    if (!DECIMAL.test(size) || Number(size) <= 0 || sizeMode !== effectiveSizeMode) out.push(effectiveSizeMode === "quantity" ? "Enter a quantity." : "Enter an amount.");
    if (effectiveSizeMode === "quantity" && !fractionalAllowed && /\.\d*[1-9]/.test(size)) out.push("Enter a whole quantity for this order.");
    if ((type === "limit" || type === "stop_limit") && (!DECIMAL.test(limit) || Number(limit) <= 0)) out.push("Enter a limit price.");
    if ((type === "stop" || type === "stop_limit") && (!DECIMAL.test(stop) || Number(stop) <= 0)) out.push("Enter a stop price.");
    if (!effectiveTif) out.push("This order type isn't available here.");
  }

  const draft = useMutation({
    mutationFn: async ({ intent, owner }: { intent: OrderIntentInput; owner: string }) => {
      const request = JSON.stringify({ owner, intent });
      const key = pendingDraft.current?.request === request ? pendingDraft.current.key : newIdempotencyKey();
      pendingDraft.current = { request, key };
      try {
        return (await Orders.act({ action: "draft", intent }, key, owner)).intent;
      } catch (error) {
        if (error instanceof OmsError && !["network", "not_deployed", "internal"].includes(error.code)) pendingDraft.current = null;
        throw error;
      }
    },
    onSuccess: async (intent, { owner }) => {
      pendingDraft.current = null;
      if (await accessToken(owner)) router.push(`/orders/${intent.id}`);
    },
  });

  if (!id) return <EmptyState title="Pick an instrument first" body="Open an instrument from Markets and use Buy or Sell." actions={<ButtonLink href="/markets">Markets</ButtonLink>} />;
  if (path.loading || listing.isLoading) return <div className="mx-auto max-w-xl space-y-3"><div className="skeleton h-8 w-40" /><div className="skeleton h-96" /></div>;
  if (!path.available || !instrument || !connection || !cap) {
    return <div className="mx-auto max-w-xl"><Card><EmptyState tone="warn" title="No order path for this instrument"
      body={path.unavailable ?? "Connect an eligible paper account to prepare an order for this asset."}
      actions={<><ButtonLink href="/connections">Connections</ButtonLink>{id ? <ButtonLink href={`/markets/${encodeURIComponent(id)}`}>Back</ButtonLink> : null}</>} /></Card></div>;
  }
  const prepare = () => {
    if (!userId || problems.length || draft.isPending) return;
    draft.mutate({ owner: userId, intent: {
      connectionID: connection.id,
      symbol: providerSymbol(connection.provider, instrument.venue, instrument.symbol),
      assetClass: cls!, side, type, timeInForce: effectiveTif!,
      ...(effectiveSizeMode === "quantity" ? { quantity: size } : { notional: size }),
      ...(type === "limit" || type === "stop_limit" ? { limitPrice: limit } : {}),
      ...(type === "stop" || type === "stop_limit" ? { stopPrice: stop } : {}),
      origin: { kind: "manual" },
    } });
  };
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
          Check every field before preparing the order for review.
        </Notice>
      ) : null}
      <Card>
        <CardHeader title={q ? money(q.last, q.currency) : "No live price"} subtitle={q ? <SourceLine source={q.source} currency={q.currency} observedAt={q.observedAt} stale={q.stale} staleReason={q.staleReason} /> : undefined}
          actions={quote.data ? <MarketChip market={quote.data.market} /> : null} />
        <form className="grid gap-4 border-t border-border px-4 py-4" onSubmit={(e) => { e.preventDefault(); prepare(); }}>
          <Segmented label="Side" value={side} onChange={setSide} className="w-full [&>button]:flex-1" options={[{ value: "buy", label: "Buy" }, { value: "sell", label: "Sell" }]} />
          <Field label="Account" htmlFor="t-account"><Select id="t-account" value={connection.id} onChange={(e) => { setConnectionID(e.target.value); setSizeMode("quantity"); setSize(""); }}>
            {path.connections.map((c) => <option key={c.id} value={c.id}>{c.label} · {c.environment}</option>)}</Select></Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Order type" htmlFor="t-type"><Select id="t-type" value={type} onChange={(e) => changeType(e.target.value as BrokerOrderType)}>
              {cap.orderTypes.map((t) => <option key={t} value={t}>{t.replace("_", " ")}</option>)}</Select></Field>
            <Field label="Time in force" htmlFor="t-tif"><Select id="t-tif" value={effectiveTif ?? ""} onChange={(e) => changeTif(e.target.value as BrokerTimeInForce)}>
              {tifs.map((t) => <option key={t} value={t}>{t.toUpperCase()}</option>)}</Select></Field>
          </div>
          <div className="grid gap-2">
            {notionalAllowed ? <Segmented label="Size by" value={effectiveSizeMode} onChange={(mode) => { setSizeMode(mode); setSize(""); }} options={[{ value: "quantity", label: "Quantity" }, { value: "notional", label: `Amount (${instrument.currency})` }]} /> : null}
            <Field label={effectiveSizeMode === "quantity" ? (fractionalAllowed ? "Quantity (fractions allowed)" : "Quantity (whole units)") : `Amount in ${instrument.currency}`} htmlFor="t-size">
              <Input id="t-size" inputMode="decimal" value={effectiveSizeMode === sizeMode ? size : ""} onChange={(e) => { setSizeMode(effectiveSizeMode); setSize(e.target.value.trim()); }} placeholder={effectiveSizeMode === "quantity" ? "e.g. 1" : "e.g. 100"} /></Field>
          </div>
          {type === "limit" || type === "stop_limit" ? <Field label={`Limit price (${instrument.currency})`} htmlFor="t-limit"><Input id="t-limit" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value.trim())} /></Field> : null}
          {type === "stop" || type === "stop_limit" ? <Field label={`Stop price (${instrument.currency})`} htmlFor="t-stop"><Input id="t-stop" inputMode="decimal" value={stop} onChange={(e) => setStop(e.target.value.trim())} /></Field> : null}
          {connection.capabilities.notes.length ? <ul className="list-disc space-y-0.5 pl-4 text-[11px] text-text-3">{connection.capabilities.notes.map((n) => <li key={n}>{n}</li>)}</ul> : null}
          {err ? <Notice tone="down" title={err.title}>{err.body}</Notice> : null}
          <Button type="submit" variant={side === "buy" ? "buy" : "sell"} disabled={!userId || problems.length > 0 || draft.isPending}>
            {draft.isPending ? "Preparing order…" : `Review ${side} order`}
          </Button>
          <p className="text-[11px] text-text-3">{problems[0] ?? "Review the draft, run the risk checks, then approve and submit the order."}</p>
        </form>
      </Card>
    </div>
  );
}
