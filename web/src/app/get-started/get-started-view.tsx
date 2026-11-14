"use client";

import Link from "next/link";
import { useState } from "react";
import { SourceLine } from "@/components/market/DataChips";
import { DEFAULT_INDICATORS, PriceChart } from "@/components/market/PriceChart";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Field, Select } from "@/components/ui/Field";
import { PageHeader } from "@/components/ui/PageHeader";
import { useCandles } from "@/hooks/market";
import { useWatchlist, useWatchlistMutations } from "@/hooks/watchlist";
import { money } from "@/lib/format";
import { toView } from "@/lib/instrument-view";
import { useSession } from "@/lib/session";
import { asxStock, cryptoAsset, usStock } from "@engine/market.ts";
import { Connections } from "@/workspace/components/research";
import { BrokerCash } from "../portfolio/broker-cash";
import "@/workspace/styles.css";

const interests = [
  { label: "US shares", instrument: toView(usStock("AAPL", "Apple")), increment: 1 },
  { label: "Australian shares", instrument: toView(asxStock("BHP", "BHP Group")), increment: 1 },
  { label: "Crypto", instrument: toView(cryptoAsset("BTC", "Bitcoin")), increment: 0.001 },
] as const;
const sampleCash = 2_500;
const signup = "/login?mode=signup&next=/get-started";
const signin = "/login?next=/get-started";

function DemoPortfolio({ interest }: { interest: typeof interests[number] }) {
  const [units, setUnits] = useState(5);
  const { instrument, increment } = interest;
  const quantity = units * increment;
  const history = useCandles(instrument.id, "1M");
  const source = history.data;
  const bars = source?.candles.map((bar) => ({
    ...bar,
    open: sampleCash + quantity * bar.open,
    high: sampleCash + quantity * bar.high,
    low: sampleCash + quantity * bar.low,
    close: sampleCash + quantity * bar.close,
  })) ?? [];
  const last = bars.at(-1);

  return (
    <Card>
      <CardHeader title={<>Portfolio demo <Badge tone="warn">Sample</Badge></>}
        subtitle="Change the sample holding to see how market prices affect the portfolio." />
      <div className="space-y-4 border-t border-border p-4">
        <div className="flex flex-wrap justify-between gap-4">
          <div>
            <p className="text-sm text-text-2">{last ? "Sample portfolio value" : "Sample cash"}</p>
            <p className="tabular text-3xl font-semibold" aria-live="polite">{money(last?.close ?? sampleCash, instrument.currency)}</p>
          </div>
          <Field htmlFor="demo-quantity" label={`${instrument.symbol} units`}>
            <Select id="demo-quantity" value={units} onChange={(event) => setUnits(Number(event.target.value))}>
              {[0, 1, 5, 10, 20].map((size) => <option key={size} value={size}>{size * increment}</option>)}
            </Select>
          </Field>
        </div>
        {last && source ? (
          <>
            <PriceChart candles={bars} type="area" indicators={{ ...DEFAULT_INDICATORS, volume: false }} intraday={false}
              height={230} ariaLabel={`Sample portfolio value over one month with ${instrument.symbol}`} />
            <SourceLine source={source.source} currency={source.currency} observedAt={source.observedAt} />
          </>
        ) : (
          <div className="flex min-h-28 flex-wrap items-center justify-between gap-2 rounded-lg border border-border px-3">
            <p role="status" className="text-sm text-text-2">{history.isPending ? "Loading market history…" : "Market history is unavailable."}</p>
            {!history.isPending && <Button size="sm" onClick={() => void history.refetch()}>Retry</Button>}
          </div>
        )}
        <p className="text-xs text-text-2">{money(sampleCash, instrument.currency)} starting cash · Daily market prices · Fees excluded</p>
      </div>
    </Card>
  );
}

export function GetStartedView({ brokerageEnabled, aiEnabled }: { brokerageEnabled: boolean; aiEnabled: boolean }) {
  const session = useSession();
  const [interest, setInterest] = useState<(typeof interests)[number]>(interests[0]);
  const watchlist = useWatchlist();
  const userId = session.status === "signedIn" ? session.user.id : undefined;

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <PageHeader title="Get started with Stock Tracker" />
      {session.status === "signedOut" && <Card>
        <CardHeader title="Your Stock Tracker account" subtitle="Save your watchlist and portfolio across web and iPhone." />
        <div className="flex flex-wrap gap-2 border-t border-border p-4">
          <ButtonLink href={signup} variant="primary">Create an account</ButtonLink>
          <ButtonLink href={signin}>Sign in</ButtonLink>
        </div>
      </Card>}
      <Card>
        <CardHeader title="What do you want to explore?" />
        <div className="space-y-3 border-t border-border p-4">
          <div className="flex flex-wrap gap-2" role="group" aria-label="Investing interests">
            {interests.map((option) => <Button key={option.label} aria-pressed={option === interest}
              variant={option === interest ? "primary" : "secondary"} onClick={() => setInterest(option)}>
              {option.label}
            </Button>)}
          </div>
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <Link className="text-primary-fg underline" href={`/markets/${encodeURIComponent(interest.instrument.id)}`}>
              Research {interest.instrument.symbol}
            </Link>
            {userId && <FollowInterest key={`${userId}:${interest.label}`} interest={interest}
              saved={watchlist.data?.some(({ instrument }) => instrument.id === interest.instrument.id) ?? false}
              loading={watchlist.isPending} />}
          </div>
        </div>
      </Card>
      <DemoPortfolio key={interest.label} interest={interest} />
      {userId && <>
        <div className="workspace onboarding-brokerage"><Connections key={userId} enabled={brokerageEnabled} userId={userId} /></div>
        {brokerageEnabled && <BrokerCash key={userId} userId={userId} />}
      </>}
      <Card>
        <CardHeader title="Continue to your workspace" />
        <div className="flex flex-wrap gap-2 border-t border-border p-4">
          <ButtonLink href="/" variant="primary">Open dashboard</ButtonLink>
          <ButtonLink href="/markets">Explore markets</ButtonLink>
          <ButtonLink href="/paper">Practise trading</ButtonLink>
          <ButtonLink href="/settings">Preferences</ButtonLink>
          {aiEnabled && <ButtonLink href="/ai">Open AI assistant</ButtonLink>}
        </div>
      </Card>
    </div>
  );
}

function FollowInterest({ interest, saved, loading }: { interest: typeof interests[number]; saved: boolean; loading: boolean }) {
  const { add } = useWatchlistMutations();
  const { instrument } = interest;
  const following = saved || add.isSuccess;
  return <>
    <Button size="sm" disabled={loading || add.isPending || following} onClick={() => add.mutate(instrument)}>
      {following ? `${instrument.symbol} is on your watchlist` : `Follow ${instrument.symbol}`}
    </Button>
    {add.isError && <p className="text-sm text-down" role="alert">Couldn’t save the watchlist. Try again.</p>}
  </>;
}
