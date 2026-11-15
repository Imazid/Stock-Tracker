-- Only trusted provider events can move applications through withdrawal or
-- settlement. A handoff remains an intent until the provider acknowledges it.
alter table public.investment_commitments
  add column provider_connection_id uuid,
  add column provider_received_at timestamptz,
  add column withdrawal_requested_at timestamptz,
  add column withdrawal_declined_at timestamptz,
  add column withdrawn_at timestamptz,
  add constraint private_commitment_provider_connection
    foreign key (provider_connection_id, user_id, provider)
    references public.provider_connections(id, user_id, provider) deferrable initially deferred,
  drop constraint investment_commitments_status_check,
  add constraint investment_commitments_status_check check (status in
    ('handoff','application_received','withdrawal_requested','confirmed','withdrawn','rejected'));

update public.investment_commitments set provider_received_at = provider_event_at where status = 'application_received';
update public.investment_commitments set withdrawn_at = provider_event_at where status = 'withdrawn';

drop index public.private_one_active_commitment;
create unique index private_one_active_commitment on public.investment_commitments (user_id, opportunity_id)
  where status in ('handoff','application_received','withdrawal_requested','confirmed');

create or replace function public.prepare_private_handoff(
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
    and status in ('handoff','application_received','withdrawal_requested','confirmed');
  if found then
    if prior.status = 'handoff' and prior.requested_amount = p_amount and prior.rule_version = rules.version
       and prior.reviewed_document_url = p_document_url
       and (prior.provider_connection_id is null or prior.provider_connection_id = verification.connection_id) then
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
          and c.status in ('application_received','withdrawal_requested','confirmed')
          and coalesce(c.provider_received_at, c.acknowledged_at) > now() - interval '12 months'), 0)
      > rules.retail_csf_cap) then
    raise exception 'Recorded applications would exceed the Australian retail CSF cap' using errcode = '22023';
  end if;

  insert into public.investment_commitments (user_id, opportunity_id, provider, jurisdiction, rule_version,
    reviewed_document_url, requested_amount, currency, provider_connection_id)
  values (p_user, p_opportunity, deal.provider, profile.country, rules.version, p_document_url, p_amount, round.currency, verification.connection_id)
  returning id into commitment_id;
  insert into public.investment_audit_logs (user_id, action, subject_id) values (p_user, 'provider_handoff', commitment_id);
  handoff_url := deal.handoff_url;
  return next;
end $$;
create or replace function public.record_private_provider_event(
  p_provider text, p_subject text, p_commitment uuid, p_reference text, p_status text,
  p_provider_event_at timestamptz, p_cooling_off_ends_at timestamptz default null,
  p_units numeric default null, p_invested_amount numeric default null
) returns void language plpgsql set search_path = '' as $$
declare
  entry public.investment_commitments%rowtype;
  listing public.investment_opportunities%rowtype;
  issuer public.private_companies%rowtype;
  subject_connection uuid;
begin
  if p_status is null or p_status not in ('application_received','withdrawal_requested','withdrawal_declined','confirmed','withdrawn','rejected') or
     nullif(trim(p_reference), '') is null or length(p_reference) > 200 or
     p_provider_event_at is null or p_provider_event_at > now() then
    raise exception 'Invalid provider event' using errcode = '22023';
  end if;
  select c.* into entry from public.investment_commitments c
    join public.provider_connections pc on pc.user_id = c.user_id and pc.provider = c.provider and pc.revoked_at is null
    where c.id = p_commitment and c.provider = p_provider and pc.external_subject = p_subject
      and (c.provider_connection_id is null or pc.id = c.provider_connection_id)
    for update of c for share of pc;
  if not found or not exists (
    select 1 from public.private_provider_approvals a join public.private_market_rules r
      on r.jurisdiction = a.jurisdiction and r.version = a.rule_version
    where a.provider = entry.provider and a.jurisdiction = entry.jurisdiction and a.rule_version = entry.rule_version
      and a.enabled and a.expires_at > now() and r.handoff_enabled and r.reviewed_at <= now() and r.effective_at <= now()
  ) then
    raise exception 'Provider event unavailable for this application' using errcode = '42501';
  end if;
  if entry.provider_reference is not null and entry.provider_reference <> p_reference then
    raise exception 'Provider reference conflicts with the recorded application' using errcode = '23505';
  end if;
  if entry.provider_event_at is not null and entry.provider_event_at >= p_provider_event_at then return; end if;
  if not isfinite(p_provider_event_at) or p_provider_event_at < entry.acknowledged_at - interval '5 minutes' or
     (p_cooling_off_ends_at is not null and (p_status <> 'application_received' or
        not isfinite(p_cooling_off_ends_at) or
        p_cooling_off_ends_at <= coalesce(entry.provider_received_at, p_provider_event_at))) then
    raise exception 'Invalid application event or withdrawal deadline' using errcode = '22023';
  end if;
  if not (case entry.status
      when 'handoff' then p_status in ('application_received','withdrawn','rejected')
      when 'application_received' then p_status in ('application_received','withdrawal_requested','confirmed','withdrawn','rejected')
      when 'withdrawal_requested' then p_status in ('withdrawal_requested','withdrawal_declined','withdrawn','rejected')
      else false end) then
    raise exception 'Unsupported application transition' using errcode = '22023';
  end if;
  if p_status = 'confirmed' and entry.cooling_off_ends_at > p_provider_event_at then
    raise exception 'Ownership cannot settle during the provider withdrawal window' using errcode = '22023';
  end if;
  if p_status = 'confirmed' and
     (p_units is null or p_units <= 0 or p_units::text in ('NaN','Infinity','-Infinity') or
      p_invested_amount is null or p_invested_amount <= 0 or p_invested_amount::text in ('NaN','Infinity','-Infinity')) then
    raise exception 'Confirmation requires provider-issued units and settled capital' using errcode = '22023';
  end if;
  select pc.id into subject_connection from public.provider_connections pc
    where pc.user_id = entry.user_id and pc.provider = entry.provider and pc.external_subject = p_subject and pc.revoked_at is null;
  update public.investment_commitments
    set status = case when p_status = 'withdrawal_declined' then 'application_received' else p_status end,
    provider_reference = p_reference, provider_connection_id = subject_connection,
    provider_event_at = p_provider_event_at,
    provider_received_at = case when p_status = 'application_received' then coalesce(provider_received_at, p_provider_event_at)
      else provider_received_at end,
    withdrawal_requested_at = case when p_status = 'withdrawal_requested' and entry.status <> 'withdrawal_requested'
      then p_provider_event_at else withdrawal_requested_at end,
    withdrawal_declined_at = case when p_status = 'withdrawal_declined' then p_provider_event_at
      when p_status = 'withdrawal_requested' then null else withdrawal_declined_at end,
    withdrawn_at = case when p_status = 'withdrawn' then p_provider_event_at else withdrawn_at end,
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
