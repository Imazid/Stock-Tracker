begin;

alter table public.provider_connections add column owner_disconnected_at timestamptz;

create function public.disconnect_private_provider(p_user uuid, p_session uuid, p_provider text)
returns boolean language plpgsql security invoker set search_path = '' as $$
declare
  connection_id uuid;
  disconnected_at timestamptz;
begin
  if not public.account_deletion_session_active(p_user, p_session) then
    raise exception 'The investor session is unavailable' using errcode = '42501';
  end if;

  if exists (select 1 from public.provider_connections
    where user_id = p_user and provider = p_provider and owner_disconnected_at is not null) then
    return true;
  end if;

  -- Redemption locks the code before the provider connection. Keep that order.
  delete from provider_operations.private_link_codes where user_id = p_user and provider = p_provider;
  disconnected_at := clock_timestamp();
  update public.provider_connections
  set owner_disconnected_at = disconnected_at, revoked_at = greatest(revoked_at, disconnected_at)
  where user_id = p_user and provider = p_provider and owner_disconnected_at is null
  returning id into connection_id;
  if found then
    insert into public.investment_audit_logs (user_id,action,subject_id)
      values (p_user,'provider_disconnected_by_owner',connection_id);
    return true;
  end if;
  if exists (select 1 from public.provider_connections
    where user_id = p_user and provider = p_provider and owner_disconnected_at is not null) then
    return true;
  end if;
  raise exception 'The investor connection is unavailable' using errcode = '42501';
end $$;

revoke all on function public.disconnect_private_provider(uuid,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.disconnect_private_provider(uuid,uuid,text) to service_role;

create or replace function public.record_private_provider_verification(
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

  if connection.owner_disconnected_at is not null then
    raise exception 'The investor disconnected this provider' using errcode = '42501';
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

create or replace function public.redeem_private_account_link(
  p_provider text, p_event_id text, p_body_sha256 text, p_subject text,
  p_event_at timestamptz, p_details jsonb
) returns text language plpgsql security invoker set search_path = '' as $$
declare
  link provider_operations.private_link_codes%rowtype;
  receipt provider_operations.private_event_deliveries%rowtype;
begin
  if p_event_at is null or not isfinite(p_event_at) or p_event_at > now() or
    p_event_id is null or p_event_id !~ '^[a-zA-Z0-9_.:-]{1,160}$' or
    p_body_sha256 is null or p_body_sha256 !~ '^[a-f0-9]{64}$' or
    p_details->>'code_digest' is null or p_details->>'code_digest' !~ '^[a-f0-9]{64}$' or
    p_details->>'verified_class' is null then
    raise exception 'Invalid account link event' using errcode = '22023';
  end if;

  -- Exact retries succeed after the code has been consumed, including a lost HTTP response.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_provider || ':' || p_event_id, 52));
  select * into receipt from provider_operations.private_event_deliveries
    where provider = p_provider and event_id = p_event_id;
  if found then
    if receipt.body_sha256 is distinct from p_body_sha256 or not exists (
      select from public.provider_connections where user_id=receipt.user_id
        and provider=p_provider and external_subject=p_subject
    ) then
      raise exception 'Provider delivery ID was already used' using errcode = '23505';
    end if;
    return 'duplicate';
  end if;

  select * into link from provider_operations.private_link_codes
    where digest = p_details->>'code_digest' and provider = p_provider
    for update;
  if not found or link.expires_at <= now() or p_event_at < link.issued_at - interval '1 second'
    or link.jurisdiction is distinct from p_details->>'jurisdiction'
    or not public.account_deletion_session_active(link.user_id, link.session_id)
    or not exists (select from public.private_account_link_providers(link.user_id) a
      where (a.provider,a.jurisdiction) = (link.provider,link.jurisdiction)) then
    raise exception 'Account linking is unavailable' using errcode = '42501';
  end if;

  -- Hold approval and profile evidence until the verified link commits.
  perform 1 from public.private_provider_approvals a
    join public.private_market_rules r on (r.jurisdiction,r.version) = (a.jurisdiction,a.rule_version)
    join public.investor_profiles p on (p.user_id,p.country) = (link.user_id,a.jurisdiction)
    where (a.provider,a.jurisdiction) = (link.provider,link.jurisdiction)
      and a.account_link_enabled and a.enabled and a.expires_at > now()
      and r.handoff_enabled and r.reviewed_at <= now() and r.effective_at <= now()
    for share of a, r, p;
  if not found then raise exception 'Account linking is unavailable' using errcode = '42501'; end if;

  -- Only the owner's new code for the same external account can reopen access.
  -- If verification fails, the connection and its marker roll back together.
  update public.provider_connections
  set owner_disconnected_at = null
  where (user_id,provider,external_subject) = (link.user_id,p_provider,p_subject)
    and owner_disconnected_at < link.issued_at;

  if not public.record_private_provider_verification(
    link.user_id,p_provider,p_subject,link.jurisdiction,p_details->>'verified_class',p_event_at,
    p_details->>'evidence_reference',(p_details->>'expires_at')::timestamptz,(p_details->>'accountant_reviewed_at')::timestamptz
  ) then
    raise exception 'Account linking requires fresh provider verification' using errcode = '22023';
  end if;

  insert into provider_operations.private_event_deliveries (provider,event_id,body_sha256,user_id)
    values (p_provider,p_event_id,p_body_sha256,link.user_id);
  delete from provider_operations.private_link_codes where user_id=link.user_id and provider=p_provider;
  return 'accepted';
end $$;

notify pgrst, 'reload schema';
commit;
