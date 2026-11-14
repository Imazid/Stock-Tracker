-- Check and open use one set of provider, eligibility and offer rules.
create function provider_operations.private_handoff(
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
    return query select prior.id, deal.handoff_url;
    return;
  end if;

  insert into public.investment_commitments (user_id, opportunity_id, provider, jurisdiction, rule_version,
    reviewed_document_url, requested_amount, currency, provider_connection_id,
    retail_csf_cooling_off_required)
  values (p_user, p_opportunity, deal.provider, profile.country, rules.version, p_document_url, p_amount, round.currency, verification.connection_id,
    requires_cooling_off)
  returning id into commitment_id;
  insert into public.investment_audit_logs (user_id, action, subject_id) values (p_user, 'provider_handoff', commitment_id);
  handoff_url := deal.handoff_url;
  return next;
end $$;

revoke all on function provider_operations.private_handoff(uuid,uuid,numeric,text,text,boolean)
  from public, anon, authenticated, service_role;
grant execute on function provider_operations.private_handoff(uuid,uuid,numeric,text,text,boolean) to service_role;

create or replace function public.prepare_private_handoff(
  p_user uuid, p_opportunity uuid, p_amount numeric, p_document_url text
) returns table (commitment_id uuid, handoff_url text)
language sql set search_path = '' as $$
  select * from provider_operations.private_handoff(p_user, p_opportunity, p_amount, p_document_url, null, true);
$$;

create function public.check_private_handoff(
  p_user uuid, p_opportunity uuid, p_amount numeric, p_document_url text, p_currency text
) returns boolean language sql set search_path = '' as $$
  select exists (select 1 from provider_operations.private_handoff(p_user, p_opportunity, p_amount, p_document_url, p_currency, false));
$$;
revoke all on function public.check_private_handoff(uuid,uuid,numeric,text,text) from public, anon, authenticated, service_role;
grant execute on function public.check_private_handoff(uuid,uuid,numeric,text,text) to service_role;
create function public.open_private_handoff(
  p_user uuid, p_opportunity uuid, p_amount numeric, p_document_url text, p_currency text
) returns table (commitment_id uuid, handoff_url text)
language sql set search_path = '' as $$
  select * from provider_operations.private_handoff(p_user, p_opportunity, p_amount, p_document_url, p_currency, true);
$$;
revoke all on function public.open_private_handoff(uuid,uuid,numeric,text,text) from public, anon, authenticated, service_role;
grant execute on function public.open_private_handoff(uuid,uuid,numeric,text,text) to service_role;
notify pgrst, 'reload schema';
