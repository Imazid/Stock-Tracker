-- The sequence orders alert collection for each account. The collector holds the
-- account lock, or the exclusive monitor lock, through commit.
alter table public.private_market_alerts add column push_sequence bigint generated always as identity;
create index private_market_alerts_push_cursor on public.private_market_alerts (user_id, push_sequence);

create table public.private_market_push_devices (
  user_id uuid not null,
  device_id uuid not null,
  session_id uuid not null,
  environment text not null check (environment in ('sandbox', 'production')),
  token_hash text not null check (token_hash ~ '^[a-f0-9]{64}$'),
  sealed jsonb not null,
  delivered_through bigint not null,
  registered_at timestamptz not null default now(),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  leased_through bigint,
  primary key (user_id, device_id),
  unique (environment, token_hash),
  foreign key (user_id, device_id) references public.private_monitor_devices(user_id, device_id) on delete cascade
);
create index private_market_push_due on public.private_market_push_devices (environment, next_attempt_at);
create index private_market_push_session on public.private_market_push_devices (session_id);
alter table public.private_market_push_devices enable row level security;
revoke all on public.private_market_push_devices from public, anon, authenticated, service_role;

-- GoTrue owns this relation and can create it after the app migrations.
create function public.private_market_push_session_active(p_user uuid, p_session uuid)
returns boolean language plpgsql stable set search_path = '' as $$
declare
  active boolean;
begin
  if pg_catalog.to_regclass('auth.sessions') is null then return false; end if;
  execute 'select exists (select 1 from auth.sessions where user_id = $1 and id = $2
    and (not_after is null or not_after > now()))' into active using p_user, p_session;
  return active;
end $$;

create function public.configure_private_market_push(
  p_user uuid, p_device uuid, p_session uuid, p_environment text, p_token_hash text, p_sealed jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  cursor_position bigint;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text, 41));
  perform pg_catalog.pg_advisory_xact_lock(412345, 43);
  if p_sealed is null then
    delete from public.private_market_push_devices where (user_id, device_id) = (p_user, p_device);
    return false;
  end if;
  if not public.private_market_push_session_active(p_user, p_session)
    or not exists (select 1 from public.private_monitor_devices d
      where (d.user_id, d.device_id) = (p_user, p_device) and d.refreshed_at >= now() - interval '90 days') then
    return false;
  end if;

  -- A token follows the current sign-in on that installation.
  delete from public.private_market_push_devices
    where (environment, token_hash) = (p_environment, p_token_hash)
      and (user_id, device_id) <> (p_user, p_device);
  select coalesce(max(push_sequence), 0) into cursor_position
    from public.private_market_alerts where user_id = p_user;
  insert into public.private_market_push_devices as d
    (user_id, device_id, session_id, environment, token_hash, sealed, delivered_through)
    values (p_user, p_device, p_session, p_environment, p_token_hash, p_sealed, cursor_position)
  on conflict (user_id, device_id) do update
    set session_id = excluded.session_id, environment = excluded.environment, token_hash = excluded.token_hash,
        sealed = excluded.sealed, delivered_through = excluded.delivered_through, registered_at = now(),
        next_attempt_at = now(), lease_token = null, leased_through = null
    where (d.session_id, d.environment, d.token_hash) is distinct from
          (excluded.session_id, excluded.environment, excluded.token_hash);
  return true;
end $$;

-- A generic notification opens the inbox. Recheck using the sending device's
-- preferences and authoritative publication, eligibility and settlement data.
create function public.private_market_push_through(p_user uuid, p_device uuid, p_after bigint)
returns bigint language sql stable set search_path = '' as $$
  select max(n.push_sequence)
  from public.private_market_alerts n
  join public.private_monitor_devices d on d.user_id = n.user_id and d.device_id = p_device
  where n.user_id = p_user and n.push_sequence > p_after and n.recorded_at >= now() - interval '24 hours'
    and d.refreshed_at >= now() - interval '90 days'
    and case n.kind
      when 'announcement' then exists (
        select 1 from public.corporate_actions a join public.private_companies c on c.id = a.company_id and c.published
        where a.id = n.subject_id and a.published and a.published_at <= now()
          and (a.company_id = any(d.company_ids) or exists (
            select 1 from public.private_holdings h join public.investment_commitments k
              on (k.id, k.user_id) = (h.commitment_id, h.user_id)
            where h.user_id = p_user and h.company_id = a.company_id and h.confirmed_at is not null and k.status = 'confirmed')))
      when 'capital_call' then exists (
        select 1 from public.capital_calls a join public.private_holdings h on (h.id, h.user_id) = (a.holding_id, a.user_id)
          join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
        where a.id = n.subject_id and a.user_id = p_user and a.settled_on is null and a.provider_event_at is not null
          and h.confirmed_at is not null and k.status = 'confirmed'
          and a.due_on between (now() at time zone 'Australia/Sydney')::date and (now() at time zone 'Australia/Sydney')::date + 7)
      else exists (
        select 1 from public.investment_opportunities o
        join public.funding_rounds r on r.id = o.round_id and r.published
        join public.private_companies c on c.id = r.company_id and c.published
        where o.id = n.subject_id and o.published
          and o.verified_at between now() - interval '24 hours' and now()
          and r.verified_at between now() - interval '24 hours' and now()
          and ((o.status = 'open' and r.closes_at > now() and n.kind in ('open_round', 'eligible_round'))
            or (o.status = 'interest' and n.kind = 'interest' and (r.closes_at > now() or r.closes_at is null)))
          and ((n.kind <> 'eligible_round' and (c.id = any(d.company_ids) or exists (
            select 1 from public.private_holdings h join public.investment_commitments k
              on (k.id, k.user_id) = (h.commitment_id, h.user_id)
            where h.user_id = p_user and h.company_id = c.id and h.confirmed_at is not null and k.status = 'confirmed')))
            or (n.kind = 'eligible_round' and d.eligible_opportunities and exists (
              select 1 from public.investor_profiles p
              join public.investor_eligibility e on e.user_id = p.user_id and e.jurisdiction = p.country and e.provider = o.provider
              join public.provider_connections pc on (pc.id, pc.user_id, pc.provider) = (e.connection_id, e.user_id, e.provider)
              join public.private_provider_approvals pa on pa.provider = e.provider and pa.jurisdiction = e.jurisdiction
              join public.private_market_rules rule on (rule.jurisdiction, rule.version) = (pa.jurisdiction, pa.rule_version)
              where p.user_id = p_user and p.country = 'AU' and p.country = any(o.jurisdictions)
                and e.verified_at <= now() and e.expires_at > now() and pc.revoked_at is null
                and pa.enabled and pa.expires_at > now() and rule.handoff_enabled
                and rule.reviewed_at <= now() and rule.effective_at <= now()
                and not exists (select 1 from public.private_market_rules newer
                  where newer.jurisdiction = rule.jurisdiction and newer.effective_at <= now()
                    and (newer.effective_at, newer.version) > (rule.effective_at, rule.version))
                and (o.eligibility = 'retail' or (o.eligibility = 'wholesale' and e.verified_class = 'wholesale'))))))
    end;
$$;

create function public.claim_private_market_push(p_environments text[])
returns table (owner_id uuid, installation_id uuid, push_environment text, lease uuid, envelope jsonb)
language sql security definer set search_path = '' as $$
  with ready as materialized (
    select p.user_id, p.device_id, pending.through
    from public.private_market_push_devices p
    cross join lateral (select public.private_market_push_through(p.user_id, p.device_id, p.delivered_through) as through) pending
    where p.environment = any(p_environments) and p.next_attempt_at <= now() and pending.through is not null
      and public.private_market_push_session_active(p.user_id, p.session_id)
    order by p.next_attempt_at, p.device_id
    limit 30 for update of p skip locked
  )
  update public.private_market_push_devices p
    set next_attempt_at = now() + interval '15 minutes', lease_token = gen_random_uuid(), leased_through = r.through
    from ready r where (p.user_id, p.device_id) = (r.user_id, r.device_id)
  returning p.user_id, p.device_id, p.environment, p.lease_token, p.sealed;
$$;

-- Check consent and evidence again before sending the leased notification.
create function public.private_market_push_is_current(p_user uuid, p_device uuid, p_lease uuid)
returns boolean language sql security definer set search_path = '' as $$
  select exists (
    select 1 from public.private_market_push_devices p
    where (p.user_id,p.device_id,p.lease_token) = (p_user,p_device,p_lease)
      and p.next_attempt_at > now()
      and public.private_market_push_session_active(p.user_id, p.session_id)
      and public.private_market_push_through(p.user_id, p.device_id, p.delivered_through) >= p.leased_through
  );
$$;

create function public.finish_private_market_push(p_user uuid, p_device uuid, p_lease uuid, p_result text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_result = 'invalid' then
    delete from public.private_market_push_devices where (user_id,device_id,lease_token) = (p_user,p_device,p_lease);
  elsif p_result = 'accepted' then
    update public.private_market_push_devices set delivered_through = leased_through, leased_through = null,
      lease_token = null, next_attempt_at = now() + interval '15 minutes'
      where (user_id,device_id,lease_token) = (p_user,p_device,p_lease);
  end if;
end $$;

create function public.invoke_private_market_push()
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  worker_url text;
  worker_secret text;
  request_id bigint;
begin
  delete from public.private_market_push_devices p
    where not public.private_market_push_session_active(p.user_id, p.session_id);
  if pg_catalog.to_regclass('vault.decrypted_secrets') is null or
    not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') or
    not exists (select 1 from public.private_market_push_devices) then return null; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_url using 'private_market_digest_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_secret using 'private_market_digest_secret';
  if coalesce(worker_url, '') = '' or coalesce(worker_secret, '') = '' then return null; end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 55000)'
    into request_id using worker_url, jsonb_build_object(
      'content-type', 'application/json', 'x-scheduler-secret', worker_secret
    ), '{"action":"scheduled_push"}'::jsonb;
  return request_id;
end $$;

revoke all on function public.configure_private_market_push(uuid,uuid,uuid,text,text,jsonb),
  public.private_market_push_session_active(uuid,uuid), public.private_market_push_through(uuid,uuid,bigint),
  public.claim_private_market_push(text[]),
  public.private_market_push_is_current(uuid,uuid,uuid), public.finish_private_market_push(uuid,uuid,uuid,text),
  public.invoke_private_market_push()
  from public, anon, authenticated, service_role;
grant execute on function public.configure_private_market_push(uuid,uuid,uuid,text,text,jsonb),
  public.claim_private_market_push(text[]), public.private_market_push_is_current(uuid,uuid,uuid),
  public.finish_private_market_push(uuid,uuid,uuid,text) to service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
    and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $job$select cron.schedule('private-market-push', '2-59/5 * * * *', 'select public.invoke_private_market_push()')$job$;
  end if;
end $$;
