begin;

-- Enable only for an offer where the partner accepts and echoes this query parameter.
alter table public.investment_opportunities add column provider_handoff_parameter text
  check (provider_handoff_parameter is null or (
    provider_handoff_parameter ~ '^[A-Za-z][A-Za-z0-9_]{0,63}$'
    and provider_offer_reference is not null and handoff_url is not null
    and handoff_url ~ '^https://((www[.])?birchal[.]com|((www|crowd)[.])?onmarket[.]com[.]au)/[^[:space:][:cntrl:]?#]*$'
    and position(chr(92) in handoff_url) = 0
  ));

alter table public.investment_commitments
  add column provider_handoff_parameter text,
  add column provider_handoff_reference uuid unique,
  add constraint private_handoff_reference_pair check (
    (provider_handoff_parameter is null) = (provider_handoff_reference is null));

-- Check and open use one set of provider, eligibility and offer rules.
create or replace function provider_operations.private_handoff(
  p_user uuid, p_opportunity uuid, p_amount numeric, p_document_url text, p_currency text, p_commit boolean
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
  requires_cooling_off boolean;
  referral_reference uuid;
begin
  if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or
     p_amount <= 0 or p_amount > 9999999999999999 or scale(p_amount) > 4 then
    raise exception 'Invalid investment amount' using errcode = '22023';
  end if;
  select * into deal from public.investment_opportunities where id = p_opportunity and published for share;
  select * into round from public.funding_rounds where id = deal.round_id and published for share;
  if not found or not exists (select 1 from public.private_companies where id = round.company_id and published)
     or deal.status <> 'open' or round.closes_at is null or round.closes_at <= now()
     or deal.verified_at < now() - interval '24 hours' or deal.verified_at > now()
     or round.verified_at < now() - interval '24 hours' or round.verified_at > now()
     or deal.minimum is null or p_amount < deal.minimum then
    raise exception 'Offer availability or minimum could not be verified' using errcode = '22023';
  end if;
  if p_currency is not null and round.currency is distinct from p_currency then
    raise exception 'The offer currency changed. Reopen the offer and review its current terms' using errcode = '22023';
  end if;
  select * into profile from public.investor_profiles where user_id = p_user for share;
  if not found or profile.country <> 'AU' or not (profile.country = any(deal.jurisdictions)) then
    raise exception 'This offer requires an eligible Australian investor profile' using errcode = '42501';
  end if;
  select * into rules from public.private_market_rules where jurisdiction = profile.country and effective_at <= now()
    order by effective_at desc, version desc limit 1 for share;
  if not found or not rules.handoff_enabled or rules.reviewed_at > now() or not exists (
    select 1 from public.private_provider_approvals
    where provider = deal.provider and jurisdiction = profile.country and rule_version = rules.version
      and enabled and expires_at > now() for share
  ) then
    raise exception 'Provider handoff is awaiting approval' using errcode = '42501';
  end if;
  -- Keep the lock order shared by handoff and provider updates.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text || deal.provider || round.company_id::text, 0));
  -- Serialize the eligibility read with provider revocation and re-verification.
  perform 1 from public.provider_connections
  where user_id = p_user and provider = deal.provider for share;
  select e.* into verification from public.investor_eligibility e
    join public.provider_connections c on c.id = e.connection_id and c.revoked_at is null
    where e.user_id = p_user and e.provider = deal.provider and e.jurisdiction = profile.country
      and e.verified_at <= now() and e.expires_at > now();
  if not found or deal.eligibility = 'provider review' or
     (deal.eligibility = 'wholesale' and verification.verified_class <> 'wholesale') then
    raise exception 'The provider must verify eligibility for this offer' using errcode = '42501';
  end if;
  requires_cooling_off := profile.country = 'AU' and deal.category = 'Crowdfunding'
    and verification.verified_class = 'retail';
  host_pattern := case deal.provider
    when 'birchal' then '^https://(www\.)?birchal\.com/'
    when 'onmarket' then '^https://(www\.|crowd\.)?onmarket\.com\.au/'
    else null end;
  if host_pattern is null or deal.handoff_url is null or deal.handoff_url !~ host_pattern
     or deal.offer_document_url is null or deal.offer_document_url is distinct from p_document_url then
    raise exception 'The offer document or approved provider link is unavailable' using errcode = '22023';
  end if;

  select * into prior from public.investment_commitments where user_id = p_user and opportunity_id = p_opportunity
    and status in ('handoff','application_received','withdrawal_requested','confirmed');
  if found and not (prior.status = 'handoff' and prior.requested_amount = p_amount and prior.rule_version = rules.version
    and prior.reviewed_document_url = p_document_url
    and (prior.provider_handoff_reference is null
      or prior.provider_handoff_parameter is not distinct from deal.provider_handoff_parameter)
    and (prior.provider_connection_id is null or prior.provider_connection_id = verification.connection_id)) then
    raise exception 'An active application record already exists' using errcode = '23505';
  end if;

  if verification.verified_class = 'retail' and deal.category = 'Crowdfunding' and
     (round.currency <> 'AUD' or rules.retail_csf_cap is null or
      p_amount + coalesce((select sum(coalesce(c.provider_application_amount, c.requested_amount)) from public.investment_commitments c
        join public.investment_opportunities o on o.id = c.opportunity_id
        join public.funding_rounds r on r.id = o.round_id
        where c.user_id = p_user and c.provider = deal.provider and r.company_id = round.company_id
          and o.category = 'Crowdfunding' and c.currency = 'AUD'
          and c.status in ('application_received','withdrawal_requested','confirmed')
          and coalesce(c.provider_received_at, c.acknowledged_at) > now() - interval '12 months'), 0)
      > rules.retail_csf_cap) then
    raise exception 'Recorded applications would exceed the Australian retail CSF cap' using errcode = '22023';
  end if;

  -- The check returns neither a persisted commitment nor a provider URL.
  if not p_commit then
    return query select null::uuid, null::text;
    return;
  end if;

  if prior.id is not null then
    if requires_cooling_off and prior.retail_csf_cooling_off_required is false then
      update public.investment_commitments set retail_csf_cooling_off_required = true
        where id = prior.id and status = 'handoff';
    end if;
    commitment_id := prior.id;
    referral_reference := prior.provider_handoff_reference;
  else
    insert into public.investment_commitments (user_id, opportunity_id, provider, jurisdiction, rule_version,
      reviewed_document_url, requested_amount, currency, provider_connection_id,
      retail_csf_cooling_off_required)
    values (p_user, p_opportunity, deal.provider, profile.country, rules.version, p_document_url, p_amount, round.currency, verification.connection_id,
      requires_cooling_off)
    returning id into commitment_id;
    insert into public.investment_audit_logs (user_id, action, subject_id) values (p_user, 'provider_handoff', commitment_id);
  end if;
  handoff_url := deal.handoff_url;
  if deal.provider_handoff_parameter is not null then
    if referral_reference is null then
      referral_reference := gen_random_uuid();
      update public.investment_commitments
      set provider_handoff_parameter = deal.provider_handoff_parameter, provider_handoff_reference = referral_reference
      where id = commitment_id;
    end if;
    handoff_url := handoff_url || '?' || deal.provider_handoff_parameter || '=' || referral_reference::text;
  end if;
  return next;
end $$;

-- Preserve the application ledger and put the reference check on both delivery paths.
alter function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text) set schema provider_operations;
alter function provider_operations.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text)
  rename to apply_private_provider_application;

create function provider_operations.record_private_provider_event(
  p_provider text, p_subject text, p_commitment uuid, p_reference text, p_status text,
  p_provider_event_at timestamptz, p_cooling_off_ends_at timestamptz,
  p_units numeric, p_invested_amount numeric,
  p_application_amount numeric, p_application_currency text,
  p_supplementary_deadline timestamptz, p_supplementary_document_url text,
  p_handoff_reference uuid
) returns void language plpgsql set search_path = '' as $$
declare
  entry public.investment_commitments%rowtype;
  issuer_id uuid;
  reference_required boolean;
begin
  -- Use the application ledger's cap lock before reading the current receipt.
  select c.user_id, r.company_id into entry.user_id, issuer_id
  from public.investment_commitments c
  join public.investment_opportunities o on o.id = c.opportunity_id
  join public.funding_rounds r on r.id = o.round_id
  where c.id = p_commitment and c.provider = p_provider
  for share of o;
  if found then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(entry.user_id::text || p_provider || issuer_id::text, 0));

    select c.provider_reference, c.provider_handoff_reference, o.provider_handoff_parameter is not null
    into entry.provider_reference, entry.provider_handoff_reference, reference_required
    from public.investment_commitments c
    join public.investment_opportunities o on o.id = c.opportunity_id
    where c.id = p_commitment and c.provider = p_provider;

    if (p_handoff_reference is not null and (
        p_status is distinct from 'application_received' or entry.provider_handoff_reference is distinct from p_handoff_reference))
      or (entry.provider_reference is null and (reference_required or entry.provider_handoff_reference is not null)
        and (p_status is distinct from 'application_received' or p_handoff_reference is null)) then
      raise exception 'Provider receipt requires the original handoff reference' using errcode = '42501';
    end if;
  end if;
  perform provider_operations.apply_private_provider_application(
    p_provider,p_subject,p_commitment,p_reference,p_status,p_provider_event_at,p_cooling_off_ends_at,
    p_units,p_invested_amount,p_application_amount,p_application_currency,p_supplementary_deadline,p_supplementary_document_url
  );
end $$;

revoke all on function provider_operations.record_private_provider_event(
  text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text,uuid)
  from public, anon, authenticated, service_role;
grant execute on function provider_operations.record_private_provider_event(
  text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text,uuid)
  to service_role;

create or replace function public.record_private_provider_event(
  p_provider text, p_subject text, p_commitment uuid, p_reference text, p_status text,
  p_provider_event_at timestamptz, p_cooling_off_ends_at timestamptz default null,
  p_units numeric default null, p_invested_amount numeric default null,
  p_application_amount numeric default null, p_application_currency text default null,
  p_supplementary_deadline timestamptz default null, p_supplementary_document_url text default null
) returns void language sql security invoker set search_path = '' as $$
  select provider_operations.record_private_provider_event(
    p_provider,p_subject,p_commitment,p_reference,p_status,p_provider_event_at,p_cooling_off_ends_at,
    p_units,p_invested_amount,p_application_amount,p_application_currency,p_supplementary_deadline,
    p_supplementary_document_url,null
  );
$$;

create or replace function public.accept_private_provider_delivery(
  p_provider text, p_event_id text, p_body_sha256 text, p_kind text,
  p_subject text, p_event_at timestamptz, p_details jsonb
) returns text language plpgsql set search_path = '' as $$
declare
  owner_id uuid;
  target_id uuid;
  stored_hash text;
  affected integer;
begin
  if p_kind is null or p_kind not in ('verification','application','holding_activity','holding_disposition')
    or p_event_at is null or not isfinite(p_event_at) or p_event_at > now()
    or nullif(trim(p_subject), '') is null or length(p_subject) > 300
    or p_details is null or jsonb_typeof(p_details) <> 'object' then
    raise exception 'Invalid provider event' using errcode = '22023';
  end if;

  select user_id into owner_id from public.provider_connections
    where provider = p_provider and external_subject = p_subject;
  if not found then
    raise exception 'Provider account is unavailable' using errcode = '42501';
  end if;

  insert into provider_operations.private_event_deliveries (provider,event_id,body_sha256,user_id)
    values (p_provider,p_event_id,p_body_sha256,owner_id)
    on conflict (provider,event_id) do nothing;
  get diagnostics affected = row_count;
  if affected = 0 then
    select body_sha256 into stored_hash from provider_operations.private_event_deliveries
      where provider = p_provider and event_id = p_event_id and user_id = owner_id;
    if stored_hash is distinct from p_body_sha256 then
      raise exception 'Provider delivery ID was already used' using errcode = '23505';
    end if;
    return 'duplicate';
  end if;

  case p_kind
  when 'verification' then
    -- The adapter can update an established binding. A delivery cannot claim a
    -- Stock Tracker user ID or establish a new provider link.
    perform public.record_private_provider_verification(
      owner_id, p_provider, p_subject, p_details->>'jurisdiction', p_details->>'verified_class',
      p_event_at, p_details->>'evidence_reference', (p_details->>'expires_at')::timestamptz,
      (p_details->>'accountant_reviewed_at')::timestamptz);
  when 'application' then
    target_id := (p_details->>'commitment_id')::uuid;
    perform provider_operations.record_private_provider_event(
      p_provider, p_subject, target_id, p_details->>'reference', p_details->>'status',
      p_event_at, (p_details->>'cooling_off_ends_at')::timestamptz, (p_details->>'units')::numeric,
      (p_details->>'invested_amount')::numeric, (p_details->>'application_amount')::numeric, p_details->>'application_currency',
      (p_details->>'supplementary_deadline')::timestamptz, p_details->>'supplementary_document_url',
      (p_details->>'handoff_reference')::uuid);
  when 'holding_activity' then
    target_id := (p_details->>'holding_id')::uuid;
    perform public.record_private_holding_activity(
      p_provider, p_subject, target_id, p_details->>'activity', p_details->>'reference', p_event_at,
      (p_details->>'amount')::numeric, p_details->>'currency', (p_details->>'record_date')::date,
      p_details->>'source', p_details->>'method', (p_details->>'settled_on')::date);
  when 'holding_disposition' then
    target_id := (p_details->>'holding_id')::uuid;
    perform public.record_private_holding_disposition(
      p_provider, p_subject, target_id, p_details->>'reference', p_event_at, p_details->>'currency',
      p_details->>'source', (p_details->>'reversed')::boolean, (p_details->>'settled_on')::date,
      (p_details->>'sold_units')::numeric, (p_details->>'net_proceeds')::numeric, (p_details->>'disposed_cost')::numeric);
  end case;
  return 'accepted';
end $$;

revoke all on function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text) from public, anon, authenticated, service_role;
grant execute on function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text) to service_role;

notify pgrst, 'reload schema';
commit;
