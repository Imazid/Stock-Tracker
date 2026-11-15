-- Keep the provider's supplementary withdrawal notice separate from the
-- original application receipt, cooling-off period and withdrawal status.
alter table public.investment_commitments
  add column supplementary_notice_at timestamptz,
  add column supplementary_withdrawal_ends_at timestamptz,
  add column supplementary_document_url text;

create function public.record_private_provider_event(
  p_provider text, p_subject text, p_commitment uuid, p_reference text, p_status text,
  p_provider_event_at timestamptz, p_cooling_off_ends_at timestamptz default null,
  p_units numeric default null, p_invested_amount numeric default null,
  p_application_amount numeric default null, p_application_currency text default null,
  p_supplementary_deadline timestamptz default null, p_supplementary_document_url text default null
) returns void language plpgsql set search_path = '' as $$
declare
  entry public.investment_commitments%rowtype;
  listing public.investment_opportunities%rowtype;
  issuer public.private_companies%rowtype;
  subject_connection uuid;
  application_owner uuid;
  application_company uuid;
  is_supplementary boolean := p_status = 'supplementary_notice';
  document_host_pattern text;
begin
  if p_status is null or p_status not in ('application_received','withdrawal_requested','withdrawal_declined','confirmed','withdrawn','rejected','supplementary_notice') or
     nullif(trim(p_reference), '') is null or length(p_reference) > 200 or
     p_provider_event_at is null or p_provider_event_at > now() then
    raise exception 'Invalid provider event' using errcode = '22023';
  end if;
  -- Serialize provider-reported amounts with the same investor/company cap lock
  -- taken by handoff, before either path locks an individual application.
  select c.user_id, r.company_id into application_owner, application_company
  from public.investment_commitments c
  join public.investment_opportunities o on o.id = c.opportunity_id
  join public.funding_rounds r on r.id = o.round_id
  where c.id = p_commitment and c.provider = p_provider;
  if found then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(application_owner::text || p_provider || application_company::text, 0));
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
  if is_supplementary then
    -- Notices have their own clock so an earlier notice delivered after a
    -- withdrawal request cannot undo the request or lose its protection.
    if entry.supplementary_notice_at = p_provider_event_at then return; end if;
    select * into listing from public.investment_opportunities where id = entry.opportunity_id;
    document_host_pattern := case entry.provider
      when 'birchal' then '^https://(www[.])?birchal[.]com/[^[:space:]?#]*$'
      when 'onmarket' then '^https://(www[.]|crowd[.])?onmarket[.]com[.]au/[^[:space:]?#]*$'
      else null end;
    if entry.status not in ('application_received','withdrawal_requested')
      or entry.jurisdiction <> 'AU' or listing.category <> 'Crowdfunding'
      or entry.provider_received_at is null or not isfinite(p_provider_event_at)
      or p_provider_event_at < entry.provider_received_at
      or p_supplementary_deadline is null or not isfinite(p_supplementary_deadline)
      or p_supplementary_deadline <= p_provider_event_at
      or p_supplementary_document_url is null or length(p_supplementary_document_url) > 2048
      or document_host_pattern is null or p_supplementary_document_url !~ document_host_pattern
      or p_cooling_off_ends_at is not null or p_units is not null or p_invested_amount is not null
      or p_application_amount is not null or p_application_currency is not null
    then
      raise exception 'Invalid supplementary withdrawal notice' using errcode = '22023';
    end if;
    -- Retain the evidence for the longest applicable window across notices.
    if (entry.supplementary_withdrawal_ends_at, entry.supplementary_notice_at)
      >= (p_supplementary_deadline, p_provider_event_at) then return; end if;
    update public.investment_commitments
    set supplementary_notice_at = p_provider_event_at,
        supplementary_withdrawal_ends_at = p_supplementary_deadline,
        supplementary_document_url = p_supplementary_document_url
    where id = entry.id;
    insert into public.investment_audit_logs (user_id, action, subject_id)
    values (entry.user_id, 'provider_supplementary_notice', entry.id);
    return;
  end if;
  if p_supplementary_deadline is not null or p_supplementary_document_url is not null then
    raise exception 'Supplementary withdrawal evidence requires a supplementary notice' using errcode = '22023';
  end if;
  if entry.provider_event_at is not null and entry.provider_event_at >= p_provider_event_at then return; end if;
  if not isfinite(p_provider_event_at) or p_provider_event_at < entry.acknowledged_at - interval '5 minutes' or
     (p_cooling_off_ends_at is not null and (p_status <> 'application_received' or
        not isfinite(p_cooling_off_ends_at) or
        p_cooling_off_ends_at <= coalesce(entry.provider_received_at, p_provider_event_at))) then
    raise exception 'Invalid application event or withdrawal deadline' using errcode = '22023';
  end if;
  if (p_application_amount is null) <> (p_application_currency is null)
    or (p_application_amount is not null and (
      p_status <> 'application_received' or p_application_currency is distinct from entry.currency
      or p_application_amount <= 0 or p_application_amount > 9999999999999999
      or scale(p_application_amount) > 4 or p_application_amount = 'NaN'::numeric
    )) then
    raise exception 'Invalid provider application amount or currency' using errcode = '22023';
  end if;
  if not (case entry.status
      when 'handoff' then p_status in ('application_received','withdrawn','rejected')
      when 'application_received' then p_status in ('application_received','withdrawal_requested','confirmed','withdrawn','rejected')
      when 'withdrawal_requested' then p_status in ('withdrawal_requested','withdrawal_declined','withdrawn','rejected')
      else false end) then
    raise exception 'Unsupported application transition' using errcode = '22023';
  end if;
  if p_status = 'confirmed' then
    select * into listing from public.investment_opportunities where id = entry.opportunity_id;
    -- For a legacy Australian CSF application, require the provider deadline
    -- when the investor's class at handoff was not recorded.
    if coalesce(entry.retail_csf_cooling_off_required,
                entry.jurisdiction = 'AU' and listing.category = 'Crowdfunding')
      and (entry.cooling_off_ends_at is null or not isfinite(entry.cooling_off_ends_at)
        or entry.provider_received_at is null or entry.cooling_off_ends_at <= entry.provider_received_at)
    then
      raise exception 'Retail crowdfunding settlement requires the provider cooling-off deadline' using errcode = '22023';
    end if;
  end if;
  if p_status = 'confirmed'
    and greatest(entry.cooling_off_ends_at, entry.supplementary_withdrawal_ends_at) > p_provider_event_at then
    raise exception 'Ownership cannot settle during the provider withdrawal window' using errcode = '22023';
  end if;
  if p_status = 'confirmed' and
     (p_units is null or p_units <= 0 or p_units::text in ('NaN','Infinity','-Infinity') or
      p_invested_amount is null or p_invested_amount <= 0 or p_invested_amount::text in ('NaN','Infinity','-Infinity')) then
    raise exception 'Confirmation requires provider-issued units and settled capital' using errcode = '22023';
  end if;
  if p_status = 'confirmed' and p_invested_amount > entry.provider_application_amount then
    raise exception 'Settled capital exceeds the provider application amount' using errcode = '22023';
  end if;
  select pc.id into subject_connection from public.provider_connections pc
    where pc.user_id = entry.user_id and pc.provider = entry.provider and pc.external_subject = p_subject and pc.revoked_at is null;
  update public.investment_commitments
    set status = case when p_status = 'withdrawal_declined' then 'application_received' else p_status end,
    provider_reference = p_reference, provider_connection_id = subject_connection,
    provider_event_at = p_provider_event_at,
    provider_application_amount = coalesce(p_application_amount, provider_application_amount),
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


drop function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text);

revoke all on function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text)
  from public, anon, authenticated, service_role;
grant execute on function public.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text)
  to service_role;

notify pgrst, 'reload schema';
