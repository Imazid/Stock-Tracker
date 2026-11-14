begin;

-- A partner agreement must explicitly permit the account-linking workflow.
alter table public.private_provider_approvals add column account_link_enabled boolean not null default false;

create table provider_operations.private_link_codes (
  user_id uuid references auth.users(id) on delete cascade,
  session_id uuid not null,
  provider text not null check (provider in ('birchal','onmarket','angellist','syndex')),
  jurisdiction text not null check (jurisdiction ~ '^[A-Z]{2}$'),
  digest text not null unique check (digest ~ '^[a-f0-9]{64}$'),
  issued_at timestamptz not null,
  expires_at timestamptz not null,
  primary key (user_id, provider)
);
alter table provider_operations.private_link_codes enable row level security;
revoke all on provider_operations.private_link_codes from public, anon, authenticated, service_role;
grant select, insert, update, delete on provider_operations.private_link_codes to service_role;

create function public.private_account_link_providers(p_user uuid)
returns table (provider text, jurisdiction text)
language sql stable security invoker set search_path = '' as $$
  select a.provider, a.jurisdiction
  from public.investor_profiles p
  join public.private_provider_approvals a on a.jurisdiction = p.country
  join lateral (
    select r.version, r.handoff_enabled, r.reviewed_at
    from public.private_market_rules r where r.jurisdiction = p.country and r.effective_at <= now()
    order by r.effective_at desc, r.version desc limit 1
  ) rule on rule.version = a.rule_version
  where p.user_id = p_user and a.enabled and a.account_link_enabled and a.expires_at > now()
    and rule.handoff_enabled and rule.reviewed_at <= now()
    and not exists (select from public.provider_connections c
      where c.user_id = p_user and c.provider = a.provider and c.revoked_at is null)
  order by a.provider;
$$;

create function public.issue_private_account_link(p_user uuid, p_session uuid, p_provider text, p_digest text)
returns timestamptz language plpgsql security invoker set search_path = '' as $$
declare
  region text;
  expiry timestamptz := now() + interval '10 minutes';
begin
  select a.jurisdiction into region from public.private_account_link_providers(p_user) a
    where a.provider = p_provider;
  if not found or not public.account_deletion_session_active(p_user, p_session) then
    raise exception 'Account linking is unavailable' using errcode = '42501';
  end if;
  insert into provider_operations.private_link_codes as code (user_id,session_id,provider,jurisdiction,digest,issued_at,expires_at)
    values (p_user,p_session,p_provider,region,p_digest,now(),expiry)
    on conflict (user_id,provider) do update set jurisdiction=excluded.jurisdiction,
      session_id=excluded.session_id, digest=excluded.digest, issued_at=excluded.issued_at, expires_at=excluded.expires_at
    where code.issued_at <= now() - interval '5 seconds';
  if not found then raise exception 'A link code was recently issued' using errcode = 'P0001'; end if;
  return expiry;
end $$;

create function public.redeem_private_account_link(
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

revoke all on function public.private_account_link_providers(uuid),
  public.issue_private_account_link(uuid,uuid,text,text),
  public.redeem_private_account_link(text,text,text,text,timestamptz,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.private_account_link_providers(uuid),
  public.issue_private_account_link(uuid,uuid,text,text),
  public.redeem_private_account_link(text,text,text,text,timestamptz,jsonb) to service_role;
notify pgrst, 'reload schema';
commit;
