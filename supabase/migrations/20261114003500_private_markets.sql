-- Curated, permissioned publication only. Provider pages are linked from the app.
create table public.private_companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 180),
  sector text not null,
  country text not null check (country ~ '^[A-Z]{2}$'),
  location text,
  description text,
  logo_url text,
  founders text[],
  investors text[],
  source_url text not null check (source_url like 'https://%'),
  verified_at timestamptz not null,
  published boolean not null default false
);

create table public.funding_rounds (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.private_companies(id),
  stage text not null,
  raised numeric(20,4) check (raised >= 0),
  target numeric(20,4) check (target > 0),
  valuation numeric(20,4) check (valuation > 0),
  valuation_method text,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  closes_at timestamptz,
  source_url text not null check (source_url like 'https://%'),
  verified_at timestamptz not null,
  traction text,
  published boolean not null default false
);

create table public.share_classes (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.funding_rounds(id),
  name text not null,
  rights text not null,
  source_url text not null check (source_url like 'https://%'),
  published boolean not null default false
);

create table public.investment_opportunities (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.funding_rounds(id),
  provider text not null check (provider in ('birchal', 'onmarket', 'angellist', 'syndex')),
  category text not null check (category in ('Crowdfunding','Seed or angel','Series A','Series B or later',
    'Private equity','Venture fund','Syndicate or SPV','Pre-IPO','Private secondary')),
  status text not null check (status in ('open','interest','closed','unverified')),
  minimum numeric(20,4) check (minimum > 0),
  eligibility text not null check (eligibility in ('retail','wholesale','provider review')),
  jurisdictions text[] not null,
  source_url text not null check (source_url like 'https://%'),
  handoff_url text,
  offer_document_url text,
  verified_at timestamptz not null,
  published boolean not null default false,
  unique (provider, source_url)
);

create table public.private_market_rules (
  jurisdiction text not null,
  version text not null,
  effective_at timestamptz not null,
  reviewed_at timestamptz,
  source_url text not null,
  retail_csf_cap numeric(20,4),
  cooling_off_business_days integer,
  handoff_enabled boolean not null default false,
  primary key (jurisdiction, version),
  check (not handoff_enabled or reviewed_at is not null)
);
insert into public.private_market_rules values (
  'AU', 'AU-CSF-2026-11', '2026-11-14 00:00:00+11', null,
  'https://www.asic.gov.au/crowd-sourced-funding', 10000, 5, false
);

create table public.private_provider_approvals (
  provider text not null,
  jurisdiction text not null,
  rule_version text not null,
  agreement_reference text not null check (length(trim(agreement_reference)) > 0),
  expires_at timestamptz not null,
  enabled boolean not null default false,
  primary key (provider, jurisdiction),
  foreign key (jurisdiction, rule_version) references public.private_market_rules(jurisdiction, version)
);

create table public.investor_profiles (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  country text not null check (country ~ '^[A-Z]{2}$'),
  declared_class text not null check (declared_class in ('retail','wholesale','unknown'))
);
create table public.provider_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider in ('birchal', 'onmarket', 'angellist', 'syndex')),
  external_subject text not null check (length(trim(external_subject)) > 0),
  revoked_at timestamptz,
  unique (provider, external_subject),
  unique (user_id, provider),
  unique (id, user_id, provider)
);
create table public.investor_eligibility (
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  connection_id uuid not null,
  jurisdiction text not null,
  verified_class text not null check (verified_class in ('retail','wholesale')),
  verified_at timestamptz not null,
  expires_at timestamptz not null check (expires_at > verified_at),
  evidence_reference text not null check (length(trim(evidence_reference)) > 0),
  accountant_certificate_reviewed_at timestamptz,
  primary key (user_id, provider, jurisdiction),
  foreign key (connection_id, user_id, provider) references public.provider_connections(id, user_id, provider)
    on delete cascade
);

create table public.investment_commitments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  opportunity_id uuid not null references public.investment_opportunities(id),
  provider text not null,
  jurisdiction text not null,
  rule_version text not null,
  reviewed_document_url text not null,
  requested_amount numeric(20,4) not null check (requested_amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  acknowledged_at timestamptz not null default now(),
  status text not null default 'handoff' check (status in
    ('handoff','application_received','confirmed','withdrawn','rejected')),
  provider_reference text,
  cooling_off_ends_at timestamptz,
  confirmed_at timestamptz,
  provider_event_at timestamptz,
  check (status = 'handoff' or nullif(trim(provider_reference), '') is not null),
  check ((status = 'confirmed') = (confirmed_at is not null)),
  foreign key (jurisdiction, rule_version) references public.private_market_rules(jurisdiction, version),
  unique (provider, provider_reference)
);
create unique index private_one_active_commitment
  on public.investment_commitments (user_id, opportunity_id)
  where status in ('handoff','application_received','confirmed');

-- Manual device records use Swift data protection. These tables are for authenticated
-- partner ingestion, with tenant-checked foreign keys for every private child.
create table public.private_holdings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  company_id uuid references public.private_companies(id),
  commitment_id uuid unique,
  name text not null,
  asset_class text not null,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  committed_amount numeric(20,4) check (committed_amount >= 0),
  units numeric(25,8) check (units > 0),
  ownership_percent numeric(13,10) check (ownership_percent between 0 and 100),
  settled_amount numeric(20,4) check (settled_amount > 0),
  confirmed_at timestamptz,
  unique (id, user_id)
);
alter table public.investment_commitments add unique (id, user_id);
alter table public.private_holdings add constraint holding_commitment_owner
  foreign key (commitment_id, user_id) references public.investment_commitments(id, user_id);

create table public.valuation_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  holding_id uuid not null,
  value numeric(20,4) not null check (value >= 0),
  valued_on date not null,
  source text not null,
  methodology text not null,
  foreign key (holding_id, user_id) references public.private_holdings(id, user_id) on delete cascade
);
create table public.capital_calls (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  holding_id uuid not null,
  amount numeric(20,4) not null check (amount > 0),
  due_on date not null,
  settled_on date,
  source text not null,
  foreign key (holding_id, user_id) references public.private_holdings(id, user_id) on delete cascade
);
create table public.distributions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  holding_id uuid not null,
  amount numeric(20,4) not null check (amount > 0),
  received_on date not null,
  source text not null,
  foreign key (holding_id, user_id) references public.private_holdings(id, user_id) on delete cascade
);
create table public.corporate_actions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.private_companies(id),
  title text not null,
  significance text not null,
  published_at timestamptz not null,
  source_url text not null check (source_url like 'https://%'),
  published boolean not null default false,
  unique (company_id, source_url, published_at)
);

create table public.deal_documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (length(title) between 1 and 160),
  sealed jsonb not null,
  created_at timestamptz not null default now()
);
create table public.research_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  sealed jsonb not null,
  created_at timestamptz not null default now()
);
create table public.agent_analysis_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  report_id uuid references public.research_reports(id) on delete set null,
  status text not null check (status in ('running','complete','failed')),
  created_at timestamptz not null default now()
);
create table public.investment_audit_logs (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  subject_id uuid,
  created_at timestamptz not null default now()
);

do $$
declare
  relation text;
begin
  foreach relation in array array['private_companies','funding_rounds','share_classes',
    'investment_opportunities','corporate_actions','private_market_rules','private_provider_approvals',
    'investor_profiles','provider_connections','investor_eligibility','investment_commitments',
    'private_holdings','valuation_history','capital_calls','distributions','deal_documents',
    'research_reports','agent_analysis_runs','investment_audit_logs']
  loop
    execute format('alter table public.%I enable row level security', relation);
    execute format('revoke all on table public.%I from public, anon, authenticated, service_role', relation);
    execute format('grant select, insert, update, delete on table public.%I to service_role', relation);
  end loop;
  foreach relation in array array['provider_connections','investor_eligibility','investment_commitments',
    'private_holdings','valuation_history','capital_calls','distributions','agent_analysis_runs','investment_audit_logs']
  loop
    execute format('grant select on public.%I to authenticated', relation);
    execute format('create policy owner_read on public.%I for select to authenticated using ((select auth.uid()) = user_id)', relation);
    execute format('create index on public.%I (user_id)', relation);
  end loop;
  foreach relation in array array['deal_documents','research_reports']
  loop
    execute format('create index on public.%I (user_id, created_at desc)', relation);
  end loop;
end $$;

grant select, insert, update on public.investor_profiles to authenticated;
create policy own_profile on public.investor_profiles for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

grant select on public.private_companies, public.funding_rounds, public.share_classes,
  public.investment_opportunities, public.corporate_actions to anon, authenticated;
revoke select on public.investment_opportunities from anon, authenticated;
grant select (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,
  offer_document_url,verified_at,published) on public.investment_opportunities to anon, authenticated;

create policy published_company on public.private_companies for select using (published);
create policy published_round on public.funding_rounds for select using
  (published and exists (select 1 from public.private_companies where id = company_id and published));
create policy published_share_class on public.share_classes for select using
  (published and exists (select 1 from public.funding_rounds where id = round_id and published));
create policy published_opportunity on public.investment_opportunities for select using
  (published and exists (select 1 from public.funding_rounds where id = round_id and published));
create policy published_action on public.corporate_actions for select using
  (published and exists (select 1 from public.private_companies where id = company_id and published));

revoke update, delete on public.investment_audit_logs from service_role;

-- The caller is the authenticated edge function. This RPC creates a local intent
-- atomically. It cannot send an application or mark one as received or confirmed.
create function public.prepare_private_handoff(
  p_user uuid, p_opportunity uuid, p_amount numeric, p_document_url text
) returns table (commitment_id uuid, handoff_url text)
language plpgsql set search_path = '' as $$
declare
  deal public.investment_opportunities%rowtype;
  round public.funding_rounds%rowtype;
  rules public.private_market_rules%rowtype;
  profile public.investor_profiles%rowtype;
  verification public.investor_eligibility%rowtype;
  prior public.investment_commitments%rowtype;
  host_pattern text;
begin
  if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or
     p_amount <= 0 or p_amount > 9999999999999999 or scale(p_amount) > 4 then
    raise exception 'Invalid investment amount' using errcode = '22023';
  end if;
  select * into deal from public.investment_opportunities where id = p_opportunity and published;
  select * into round from public.funding_rounds where id = deal.round_id and published;
  if not found or not exists (select 1 from public.private_companies where id = round.company_id and published)
     or deal.status <> 'open' or round.closes_at is null or round.closes_at <= now()
     or deal.verified_at < now() - interval '24 hours' or deal.verified_at > now()
     or round.verified_at < now() - interval '24 hours' or round.verified_at > now()
     or deal.minimum is null or p_amount < deal.minimum then
    raise exception 'Offer availability or minimum could not be verified' using errcode = '22023';
  end if;
  select * into profile from public.investor_profiles where user_id = p_user;
  if not found or profile.country <> 'AU' or not (profile.country = any(deal.jurisdictions)) then
    raise exception 'This offer requires an eligible Australian investor profile' using errcode = '42501';
  end if;
  select * into rules from public.private_market_rules where jurisdiction = profile.country and effective_at <= now()
    order by effective_at desc, version desc limit 1;
  if not found or not rules.handoff_enabled or rules.reviewed_at > now() or not exists (
    select 1 from public.private_provider_approvals
    where provider = deal.provider and jurisdiction = profile.country and rule_version = rules.version
      and enabled and expires_at > now()
  ) then
    raise exception 'Provider handoff is awaiting approval' using errcode = '42501';
  end if;
  select e.* into verification from public.investor_eligibility e
    join public.provider_connections c on c.id = e.connection_id and c.revoked_at is null
    where e.user_id = p_user and e.provider = deal.provider and e.jurisdiction = profile.country
      and e.verified_at <= now() and e.expires_at > now();
  if not found or deal.eligibility = 'provider review' or
     (deal.eligibility = 'wholesale' and verification.verified_class <> 'wholesale') then
    raise exception 'The provider must verify eligibility for this offer' using errcode = '42501';
  end if;
  host_pattern := case deal.provider
    when 'birchal' then '^https://(www\.)?birchal\.com/'
    when 'onmarket' then '^https://(www\.|crowd\.)?onmarket\.com\.au/'
    else null end;
  if host_pattern is null or deal.handoff_url is null or deal.handoff_url !~ host_pattern
     or deal.offer_document_url is null or deal.offer_document_url is distinct from p_document_url then
    raise exception 'The offer document or approved provider link is unavailable' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text || deal.provider || round.company_id::text, 0));
  select * into prior from public.investment_commitments where user_id = p_user and opportunity_id = p_opportunity
    and status in ('handoff','application_received','confirmed');
  if found then
    if prior.status = 'handoff' and prior.requested_amount = p_amount and prior.rule_version = rules.version
       and prior.reviewed_document_url = p_document_url then
      return query select prior.id, deal.handoff_url;
      return;
    end if;
    raise exception 'An active application record already exists' using errcode = '23505';
  end if;

  if verification.verified_class = 'retail' and deal.category = 'Crowdfunding' and
     (round.currency <> 'AUD' or rules.retail_csf_cap is null or
      p_amount + coalesce((select sum(c.requested_amount) from public.investment_commitments c
        join public.investment_opportunities o on o.id = c.opportunity_id
        join public.funding_rounds r on r.id = o.round_id
        where c.user_id = p_user and c.provider = deal.provider and r.company_id = round.company_id
          and o.category = 'Crowdfunding' and c.currency = 'AUD'
          and c.status in ('application_received','confirmed') and c.acknowledged_at > now() - interval '12 months'), 0)
      > rules.retail_csf_cap) then
    raise exception 'Recorded applications would exceed the Australian retail CSF cap' using errcode = '22023';
  end if;

  insert into public.investment_commitments (user_id, opportunity_id, provider, jurisdiction, rule_version,
    reviewed_document_url, requested_amount, currency)
  values (p_user, p_opportunity, deal.provider, profile.country, rules.version, p_document_url, p_amount, round.currency)
  returning id into commitment_id;
  insert into public.investment_audit_logs (user_id, action, subject_id) values (p_user, 'provider_handoff', commitment_id);
  handoff_url := deal.handoff_url;
  return next;
end $$;
revoke all on function public.prepare_private_handoff(uuid,uuid,numeric,text) from public, anon, authenticated;
grant execute on function public.prepare_private_handoff(uuid,uuid,numeric,text) to service_role;

create function public.finish_private_research(p_user uuid, p_run uuid, p_title text, p_sealed jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  perform 1 from public.agent_analysis_runs where user_id = p_user and id = p_run and status = 'running' for update;
  if not found then raise exception 'Research run unavailable' using errcode = '22023'; end if;
  insert into public.research_reports (id, user_id, title, sealed) values (p_run, p_user, p_title, p_sealed);
  update public.agent_analysis_runs set status = 'complete', report_id = p_run where id = p_run and user_id = p_user;
  insert into public.investment_audit_logs (user_id, action, subject_id) values (p_user, 'research_complete', p_run);
end $$;
revoke all on function public.finish_private_research(uuid,uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.finish_private_research(uuid,uuid,text,jsonb) to service_role;

-- Internal boundary for a future approved provider adapter. There is no public
-- webhook and no assumption about any provider's delivery or signature protocol.
create function public.record_private_provider_event(
  p_provider text, p_subject text, p_commitment uuid, p_reference text, p_status text,
  p_provider_event_at timestamptz, p_cooling_off_ends_at timestamptz default null,
  p_units numeric default null, p_invested_amount numeric default null
) returns void language plpgsql set search_path = '' as $$
declare
  entry public.investment_commitments%rowtype;
  listing public.investment_opportunities%rowtype;
  issuer public.private_companies%rowtype;
begin
  if p_status is null or p_status not in ('application_received','confirmed','withdrawn','rejected') or
     nullif(trim(p_reference), '') is null or length(p_reference) > 200 or
     p_provider_event_at is null or p_provider_event_at > now() then
    raise exception 'Invalid provider event' using errcode = '22023';
  end if;
  select c.* into entry from public.investment_commitments c
    join public.provider_connections pc on pc.user_id = c.user_id and pc.provider = c.provider and pc.revoked_at is null
    where c.id = p_commitment and c.provider = p_provider and pc.external_subject = p_subject
    for update of c;
  if not found or not exists (
    select 1 from public.private_provider_approvals a join public.private_market_rules r
      on r.jurisdiction = a.jurisdiction and r.version = a.rule_version
    where a.provider = entry.provider and a.jurisdiction = entry.jurisdiction and a.rule_version = entry.rule_version
      and a.enabled and a.expires_at > now() and r.handoff_enabled and r.reviewed_at <= now()
  ) then
    raise exception 'Provider event unavailable for this application' using errcode = '42501';
  end if;
  if entry.provider_reference is not null and entry.provider_reference <> p_reference then
    raise exception 'Provider reference conflicts with the recorded application' using errcode = '23505';
  end if;
  if entry.provider_event_at is not null and entry.provider_event_at >= p_provider_event_at then return; end if;
  if entry.status in ('confirmed','withdrawn','rejected') or
     (entry.status = 'handoff' and p_status = 'confirmed') then
    raise exception 'Unsupported application transition' using errcode = '22023';
  end if;
  if p_status = 'confirmed' and
     (p_units is null or p_units <= 0 or p_units::text in ('NaN','Infinity','-Infinity') or
      p_invested_amount is null or p_invested_amount <= 0 or p_invested_amount::text in ('NaN','Infinity','-Infinity')) then
    raise exception 'Confirmation requires provider-issued units and settled capital' using errcode = '22023';
  end if;
  update public.investment_commitments set status = p_status, provider_reference = p_reference,
    provider_event_at = p_provider_event_at,
    cooling_off_ends_at = coalesce(p_cooling_off_ends_at, cooling_off_ends_at),
    confirmed_at = case when p_status = 'confirmed' then p_provider_event_at else null end
    where id = entry.id;
  if p_status = 'confirmed' then
    select * into listing from public.investment_opportunities where id = entry.opportunity_id;
    select c.* into issuer from public.private_companies c join public.funding_rounds r on r.company_id = c.id
      where r.id = listing.round_id;
    insert into public.private_holdings (user_id, company_id, commitment_id, name, asset_class, currency, units,
      settled_amount, confirmed_at)
    values (entry.user_id, issuer.id, entry.id, issuer.name, case listing.category
      when 'Venture fund' then 'Venture fund' when 'Private equity' then 'Private equity'
      when 'Syndicate or SPV' then 'Syndicate or SPV' when 'Private secondary' then 'Private secondary'
      else 'Startup equity' end, entry.currency, p_units, p_invested_amount, p_provider_event_at);
  end if;
  insert into public.investment_audit_logs (user_id, action, subject_id)
  values (entry.user_id, 'provider_' || p_status, entry.id);
end $$;
revoke all on function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric)
  from public, anon, authenticated;
grant execute on function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric)
  to service_role;
