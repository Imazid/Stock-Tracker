-- The authenticated profile action presents only the investor-facing fields.
revoke select on public.provider_connections, public.investor_eligibility from authenticated;

alter table public.provider_connections
  add column verification_event_at timestamptz,
  add column revocation_evidence_reference text;

-- Approved adapters authenticate the provider and establish the Stock Tracker
-- account before calling this internal boundary. It accepts no identity files.
create function public.record_private_provider_verification(
  p_user uuid,
  p_provider text,
  p_subject text,
  p_jurisdiction text,
  p_verified_class text,
  p_event_at timestamptz,
  p_evidence_reference text,
  p_expires_at timestamptz default null,
  p_accountant_reviewed_at timestamptz default null
) returns boolean language plpgsql set search_path = '' as $$
declare
  connection public.provider_connections%rowtype;
  latest_event timestamptz;
begin
  if p_user is null or p_provider is null or p_provider not in ('birchal','onmarket','angellist','syndex')
    or p_subject is null or length(trim(p_subject)) not between 1 and 300 or trim(p_subject) <> p_subject
    or p_jurisdiction is null or p_jurisdiction !~ '^[A-Z]{2}$'
    or p_event_at is null or not isfinite(p_event_at) or p_event_at > now()
    or p_evidence_reference is null or length(trim(p_evidence_reference)) not between 1 and 500
    or (p_verified_class is null and (p_expires_at is not null or p_accountant_reviewed_at is not null))
    or (p_verified_class is not null and (
      p_verified_class not in ('retail','wholesale')
      or p_expires_at is null or not isfinite(p_expires_at) or p_expires_at <= now()
      or (p_accountant_reviewed_at is not null and (
        p_verified_class <> 'wholesale' or not isfinite(p_accountant_reviewed_at)
        or p_accountant_reviewed_at > p_event_at))
    ))
  then
    raise exception 'Invalid provider verification record' using errcode = '22023';
  end if;

  if p_verified_class is not null then
    if not exists (
      select 1 from public.private_provider_approvals approval
      join lateral (
        select version, reviewed_at, handoff_enabled
        from public.private_market_rules
        where jurisdiction = p_jurisdiction and effective_at <= now()
        order by effective_at desc, version desc limit 1
      ) rule on rule.version = approval.rule_version
      where approval.provider = p_provider and approval.jurisdiction = p_jurisdiction
        and approval.enabled and approval.expires_at > now()
        and rule.handoff_enabled and rule.reviewed_at <= now()
    ) then
      raise exception 'Provider verification is awaiting approval' using errcode = '42501';
    end if;

    insert into public.provider_connections (user_id, provider, external_subject)
      values (p_user, p_provider, p_subject) on conflict do nothing;
  end if;

  select * into connection from public.provider_connections c
  where (c.user_id, c.provider, c.external_subject) = (p_user, p_provider, p_subject)
  for update;
  if not found then
    raise exception 'Provider account is unavailable for this investor' using errcode = '42501';
  end if;

  -- Include older rows created before provider event timestamps were recorded.
  select greatest(connection.verification_event_at, connection.revoked_at, max(e.verified_at)) into latest_event
  from public.investor_eligibility e where e.connection_id = connection.id;
  if latest_event >= p_event_at then return false; end if;

  if p_verified_class is null then
    -- An account-level revocation must come from a jurisdiction already linked
    -- to this account. It remains valid even if the commercial approval ended.
    if not exists (select 1 from public.investor_eligibility e
      where e.connection_id = connection.id and e.jurisdiction = p_jurisdiction)
    then
      raise exception 'Provider account is unavailable for this jurisdiction' using errcode = '42501';
    end if;
    update public.provider_connections
      set revoked_at = p_event_at, verification_event_at = p_event_at,
          revocation_evidence_reference = p_evidence_reference where id = connection.id;
  else
    update public.provider_connections
      set revoked_at = null, verification_event_at = p_event_at where id = connection.id;
    if connection.revoked_at is not null then
      -- A fresh check restores only the jurisdiction the provider reverified.
      delete from public.investor_eligibility
      where connection_id = connection.id and jurisdiction <> p_jurisdiction;
    end if;
    insert into public.investor_eligibility
      (user_id, provider, connection_id, jurisdiction, verified_class, verified_at, expires_at,
       evidence_reference, accountant_certificate_reviewed_at)
    values (p_user, p_provider, connection.id, p_jurisdiction, p_verified_class, p_event_at, p_expires_at,
      p_evidence_reference, p_accountant_reviewed_at)
    on conflict (user_id, provider, jurisdiction) do update
    set verified_class = excluded.verified_class, verified_at = excluded.verified_at,
        expires_at = excluded.expires_at, evidence_reference = excluded.evidence_reference,
        accountant_certificate_reviewed_at = excluded.accountant_certificate_reviewed_at;
  end if;

  insert into public.investment_audit_logs (user_id, action, subject_id)
  values (p_user, case when p_verified_class is null then 'provider_verification_revoked'
                      else 'provider_verification_recorded' end, connection.id);
  return true;
end $$;

revoke all on function public.record_private_provider_verification(uuid,text,text,text,text,timestamptz,text,timestamptz,timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function public.record_private_provider_verification(uuid,text,text,text,text,timestamptz,text,timestamptz,timestamptz)
  to service_role;

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
