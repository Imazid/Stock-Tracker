"use client";

import { useMutation, useQuery } from "@tanstack/react-query";
import { Building2, Search } from "lucide-react";
import { useState } from "react";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input, Select } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { PageHeader } from "@/components/ui/PageHeader";
import { Segmented } from "@/components/ui/Segmented";
import { supabaseConfigured } from "@/lib/env";
import { useSession } from "@/lib/session";
import { CompareRounds, DealCard, interpretedFilters } from "./catalog";
import { Monitoring } from "./monitoring";
import { availability, availabilityLabels, countryName, privateMarkets, type Discovery, type PrivateDeal } from "./private-data";
import { Positions } from "./positions";
import { ProviderApplication } from "./provider-application";
import { Research } from "./research";

type Tab = "catalogue" | "research" | "portfolio" | "updates";
function SignIn({ view }: { view?: Tab }) {
  const destination = view && view !== "catalogue" ? `/private-markets?view=${view}` : "/private-markets";
  return <ButtonLink variant="primary" size="sm" href={`/login?next=${encodeURIComponent(destination)}`}>Sign in</ButtonLink>;
}

function Discover({ owner, aiEnabled, deals, asOf, selected, toggle, onResearch }: {
  owner?: string; aiEnabled: boolean; deals: PrivateDeal[]; asOf: number; selected: PrivateDeal[];
  toggle: (deal: PrivateDeal) => void; onResearch: () => void;
}) {
  const [name, setName] = useState("");
  const [category, setCategory] = useState("");
  const [sector, setSector] = useState("");
  const [stage, setStage] = useState("");
  const [currency, setCurrency] = useState("");
  const [maxMinimum, setMaxMinimum] = useState("");
  const [maxValuation, setMaxValuation] = useState("");
  const [traction, setTraction] = useState(false);
  const [country, setCountry] = useState("");
  const [jurisdiction, setJurisdiction] = useState("");
  const [status, setStatus] = useState("");
  const [eligibility, setEligibility] = useState("");
  const [prompt, setPrompt] = useState("");
  const [consent, setConsent] = useState(false);
  const search = useMutation({
    mutationFn: (question: string) => privateMarkets<Discovery>("discover", { owner, question, model_consent: true }),
  });

  const currentAt = Math.max(asOf, search.submittedAt);
  const query = name.trim().normalize("NFKC").toLowerCase();
  const within = (value: number | null, ceiling: string) => !ceiling || (value !== null && value <= Number(ceiling));
  const visible = (search.data?.deals ?? deals).filter((deal) => {
    const company = deal.round.company;
    return (!query || [company.name, deal.round.stage, company.sector].some((value) => value.normalize("NFKC").toLowerCase().includes(query))) &&
      (!category || deal.category === category) && (!sector || company.sector === sector) &&
      (!country || company.country === country) && (!jurisdiction || deal.jurisdictions.includes(jurisdiction)) &&
      (!status || availability(deal, currentAt) === status) && (!eligibility || deal.eligibility === eligibility) &&
      (!stage || deal.round.stage === stage) && (!traction || Boolean(deal.round.traction || company.financials.length)) &&
      (!currency || (deal.round.currency === currency && within(deal.minimum, maxMinimum) && within(deal.round.valuation, maxValuation)));
  });
  const filters = [
    { id: "private-category", label: "Category", value: category, set: setCategory, options: deals.map(({ category }) => [category, category]) },
    { id: "private-sector", label: "Sector", value: sector, set: setSector, options: deals.map(({ round }) => [round.company.sector, round.company.sector]) },
    { id: "private-stage", label: "Funding stage", value: stage, set: setStage, options: deals.map(({ round }) => [round.stage, round.stage]) },
    { id: "private-country", label: "Company location", value: country, set: setCountry, options: deals.map(({ round }) => [round.company.country, countryName(round.company.country)]) },
    { id: "private-jurisdiction", label: "Investor jurisdiction", value: jurisdiction, set: setJurisdiction,
      options: deals.flatMap(({ jurisdictions }) => jurisdictions.map((code) => [code, countryName(code)])) },
    { id: "private-status", label: "Availability", value: status, set: setStatus, options: Object.entries(availabilityLabels) },
    { id: "private-eligibility", label: "Disclosed eligibility", value: eligibility, set: setEligibility, options: [["retail", "Retail"], ["wholesale", "Wholesale"], ["provider review", "Provider review"]] },
  ];
  const interpreted = search.data ? interpretedFilters(search.data.criteria) : [];

  return (
    <div className="space-y-4">
      <Card>
        <div className="grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-4">
          <Field label="Find a company or round" htmlFor="private-filter" className="sm:col-span-2">
            <Input id="private-filter" type="search" value={name} onChange={(event) => setName(event.target.value)} />
          </Field>
          {filters.map(({ id, label, value, set, options }) => (
            <Field key={id} label={label} htmlFor={id}>
              <Select id={id} value={value} onChange={(event) => set(event.target.value)}>
                <option value="">All</option>
                {[...new Map(options.map(([key, value]) => [key, value]))].sort((a, b) => a[1].localeCompare(b[1])).map(([key, text]) => (
                  <option key={key} value={key}>{text}</option>
                ))}
              </Select>
            </Field>
          ))}
        </div>
        <details className="border-t border-border px-4 py-3">
          <summary className="cursor-pointer text-sm font-medium text-text">Investment size and traction</summary>
          <div className="mt-3 grid gap-3 sm:grid-cols-3">
            <Field label="Reported currency" htmlFor="private-currency">
              <Select id="private-currency" value={currency} onChange={(event) => setCurrency(event.target.value)}>
                <option value="">All</option>
                {[...new Set(deals.map(({ round }) => round.currency))].sort().map((code) => <option key={code}>{code}</option>)}
              </Select>
            </Field>
            <Field label="Maximum minimum investment" htmlFor="private-max-minimum">
              <Input id="private-max-minimum" type="number" min="0" step="any" disabled={!currency} value={maxMinimum}
                onChange={(event) => setMaxMinimum(event.target.value)} />
            </Field>
            <Field label="Maximum reported valuation" htmlFor="private-max-valuation">
              <Input id="private-max-valuation" type="number" min="0" step="any" disabled={!currency} value={maxValuation}
                onChange={(event) => setMaxValuation(event.target.value)} />
            </Field>
            <label className="flex items-center gap-2 text-[13px] text-text-2">
              <input type="checkbox" checked={traction} onChange={(event) => setTraction(event.target.checked)} /> Disclosed traction
            </label>
          </div>
        </details>
        {aiEnabled && <details className="border-t border-border px-4 py-3">
          <summary className="cursor-pointer text-sm font-medium text-text">Search with AI</summary>
          {owner ? <form className="mt-3 space-y-3" onSubmit={(event) => {
            event.preventDefault();
            if (!consent || !prompt.trim() || search.isPending) return;
            setConsent(false);
            search.mutate(prompt.trim());
          }}>
            <Field label="What are you looking for?" htmlFor="private-search-question">
              <Input id="private-search-question" value={prompt} maxLength={600} required
                onChange={(event) => { setPrompt(event.target.value); setConsent(false); }} />
            </Field>
            <label className="flex items-start gap-2 text-[13px] text-text-2">
              <input className="mt-0.5" type="checkbox" checked={consent} disabled={search.isPending}
                onChange={(event) => setConsent(event.target.checked)} />
              <span>Allow Stock Tracker to send this search to its AI provider.</span>
            </label>
            <Button type="submit" size="sm" variant="primary" disabled={!consent || !prompt.trim() || search.isPending}>
              <Search className="h-4 w-4" aria-hidden />{search.isPending ? "Searching…" : "Search published rounds"}
            </Button>
            {search.error && <Notice tone="down">{search.error.message}</Notice>}
          </form> : <div className="mt-3"><SignIn /></div>}
        </details>}
      </Card>
      {search.data && <Card>
        <CardHeader title="AI search results" subtitle={`${search.data.matched_count} published matches`}
          actions={<Button size="sm" onClick={() => search.reset()}>Clear AI search</Button>} />
        <div className="space-y-2 border-t border-border p-4 text-[13px] text-text-2">
          {!!interpreted.length && <dl className="flex flex-wrap gap-x-4 gap-y-1">{interpreted.map(({ label, value }) => (
            <div key={label}><dt className="inline font-medium text-text">{label} </dt><dd className="inline">{value}</dd></div>
          ))}</dl>}
          {!!search.data.criteria.unsupported.length && <Notice tone="warn" title="Clarify your search">
            {search.data.criteria.unsupported.join(" · ")}
          </Notice>}
          {(!search.data.scanned_all || search.data.matched_count > search.data.deals.length) && <p>Showing matches from the current catalogue search window.</p>}
        </div>
      </Card>}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-[13px] text-text-2" role="status">{visible.length} {visible.length === 1 ? "round" : "rounds"}</p>
        {selected.length > 0 && <Button size="sm" variant="primary" onClick={onResearch}>Research selected rounds ({selected.length})</Button>}
      </div>
      {selected.length > 1 && <Card>
        <CardHeader title="Compare funding rounds" />
        <div className="border-t border-border p-4"><CompareRounds deals={selected} asOf={currentAt} /></div>
      </Card>}
      {visible.length ? <div className="grid items-start gap-4 2xl:grid-cols-2">
        {visible.map((deal) => <DealCard key={deal.id} deal={deal} asOf={currentAt} selected={selected.some(({ id }) => id === deal.id)}
          selectionFull={selected.length >= 3} onSelect={() => toggle(deal)}
          application={<ProviderApplication key={JSON.stringify([deal.offer_document_url, deal.verified_at, deal.round.verified_at,
            deal.round.currency, deal.round.closes_at, deal.minimum])} owner={owner} deal={deal} />} />)}
      </div> : <Card><EmptyState icon={<Building2 className="h-5 w-5" aria-hidden />} title="No matching rounds" body="Change the filters to see more published records." /></Card>}
    </div>
  );
}

export function PrivateMarketsView({ aiEnabled, initialTab }: { aiEnabled: boolean; initialTab: Tab }) {
  const [tab, setTab] = useState(initialTab);
  const [selected, setSelected] = useState<PrivateDeal[]>([]);
  const [openedReport, setOpenedReport] = useState<{ owner: string; id: string } | null>(null);
  const session = useSession();
  const owner = session.status === "signedIn" ? session.user.id : undefined;
  const catalogue = useQuery({
    queryKey: ["private-markets", "catalogue"], enabled: supabaseConfigured,
    queryFn: ({ signal }) => privateMarkets<{ deals: PrivateDeal[] }>("catalog", { signal }),
  });

  function toggle(deal: PrivateDeal) {
    setSelected((current) => {
      if (current.some(({ id }) => id === deal.id)) return current.filter(({ id }) => id !== deal.id);
      return current.length < 3 ? [...current, deal] : current;
    });
  }

  return (
    <div className="mx-auto max-w-[1300px]">
      <PageHeader title="Private Markets" description="Explore published funding rounds, research private companies, and review provider-confirmed activity." />
      <Segmented<Tab> value={tab} onChange={(value) => { setOpenedReport(null); setTab(value); }} label="Private Markets sections"
        className="mb-4 max-w-full flex-wrap [&>button]:px-2 sm:[&>button]:px-2.5"
        options={[{ value: "catalogue", label: "Discover" }, { value: "research", label: "AI Research" }, { value: "portfolio", label: "Portfolio & applications" }, { value: "updates", label: "Updates" }]} />
      {tab === "catalogue" && (!supabaseConfigured ? <Notice>Private Markets is unavailable in this deployment.</Notice>
        : catalogue.error ? <Notice tone="down">{catalogue.error.message} <Button size="sm" onClick={() => void catalogue.refetch()}>Retry</Button></Notice>
        : !catalogue.data ? <p className="text-sm text-text-2" role="status">Loading published rounds…</p>
        : <Discover key={owner ?? "public"} owner={owner} aiEnabled={aiEnabled} deals={catalogue.data.deals} asOf={catalogue.dataUpdatedAt}
          selected={selected} toggle={toggle} onResearch={() => setTab("research")} />)}
      {tab !== "catalogue" && (owner ? tab === "research"
        ? <Research key={owner} owner={owner} selected={selected} aiEnabled={aiEnabled} asOf={catalogue.dataUpdatedAt}
          initialReportID={openedReport?.owner === owner ? openedReport.id : undefined} />
        : tab === "portfolio" ? <Positions key={owner} owner={owner} />
        : <Monitoring key={owner} owner={owner} deals={catalogue.data?.deals ?? []} catalogueLoading={catalogue.isLoading}
          catalogueError={catalogue.error} retryCatalogue={() => void catalogue.refetch()}
          onReport={(id) => { setOpenedReport({ owner, id }); setTab("research"); }} />
        : session.status === "loading" ? <p className="text-sm text-text-2" role="status">Checking account…</p>
        : <Card><EmptyState title={tab === "research" ? "Sign in for AI research and saved reports" :
          tab === "updates" ? "Sign in to follow companies and see monitoring alerts" : "Sign in to see your private portfolio"}
          actions={session.status === "signedOut" ? <SignIn view={tab} /> : undefined} /></Card>)}
    </div>
  );
}
