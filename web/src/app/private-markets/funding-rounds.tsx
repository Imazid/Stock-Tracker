import { Building2 } from "lucide-react";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Field, Input } from "@/components/ui/Field";
import { Notice } from "@/components/ui/Notice";
import { CompareRounds, CompanyFacts, CompanyLogo, DealCard, hasUpcomingQuotation, SourceLink } from "./catalog";
import { availability, countryName, dateLabel, type PrivateCompany, type PrivateDeal } from "./private-data";
import { maxMonitoredCompanies, useWebMonitor } from "./web-monitor";

type RoundActions = {
  asOf: number;
  selected: PrivateDeal[];
  toggle: (deal: PrivateDeal) => void;
  onResearch: () => void;
  onScenario: (deal: PrivateDeal) => void;
  renderApplication: (deal: PrivateDeal) => ReactNode;
};

function CompareSelection({ selected, asOf, onResearch, toggle }: Pick<RoundActions, "selected" | "asOf" | "onResearch" | "toggle">) {
  if (!selected.length) return null;
  return <Card>
    <CardHeader title={selected.length > 1 ? "Compare funding rounds" : "Selected funding round"} />
    <div className="space-y-3 border-t border-border p-4">
      <CompareRounds deals={selected} asOf={asOf} onRemove={toggle} />
      <Button size="sm" variant="primary" onClick={onResearch}>Research selected rounds ({selected.length})</Button>
    </div>
  </Card>;
}

const statusOrder = { open: 0, interest: 1, closed: 2, expired: 3, unverified: 4 };

function distinctRounds(deals: PrivateDeal[], asOf: number) {
  const rounds = new Map<string, PrivateDeal>();
  for (const deal of deals) {
    const current = rounds.get(deal.round.id);
    if (!current || statusOrder[availability(deal, asOf)] < statusOrder[availability(current, asOf)]) {
      rounds.set(deal.round.id, deal);
    }
  }
  return [...rounds.values()];
}

function newestFirst(a: PrivateDeal, b: PrivateDeal) {
  const announced = (b.round.announced_on ?? "").localeCompare(a.round.announced_on ?? "");
  return announced || a.round.company.name.localeCompare(b.round.company.name) || a.id.localeCompare(b.id);
}

function byDeadline(a: PrivateDeal, b: PrivateDeal) {
  const first = a.round.closes_at ? Date.parse(a.round.closes_at) : Infinity;
  const second = b.round.closes_at ? Date.parse(b.round.closes_at) : Infinity;
  return first === second ? newestFirst(a, b) : first - second;
}

function RoundCards({ deals, actions, onCompany }: {
  deals: PrivateDeal[]; actions: RoundActions; onCompany?: (id: string) => void;
}) {
  return <div className="grid gap-4 2xl:grid-cols-2 2xl:items-start">
    {deals.map((deal) => <DealCard key={deal.id} deal={deal} asOf={actions.asOf}
      selected={actions.selected.some(({ round }) => round.id === deal.round.id)}
      selectionFull={actions.selected.length >= 3} onSelect={() => actions.toggle(deal)}
      onScenario={() => actions.onScenario(deal)} onCompany={onCompany ? () => onCompany(deal.round.company.id) : undefined}
      application={actions.renderApplication(deal)} />)}
  </div>;
}

function FollowCompany({ owner, company, showUpdates }: { owner: string; company: PrivateCompany; showUpdates: () => void }) {
  const { settings, save } = useWebMonitor(owner);
  const [confirm, setConfirm] = useState(false);
  const view = settings.data;
  const preferences = view?.preferences;
  const followIDs = preferences?.company_ids ?? [];
  const followed = followIDs.includes(company.id);
  const atLimit = !followed && followIDs.length >= maxMonitoredCompanies;
  const busy = settings.isFetching || save.isPending;

  function changeFollow() {
    if (!view || busy || atLimit) return;
    setConfirm(false);
    save.mutate({
      expected_revision: view.revision,
      expected_enabled: Boolean(preferences),
      enabled: true,
      company_ids: followed ? followIDs.filter((id) => id !== company.id) : [...followIDs, company.id],
      eligible_opportunities: preferences?.eligible_opportunities ?? false,
      digest_enabled: preferences?.digest_enabled ?? false,
    });
  }

  return <div className="space-y-2 border-t border-border pt-3">
    {settings.isPending && <p className="text-sm text-text-2" role="status">Loading watchlist…</p>}
    {settings.error && <Notice tone="down">{settings.error.message} <Button size="sm" onClick={() => void settings.refetch()}>Retry watchlist</Button></Notice>}
    {view && !settings.error && <div className="flex flex-wrap items-center gap-2">
      <Button size="sm" variant={followed ? "secondary" : "primary"} disabled={busy || atLimit || confirm}
        onClick={() => preferences ? changeFollow() : setConfirm(true)}>{followed ? "Unfollow company" : "Follow company"}</Button>
      {followed && <Button size="sm" onClick={showUpdates}>View company updates</Button>}
      {save.isPending && <p className="text-xs text-text-2" role="status">Saving watchlist…</p>}
      {save.isSuccess && <p className="text-xs text-text-2" role="status">{followed ? "Company followed." : "Company unfollowed."}</p>}
    </div>}
    {confirm && <div className="space-y-2 text-sm text-text-2">
      <p>Enable web monitoring to collect this company’s published updates and provider-confirmed activity in your account inbox.</p>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="primary" disabled={busy || settings.isError} onClick={changeFollow}>Enable monitoring and follow</Button>
        <Button size="sm" onClick={() => setConfirm(false)}>Cancel</Button>
      </div>
    </div>}
    {atLimit && <p className="text-xs text-text-2">Your watchlist has {maxMonitoredCompanies} companies. Unfollow a company before adding another.</p>}
    {save.error && <Notice tone="down">{save.error.message}</Notice>}
  </div>;
}

export function StartupExplorer({ deals, companyID, setCompany, actions, owner, signedOut, showUpdates }: {
  deals: PrivateDeal[]; companyID: string | null; setCompany: (id: string | null) => void; actions: RoundActions;
  owner?: string; signedOut: boolean; showUpdates: () => void;
}) {
  const [query, setQuery] = useState("");
  const companyHeading = useRef<HTMLHeadingElement>(null);
  const search = useRef<HTMLDivElement>(null);
  const focusSearch = useRef(false);
  const rounds = distinctRounds(deals, actions.asOf);
  const companies = [...new Map(rounds.map(({ round }) => [round.company.id, round.company])).values()]
    .sort((a, b) => a.name.localeCompare(b.name));
  const company = companies.find(({ id }) => id === companyID);
  useEffect(() => {
    if (companyID) companyHeading.current?.focus();
    else if (focusSearch.current) {
      search.current?.querySelector("input")?.focus();
      focusSearch.current = false;
    }
  }, [companyID]);
  const term = query.trim().normalize("NFKC").toLowerCase();
  const matches = companies.filter((entry) => [entry.name, entry.sector, entry.location ?? countryName(entry.country)]
    .some((value) => value.normalize("NFKC").toLowerCase().includes(term)));

  if (company) {
    const history = rounds.filter(({ round }) => round.company.id === company.id).sort(newestFirst);
    return <div className="space-y-4">
      <Button size="sm" onClick={() => { focusSearch.current = true; setCompany(null); }}>All companies</Button>
      <Card as="article" className="space-y-3 p-4 md:p-5">
        <div className="flex items-center gap-3">
          <CompanyLogo url={company.logo_url} />
          <div>
            <h2 ref={companyHeading} tabIndex={-1} className="text-xl font-semibold text-text">{company.name}</h2>
            <p className="text-sm text-text-2">{company.sector} · {company.location ?? countryName(company.country)}</p>
          </div>
        </div>
        <div className="space-y-3 text-[13px] leading-relaxed text-text-2"><CompanyFacts company={company} /></div>
        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-text-2">
          <SourceLink url={company.source_url}>Company source</SourceLink>
          <span>Verified {dateLabel(company.verified_at, "time")}</span>
        </div>
        {owner ? <FollowCompany key={`${owner}:${company.id}`} owner={owner} company={company} showUpdates={showUpdates} />
          : signedOut && <ButtonLink size="sm"
            href={`/login?next=${encodeURIComponent(`/private-markets?view=explorer&company=${company.id}`)}`}>Sign in to follow</ButtonLink>}
      </Card>
      <CompareSelection {...actions} />
      <h2 className="text-base font-semibold text-text">Funding history</h2>
      <RoundCards deals={history} actions={actions} />
    </div>;
  }

  return <div className="space-y-4">
    <Card>
      <CardHeader title="Startup Explorer" />
      <div ref={search} className="border-t border-border p-4">
        <Field label="Find a company" htmlFor="private-company-filter">
          <Input id="private-company-filter" type="search" value={query} onChange={(event) => setQuery(event.target.value)} />
        </Field>
      </div>
      <ul className="divide-y divide-border">
        {matches.map((entry) => <li key={entry.id}>
          <button className="flex w-full items-center gap-3 px-4 py-3 text-left hover:bg-surface-2 focus-visible:bg-surface-2"
            type="button" onClick={() => setCompany(entry.id)}>
            <CompanyLogo url={entry.logo_url} />
            <span className="min-w-0">
              <span className="block break-words text-sm font-medium text-text">{entry.name}</span>
              <span className="block text-xs text-text-2">{entry.sector} · {entry.location ?? countryName(entry.country)}</span>
            </span>
          </button>
        </li>)}
      </ul>
      {matches.length === 0 && <EmptyState icon={<Building2 className="size-5" aria-hidden />} title="No matching companies" />}
    </Card>
  </div>;
}

export function FundingRounds({ deals, actions, onCompany }: {
  deals: PrivateDeal[]; actions: RoundActions; onCompany: (id: string) => void;
}) {
  const { asOf } = actions;
  const rounds = distinctRounds(deals, asOf);
  const listings = rounds.flatMap((deal) => deal.round.listing ? [{ deal, listing: deal.round.listing }] : []);
  listings.sort((a, b) => {
    const aUpcoming = hasUpcomingQuotation(a.listing, asOf);
    const bUpcoming = hasUpcomingQuotation(b.listing, asOf);
    if (aUpcoming !== bUpcoming) return aUpcoming ? -1 : 1;
    const order = (a.listing.quotation_on ?? "").localeCompare(b.listing.quotation_on ?? "");
    return (aUpcoming ? order : -order) || newestFirst(a.deal, b.deal);
  });
  const funding = rounds.filter(({ round }) => !round.listing);
  const current = funding.filter((deal) => {
    const status = availability(deal, asOf);
    return status === "open" || status === "interest";
  }).sort(byDeadline);
  const currentIDs = new Set(current.map(({ id }) => id));
  const other = funding.filter(({ id }) => !currentIDs.has(id)).sort(newestFirst);
  const sections = [
    { title: "Verified opportunities and expressions of interest", deals: current },
    { title: "IPO milestones", deals: listings.map(({ deal }) => deal) },
    { title: "Historical and unverified rounds", deals: other },
  ];

  return <div className="space-y-5">
    <CompareSelection {...actions} />
    {current.length === 0 && <p className="text-sm text-text-2">No verified open rounds or current expressions of interest.</p>}
    {sections.filter((section) => section.deals.length).map((section) => <section key={section.title} className="space-y-3">
      <h2 className="text-base font-semibold text-text">{section.title}</h2>
      <RoundCards deals={section.deals} actions={actions} onCompany={onCompany} />
    </section>)}
  </div>;
}
