import { ArrowUpRight, ChevronDown } from "lucide-react";
import type { ReactNode } from "react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import {
  amount, availability, availabilityLabels, countryName, dateLabel, providerName, sourceHref, todayInSydney,
  type Criteria, type FinancialPeriod, type PrivateDeal,
} from "./private-data";

export function SourceLink({ url, children }: { url?: string | null; children: ReactNode }) {
  const href = sourceHref(url);
  return href ? (
    <a className="inline-flex max-w-full items-baseline gap-1 text-primary-fg underline-offset-4 hover:underline"
      href={href} target="_blank" rel="noopener noreferrer">
      <span className="min-w-0 break-words">{children}</span>
      <ArrowUpRight className="h-3.5 w-3.5 shrink-0 self-center" aria-hidden />
    </a>
  ) : <span>{children}</span>;
}

const eligibilityLabels: Record<string, string> = {
  retail: "Retail", wholesale: "Wholesale", "provider review": "Provider review",
};

const quotationLabels = {
  proposed: "Proposed first quotation", anticipated: "Anticipated first quotation",
  listed: "First quotation confirmed", withdrawn: "Listing application withdrawn",
};

function FinancialDisclosure({ period }: { period: FinancialPeriod }) {
  const facts = [
    ["Revenue", period.revenue], ["Annual recurring revenue", period.annual_recurring_revenue],
    ["Net profit or loss", period.net_profit_loss], ["Net operating cash flow", period.operating_cash_flow],
    ["Cash and cash equivalents", period.cash_and_equivalents],
  ] as const;
  return (
    <li className="rounded-lg border border-border bg-surface-2 px-3 py-2.5">
      <p className="font-medium text-text">{period.assurance === "audited" ? "Audited financial statements" : "Issuer-reported figures"}</p>
      <p className="text-xs text-text-3">{period.period_kind === "financial_year"
        ? `Year ended ${dateLabel(period.period_end_on)}`
        : dateLabel(period.period_end_on, "month")} · Published {dateLabel(period.published_on)}</p>
      <dl className="mt-2 space-y-1">
        {facts.filter(([, value]) => value !== null).map(([label, value]) => (
          <div key={label} className="flex flex-wrap justify-between gap-x-3">
            <dt>{label}</dt><dd className="font-medium tabular-nums text-text">{amount(value, period.currency)}</dd>
          </div>
        ))}
      </dl>
      <p className="mt-2"><SourceLink url={period.source_url}>Financial disclosure</SourceLink></p>
    </li>
  );
}

function listingStatus(listing: NonNullable<PrivateDeal["round"]["listing"]>) {
  const awaiting = listing.quotation_status === "proposed" || listing.quotation_status === "anticipated";
  return awaiting && (!listing.quotation_on || listing.quotation_on < todayInSydney())
    ? "Quotation confirmation pending" : quotationLabels[listing.quotation_status];
}

function roundFigures(deal: PrivateDeal): [string, number | null][] {
  return [
    ["Raise target", deal.round.target], ["Reported raised", deal.round.raised],
    ["Valuation", deal.round.valuation], ["Minimum investment", deal.minimum],
  ];
}

export function CompareRounds({ deals }: { deals: PrivateDeal[] }) {
  return <div className="grid gap-2 md:grid-cols-3">
    {deals.map((deal) => <div key={deal.id} className="rounded-lg border border-border bg-surface-2 p-3 text-sm">
      <p className="font-medium text-text">{deal.round.company.name}</p>
      <p className="text-xs text-text-3">{deal.round.stage} · {availabilityLabels[availability(deal)]}</p>
      <dl className="my-2 space-y-1">
        {roundFigures(deal).map(([label, value]) => <div key={label} className="flex flex-wrap justify-between gap-x-2">
          <dt className="text-xs text-text-2">{label}</dt><dd className="text-xs font-medium text-text">{amount(value, deal.round.currency)}</dd>
        </div>)}
      </dl>
      {deal.round.valuation_method && <p className="mb-2 text-xs text-text-2">{deal.round.valuation_method}</p>}
      <SourceLink url={deal.source_url}>Round disclosure</SourceLink>
    </div>)}
  </div>;
}

export function DealCard({ deal, selected, selectionFull, onSelect }: {
  deal: PrivateDeal; selected: boolean; selectionFull: boolean; onSelect: () => void;
}) {
  const { round } = deal;
  const { company, listing } = round;
  const status = availability(deal);
  const eligibility = eligibilityLabels[deal.eligibility] ?? deal.eligibility;
  const hasTeam = !!company.founders?.length || !!company.investors?.length;
  return (
    <Card as="article" className="min-w-0">
      <div className="p-4 md:p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="text-xs font-medium text-text-3">{deal.category}</p>
            <h2 className="mt-0.5 break-words text-lg font-semibold tracking-tight text-text">{company.name}</h2>
            <p className="mt-0.5 text-sm text-text-2">{round.stage} · {company.sector} · {company.location ?? countryName(company.country)}</p>
          </div>
          <Badge tone={status === "open" ? "up" : status === "interest" ? "primary" : status === "unverified" ? "warn" : "neutral"}>
            {availabilityLabels[status]}
          </Badge>
        </div>
        <dl className="mt-4 grid grid-cols-2 gap-3 rounded-lg border border-border bg-surface-2 p-3 text-sm sm:grid-cols-4">
          {roundFigures(deal).map(([label, value]) => (
            <div key={label}>
              <dt className="text-xs text-text-3">{label}</dt>
              <dd className="mt-0.5 break-words font-medium tabular-nums text-text">{amount(value, round.currency)}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-3 flex flex-wrap gap-x-2 gap-y-1 text-xs text-text-2">
          <span>{eligibility} eligibility</span>
          <span aria-hidden>·</span>
          <span>{round.closes_at ? `Published deadline ${dateLabel(round.closes_at, "time")}` :
            round.announced_on ? `Announced ${dateLabel(round.announced_on)}` : "Deadline undisclosed"}</span>
          <span aria-hidden>·</span>
          <span>Verified {dateLabel(deal.verified_at, "time")}</span>
        </p>
      </div>
      <details className="group border-t border-border px-4 md:px-5">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-2 py-3 text-[13px] font-medium text-text hover:text-primary-fg [&::-webkit-details-marker]:hidden">
          Terms and disclosures<span className="sr-only"> for {company.name} {round.stage}</span>
          <ChevronDown className="h-4 w-4 shrink-0 group-open:rotate-180" aria-hidden />
        </summary>
        <div className="space-y-3 pb-4 text-[13px] leading-relaxed text-text-2">
          {company.description && <p>{company.description}</p>}
          <p>Investor jurisdictions {deal.jurisdictions.length ? deal.jurisdictions.map(countryName).join(", ") : "undisclosed"}</p>
          {round.valuation_method && <p>{round.valuation_method}</p>}
          {round.traction && <p>{round.traction}</p>}
          {hasTeam && <dl className="space-y-2">
            {!!company.founders?.length && <div><dt className="font-medium text-text">Founders</dt><dd>{company.founders.join(", ")}</dd></div>}
            {!!company.investors?.length && <div><dt className="font-medium text-text">Disclosed investors</dt><dd>{company.investors.join(", ")}</dd></div>}
          </dl>}
          {round.share_classes.length > 0 && <div>
            <h3 className="font-medium text-text">Share classes and rights</h3>
            <ul className="mt-1 space-y-1">{round.share_classes.map((share) => (
              <li key={share.name}><SourceLink url={share.source_url}>{share.name}</SourceLink> · {share.rights}</li>
            ))}</ul>
          </div>}
          {listing && <div>
            <h3 className="font-medium text-text">{listingStatus(listing)}</h3>
            <p>{listing.exchange} {listing.symbol}{listing.quotation_on ? ` · ${dateLabel(listing.quotation_on)}` : ""}</p>
            {listing.expected_offer_close_on && <p>Expected offer close {dateLabel(listing.expected_offer_close_on)}</p>}
            <SourceLink url={listing.source_url}>Listing disclosure</SourceLink>
          </div>}
          {company.financials.length > 0 && <div>
            <h3 className="font-medium text-text">Published financials</h3>
            <ul className="mt-2 grid gap-2 md:grid-cols-2">{company.financials.map((period) => (
              <FinancialDisclosure key={period.id} period={period} />
            ))}</ul>
          </div>}
        </div>
      </details>
      <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border px-4 py-3 text-[13px] md:px-5">
        <div className="flex flex-wrap gap-x-4 gap-y-1">
          <SourceLink url={deal.source_url}>{providerName(deal.provider)}</SourceLink>
          {deal.offer_document_url && <SourceLink url={deal.offer_document_url}>Offer document</SourceLink>}
        </div>
        <Button size="sm" aria-pressed={selected} aria-label={`Select ${company.name} ${round.stage} for research`}
          disabled={!selected && selectionFull} onClick={onSelect}>
          {selected ? "Selected" : "Select for research"}
        </Button>
      </div>
    </Card>
  );
}

export function interpretedFilters(criteria: Criteria) {
  const fields: [string, string | string[]][] = [
    ["Company", criteria.company], ["Company country", criteria.countries.map(countryName)],
    ["Investor jurisdiction", criteria.investor_jurisdictions.map(countryName)],
    ["Sector", criteria.sectors], ["Stage", criteria.stages], ["Category", criteria.categories],
    ["Availability", criteria.statuses.map((status) => availabilityLabels[status as keyof typeof availabilityLabels] ?? status)],
    ["Eligibility", criteria.eligibility.map((key) => eligibilityLabels[key] ?? key)], ["Provider", criteria.providers.map(providerName)],
    ["Maximum minimum investment", criteria.max_minimum ? amount(criteria.max_minimum, criteria.currency) : ""],
    ["Maximum valuation", criteria.max_valuation ? amount(criteria.max_valuation, criteria.currency) : ""],
    ["Minimum raise target", criteria.min_raise_target ? amount(criteria.min_raise_target, criteria.currency) : ""],
    ["Maximum raise target", criteria.max_raise_target ? amount(criteria.max_raise_target, criteria.currency) : ""],
    ["Disclosed traction", criteria.disclosed_traction ? "Required" : ""],
  ];
  return fields.flatMap(([label, value]) => value.length ? [{ label, value: typeof value === "string" ? value : value.join(", ") }] : []);
}
