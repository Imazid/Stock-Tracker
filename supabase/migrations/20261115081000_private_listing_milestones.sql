-- Exchange and issuer milestones are independent of provider availability and application deadlines.
create table public.private_listing_milestones (
  round_id uuid primary key references public.funding_rounds(id) on delete cascade,
  exchange text not null check (exchange ~ '^[A-Z0-9]{2,12}$'),
  symbol text not null check (symbol ~ '^[A-Z0-9][A-Z0-9.-]{0,14}$'),
  quotation_status text not null check (quotation_status in ('proposed', 'anticipated', 'listed', 'withdrawn')),
  expected_offer_close_on date,
  quotation_on date,
  source_url text not null check (source_url like 'https://%'),
  verified_at timestamptz not null,
  published boolean not null default false,
  check ((quotation_status = 'withdrawn') = (quotation_on is null)),
  check (quotation_status <> 'listed' or quotation_on <= (verified_at at time zone 'Australia/Sydney')::date)
);
alter table public.private_listing_milestones enable row level security;
revoke all on public.private_listing_milestones from public, anon, authenticated;
grant select on public.private_listing_milestones to anon, authenticated;
grant select, insert, update, delete on public.private_listing_milestones to service_role;
create policy published_private_listing_milestone on public.private_listing_milestones
  for select to anon, authenticated using (
    published and verified_at <= now()
    and exists (select 1 from public.funding_rounds where id = round_id and published)
  );

-- Curated factual records from ASX and issuer disclosures. No transaction routes.
insert into public.private_companies
  (id, name, sector, country, location, description, founders, source_url, verified_at, published)
values
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f101', 'ABC Commodities Limited', 'Mining', 'AU', 'New South Wales',
   'Explores critical mineral deposits in New South Wales.', null,
   'https://www.abccom.com.au/', '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f102', 'Capability X Limited', 'Industrial technology', 'AU', 'Western Australia',
   'Develops hardware and software for safety in industrial operations.', array['Chris Eastwell'],
   'https://www.capabilityx.com/asx-announcements', '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f103', 'Matrix Critical Minerals Limited', 'Mining', 'AU', 'Western Australia',
   'Explores rare-earth mineral resources.', null,
   'https://www.asx.com.au/listings/upcoming-floats-and-listings.', '2026-11-14 13:00:00+11', true);

insert into public.funding_rounds
  (id, company_id, stage, raised, target, currency, announced_on, source_url, verified_at, published)
values
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f201', 'a581f4af-a8d0-41fd-a9be-0e4e1607f101', 'Proposed IPO', null, 5000000, 'AUD',
   '2026-10-23', 'https://www.abccom.com.au/investors/asx-prospectus/', '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f202', 'a581f4af-a8d0-41fd-a9be-0e4e1607f102', 'Completed IPO', 12000000, null, 'AUD',
   '2026-11-12', 'https://cdn-api.markitdigital.com/apiman-gateway/ASX/asx-research/1.0/file/2924-03160924-6A1354733',
   '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f203', 'a581f4af-a8d0-41fd-a9be-0e4e1607f103', 'IPO listing application', null, null, 'AUD',
   null, 'https://www.asx.com.au/listings/upcoming-floats-and-listings.', '2026-11-14 13:00:00+11', true);

insert into public.investment_opportunities
  (id, round_id, provider, category, status, eligibility, jurisdictions, source_url, verified_at, published)
values
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f301', 'a581f4af-a8d0-41fd-a9be-0e4e1607f201', 'issuer', 'Pre-IPO', 'unverified',
   'provider review', '{}', 'https://www.abccom.com.au/investors/asx-prospectus/', '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f302', 'a581f4af-a8d0-41fd-a9be-0e4e1607f202', 'issuer', 'Pre-IPO', 'closed',
   'provider review', '{}', 'https://cdn-api.markitdigital.com/apiman-gateway/ASX/asx-research/1.0/file/2924-03160924-6A1354733',
   '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f303', 'a581f4af-a8d0-41fd-a9be-0e4e1607f203', 'issuer', 'Pre-IPO', 'unverified',
   'provider review', '{}', 'https://mtxcm.com.au/', '2026-11-14 13:00:00+11', true);

insert into public.private_listing_milestones
  (round_id, exchange, symbol, quotation_status, expected_offer_close_on, quotation_on, source_url, verified_at, published)
values
  ('eb84aafc-f0b1-46a4-9f40-cc6d16447702', 'ASX', 'ATW', 'proposed', '2026-11-16', '2026-11-26',
   'https://www.asx.com.au/listings/upcoming-floats-and-listings.', '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f201', 'ASX', 'ABC', 'anticipated', '2026-11-20', '2026-11-30',
   'https://www.asx.com.au/listings/upcoming-floats-and-listings.', '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f202', 'ASX', 'CX8', 'listed', null, '2026-11-12',
   'https://cdn-api.markitdigital.com/apiman-gateway/ASX/asx-research/1.0/file/2924-03160924-6A1354733',
   '2026-11-14 13:00:00+11', true),
  ('a581f4af-a8d0-41fd-a9be-0e4e1607f203', 'ASX', 'MTX', 'withdrawn', null, null,
   'https://www.asx.com.au/listings/upcoming-floats-and-listings.', '2026-11-14 13:00:00+11', true);

-- A completed listing is a company update. Expected dates stay in the catalogue.
insert into public.corporate_actions (company_id, title, significance, published_at, source_url, published)
values (
  'a581f4af-a8d0-41fd-a9be-0e4e1607f102', 'Capability X began trading on ASX',
  'Capability X confirmed that trading began under CX8 on 12 November 2026 after it completed its A$12 million IPO.',
  '2026-11-12 09:49:00+11',
  'https://cdn-api.markitdigital.com/apiman-gateway/ASX/asx-research/1.0/file/2924-03160924-6A1354733', true
);
