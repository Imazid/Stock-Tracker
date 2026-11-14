"use client";

import { useState } from "react";
import { Wallet } from "lucide-react";
import { HoldingsCard } from "@/components/portfolio/holdings-card";
import { HoldingEvents } from "@/components/portfolio/holding-events";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageHeader } from "@/components/ui/PageHeader";
import { holdingComparison } from "@/lib/portfolio-holdings";
import { unrealisedGains } from "@/lib/portfolio-gains";
import { portfolioMovement } from "@/lib/portfolio-movement";
import { AllocationCard } from "./allocation-card";
import { BrokerCash } from "./broker-cash";
import { ExposureCard } from "./exposure-card";
import { GainsCard } from "./gains-card";
import { MovementCard } from "./movement-card";
import { LotReport } from "./lot-report";
import { IncomeLedger } from "./income-ledger";
import { PerformanceLedger } from "./performance-ledger";
import { mainPortfolioId, usePortfolioGroups } from "@/hooks/portfolio-groups";
import { usePortfolioPositions } from "@/hooks/portfolio-positions";
import { usePortfolioGains, usePortfolioRates } from "@/hooks/portfolio-metrics";
import { useSession } from "@/lib/session";
import { PortfolioHistory } from "@/workspace/components/portfolio-history";
import "@/workspace/styles.css";

export function PortfolioView({ recordTransfer = false, logosEnabled, aiEnabled }: { recordTransfer?: boolean; logosEnabled: boolean; aiEnabled: boolean }) {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  return <AccountPortfolio key={userId ?? session.status} recordTransfer={recordTransfer} logosEnabled={logosEnabled}
    aiEnabled={aiEnabled} userId={userId} status={session.status} />;
}

function AccountPortfolio({ recordTransfer, logosEnabled, aiEnabled, userId, status }: {
  recordTransfer: boolean; logosEnabled: boolean; aiEnabled: boolean; userId?: string;
  status: ReturnType<typeof useSession>["status"];
}) {
  const [selection, setSelection] = useState("all");
  const [editing, setEditing] = useState<{ action: "create" | "rename" | "delete"; id?: string; name?: string } | null>(null);
  const [draft, setDraft] = useState("");
  const { groups, change } = usePortfolioGroups(userId);
  const selected = groups.data?.find(group => group.id === selection);
  const { portfolio, holdings, pricedListings, quotes, pendingQuotes, loadingPrices } = usePortfolioPositions(userId, selected?.id);
  const gains = usePortfolioGains(userId);
  const rates = usePortfolioRates(pricedListings.some(({ instrument }) => instrument.currency !== "USD"));
  const quoteFor = (id: string) => quotes.get(id)?.data;
  const currentQuote = (id: string) => quoteFor(id)?.quote;
  const movement = portfolioMovement(pricedListings, currentQuote);
  const unrealised = gains.data && unrealisedGains(holdings, gains.data.open, currentQuote, rates.data);
  const comparison = holdingComparison(holdings, quoteFor, rates.data, unrealised?.byHolding);

  return (
    <div className="mx-auto max-w-5xl space-y-5">
      <PageHeader title="Portfolio" description="View holdings and daily values across your portfolios."
        actions={<>
          <ButtonLink href="/private-markets?view=portfolio" size="sm">Private portfolio</ButtonLink>
          {userId && <a className="text-sm text-primary-fg underline" href="/api/portfolio/transactions">Export transactions CSV</a>}
        </>} />
      {userId && <Card className="space-y-3 px-4 py-3">
        {groups.isError ? <Notice tone="warn">The portfolio list couldn’t be loaded. <Button size="sm" onClick={() => void groups.refetch()}>Retry</Button></Notice>
          : <div className="flex flex-wrap items-end gap-2">
            <Field label="Portfolio" htmlFor="portfolio-group" className="w-full min-w-0 sm:w-64">
              <Select id="portfolio-group" value={selected?.id ?? "all"} disabled={change.isPending} onChange={e => { setSelection(e.target.value); setEditing(null); change.reset(); }}>
                <option value="all">All portfolios</option>
                {groups.data?.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}
              </Select>
            </Field>
            <Button disabled={!groups.data || change.isPending} onClick={() => { change.reset(); setDraft(""); setEditing({ action: "create" }); }}>New portfolio</Button>
            {selected && <Button disabled={change.isPending} onClick={() => { change.reset(); setDraft(selected.name); setEditing({ action: "rename", id: selected.id, name: selected.name }); }}>Rename</Button>}
            {selected && selected.id !== mainPortfolioId && <Button variant="ghost" disabled={change.isPending} onClick={() => { change.reset(); setEditing({ action: "delete", id: selected.id, name: selected.name }); }}>Delete</Button>}
          </div>}
        {editing && <form className="flex flex-wrap items-end gap-2" onSubmit={event => {
          event.preventDefault();
          const id = editing.action === "create" ? crypto.randomUUID() : editing.id;
          if (!id) return;
          const name = draft.trim();
          if (editing.action !== "delete" && (!name || Array.from(name).length > 80)) return;
          change.mutate({ action: editing.action, id, name: editing.action === "delete" ? undefined : name }, {
            onSuccess: () => { setSelection(editing.action === "delete" ? "all" : id); setEditing(null); },
          });
        }}>
          {editing.action === "delete" ? <p className="w-full text-sm">Delete {editing.name}? Its transaction records will be retained for reports.</p>
            : <Field label="Portfolio name" htmlFor="portfolio-name" className="w-full min-w-0 sm:w-64">
              <Input id="portfolio-name" value={draft} onChange={e => setDraft(e.target.value)} required autoFocus />
            </Field>}
          <Button type="submit" variant={editing.action === "delete" ? "danger" : "primary"}
            disabled={change.isPending || (editing.action !== "delete" && (!draft.trim() || Array.from(draft.trim()).length > 80))}>
            {editing.action === "delete" ? "Confirm deletion" : "Save portfolio"}
          </Button>
          <Button variant="ghost" disabled={change.isPending} onClick={() => { setEditing(null); change.reset(); }}>Cancel</Button>
        </form>}
        {change.isError && <Notice tone="down">{change.error.message}</Notice>}
      </Card>}
      {status === "unconfigured" ? (
        <Card><EmptyState title="Accounts are unavailable" /></Card>
      ) : status === "signedOut" ? (
        <Card><EmptyState icon={<Wallet aria-hidden />} title="Sign in to view your portfolio"
          actions={<ButtonLink href="/login?next=/portfolio" variant="primary">Sign in</ButtonLink>} /></Card>
      ) : status === "loading" || portfolio.isPending ? (
        <div className="skeleton h-28" role="status" aria-label="Loading portfolio" />
      ) : portfolio.isError ? (
        <Card><EmptyState title="Couldn’t load your portfolio" tone="down"
          actions={<Button onClick={() => void portfolio.refetch()}>Retry</Button>} /></Card>
      ) : (
        <>
          {userId && !selected && <AllocationCard owner={userId} holdings={holdings} quoteFor={quoteFor}
            loading={loadingPrices} truncated={portfolio.data?.truncated ?? false} />}
          {userId && <div className="workspace portfolio-history-embed"><PortfolioHistory key={selected?.id ?? "all"} userId={userId}
            group={selected?.id === mainPortfolioId ? undefined : selected?.id} groupName={selected?.name} /></div>}
          <HoldingsCard key={selected?.id ?? "all"} comparison={comparison} pendingQuotes={pendingQuotes} truncated={portfolio.data?.truncated ?? false}
            logosEnabled={logosEnabled} gainsUnavailable={gains.isError} ratesUnavailable={rates.isError} />
          {holdings.length > 0 && <MovementCard movement={movement} holdingCount={holdings.length} loading={loadingPrices} aiEnabled={aiEnabled && !selected} />}
          {userId && !selected && holdings.length > 0 && <HoldingEvents key={userId} userId={userId} />}
          {holdings.length > 0 && <ExposureCard key={userId} holdings={holdings} quoteFor={quoteFor}
            loading={loadingPrices} truncated={portfolio.data?.truncated ?? false} />}
          {holdings.length > 0 && <ButtonLink href="/#portfolio">Manage holdings</ButtonLink>}
          {selected && <p className="text-sm text-text-2">For account-wide cash, statement returns and tax records, choose All portfolios.</p>}
          {userId && !selected && <>
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
