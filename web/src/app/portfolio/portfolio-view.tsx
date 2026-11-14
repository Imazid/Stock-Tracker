"use client";

import { Wallet } from "lucide-react";
import { HoldingsCard } from "@/components/portfolio/holdings-card";
import { HoldingEvents } from "@/components/portfolio/holding-events";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageHeader } from "@/components/ui/PageHeader";
import { holdingComparison } from "@/lib/portfolio-holdings";
import { unrealisedGains } from "@/lib/portfolio-gains";
import { portfolioMovement } from "@/lib/portfolio-movement";
import { BrokerCash } from "./broker-cash";
import { ExposureCard } from "./exposure-card";
import { GainsCard } from "./gains-card";
import { MovementCard } from "./movement-card";
import { LotReport } from "./lot-report";
import { IncomeLedger } from "./income-ledger";
import { PerformanceLedger } from "./performance-ledger";
import { usePortfolioPositions } from "@/hooks/portfolio-positions";
import { usePortfolioGains, usePortfolioRates } from "@/hooks/portfolio-metrics";
import { useSession } from "@/lib/session";
import { PortfolioHistory } from "@/workspace/components/portfolio-history";
import "@/workspace/styles.css";

export function PortfolioView({ recordTransfer = false, logosEnabled, aiEnabled }: { recordTransfer?: boolean; logosEnabled: boolean; aiEnabled: boolean }) {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const { portfolio, holdings, pricedListings, quotes, pendingQuotes, loadingPrices } = usePortfolioPositions(userId);
  const gains = usePortfolioGains(userId);
  const rates = usePortfolioRates(pricedListings.some(({ instrument }) => instrument.currency !== "USD"));
  const quoteFor = (id: string) => quotes.get(id)?.data;
  const currentQuote = (id: string) => quoteFor(id)?.quote;
  const movement = portfolioMovement(pricedListings, currentQuote);
  const unrealised = gains.data && unrealisedGains(holdings, gains.data.open, currentQuote, rates.data);
  const comparison = holdingComparison(holdings, quoteFor, rates.data, unrealised?.byHolding);

  return (
    <div className="mx-auto max-w-5xl space-y-5">
      <PageHeader title="Portfolio" description="Holdings and saved valuations synced from Stock Tracker on iPhone."
        actions={userId && <a className="text-sm text-primary-fg underline" href="/api/portfolio/transactions">Export transactions CSV</a>} />
      {session.status === "unconfigured" ? (
        <Card><EmptyState title="Accounts are unavailable" /></Card>
      ) : session.status === "signedOut" ? (
        <Card><EmptyState icon={<Wallet aria-hidden />} title="Sign in to view your portfolio"
          actions={<ButtonLink href="/login?next=/portfolio" variant="primary">Sign in</ButtonLink>} /></Card>
      ) : session.status === "loading" || portfolio.isPending ? (
        <div className="skeleton h-28" role="status" aria-label="Loading portfolio" />
      ) : portfolio.isError ? (
        <Card><EmptyState title="Couldn’t load your portfolio" tone="down"
          actions={<Button onClick={() => void portfolio.refetch()}>Retry</Button>} /></Card>
      ) : (
        <>
          {userId && <div className="workspace portfolio-history-embed"><PortfolioHistory key={userId} userId={userId} /></div>}
          <HoldingsCard key={userId} comparison={comparison} pendingQuotes={pendingQuotes} truncated={portfolio.data?.truncated ?? false}
            logosEnabled={logosEnabled} gainsUnavailable={gains.isError} ratesUnavailable={rates.isError} />
          {holdings.length > 0 && <MovementCard movement={movement} holdingCount={holdings.length} loading={loadingPrices} aiEnabled={aiEnabled} />}
          {userId && holdings.length > 0 && <HoldingEvents key={userId} userId={userId} />}
          {holdings.length > 0 && <ExposureCard key={userId} holdings={holdings} quoteFor={quoteFor}
            loading={loadingPrices} truncated={portfolio.data?.truncated ?? false} />}
          {userId && <>
            <GainsCard key={userId + "-gains"} userId={userId} holdings={holdings} quoteFor={currentQuote}
              loading={loadingPrices} truncated={portfolio.data?.truncated ?? false} />
            <BrokerCash key={userId + "-cash"} userId={userId} />
            <PerformanceLedger key={`${userId}:${recordTransfer}`} userId={userId} recordTransfer={recordTransfer} />
            <IncomeLedger key={userId + "-income"} userId={userId} />
            <LotReport key={userId + "-lots"} userId={userId} />
          </>}
        </>
      )}
    </div>
  );
}
