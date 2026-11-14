-- Collect alerts from published records and confirmed provider holdings even
-- while a device is offline. A device publishes its monitoring choices only
-- when its owner opts in. Local holding names and financial data stay local.
create table public.private_monitor_devices (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  company_ids uuid[] not null check (cardinality(company_ids) <= 250),
  eligible_opportunities boolean not null default false,
  refreshed_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
create index private_monitor_active_devices on public.private_monitor_devices (refreshed_at);

create table public.private_market_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject_id uuid not null,
  kind text not null check (kind in ('announcement', 'open_round', 'interest', 'capital_call', 'eligible_round')),
  company_name text not null,
  title text not null,
  significance text not null,
  source_url text,
  source_label text,
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  unique (user_id, kind, subject_id)
);
create index private_market_alerts_inbox on public.private_market_alerts (user_id, recorded_at desc, id);
create index private_market_alerts_retention on public.private_market_alerts (recorded_at);

alter table public.private_monitor_devices enable row level security;
alter table public.private_market_alerts enable row level security;
revoke all on public.private_monitor_devices, public.private_market_alerts from public, anon, authenticated, service_role;
grant select on public.private_monitor_devices, public.private_market_alerts to service_role;

create function public.configure_private_monitor(
  p_user uuid, p_device uuid, p_companies uuid[], p_eligible boolean, p_enabled boolean
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or p_device is null or p_enabled is null or p_eligible is null or
     p_companies is null or cardinality(p_companies) > 250 or array_position(p_companies, null) is not null then
    raise exception 'Invalid monitoring settings' using errcode = '22023';
  end if;
  -- Serialize concurrent devices changing this account's preferences.
  perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text, 41));
  if not p_enabled then
    delete from public.private_monitor_devices where user_id = p_user and device_id = p_device;
    if not exists (select 1 from public.private_monitor_devices where user_id = p_user) then
      delete from public.private_market_alerts where user_id = p_user;
    end if;
    return;
  end if;
  delete from public.private_monitor_devices where user_id = p_user and refreshed_at < now() - interval '90 days';
  if not exists (select 1 from public.private_monitor_devices where user_id = p_user and device_id = p_device) and
     (select count(*) from public.private_monitor_devices where user_id = p_user) >= 12 then
    raise exception 'This account has too many monitoring devices' using errcode = '22023';
  end if;
  insert into public.private_monitor_devices (user_id, device_id, company_ids, eligible_opportunities)
  values (p_user, p_device,
          array(select c.id from public.private_companies c where c.published and c.id = any(p_companies)),
          p_eligible)
  on conflict (user_id, device_id) do update
    set company_ids = excluded.company_ids, eligible_opportunities = excluded.eligible_opportunities, refreshed_at = now();
end $$;

create function public.collect_private_market_alerts(p_user uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare inserted integer;
begin
  if p_user is not null then
    perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text, 41));
  else
    perform pg_catalog.pg_advisory_xact_lock(412345, 41);
  end if;
  with active as materialized (
    select user_id, company_ids, eligible_opportunities
    from public.private_monitor_devices
    where refreshed_at >= now() - interval '90 days' and (p_user is null or user_id = p_user)
  ), monitored as materialized (
    select a.user_id, unnest(a.company_ids) as company_id from active a
    union
    select h.user_id, h.company_id from public.private_holdings h
      join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
      where h.confirmed_at is not null and k.status = 'confirmed' and h.company_id is not null
        and exists (select 1 from active a where a.user_id = h.user_id)
  ), funding as materialized (
    select o.id, c.id as company_id, c.name, r.stage, o.status, o.verified_at,
           o.source_url, o.provider, o.eligibility, o.jurisdictions
    from public.investment_opportunities o
    join public.funding_rounds r on r.id = o.round_id and r.published
    join public.private_companies c on c.id = r.company_id and c.published
    where o.published and o.status in ('open', 'interest')
      and o.verified_at between now() - interval '24 hours' and now()
      and r.verified_at between now() - interval '24 hours' and now()
      and (r.closes_at > now() or (o.status = 'interest' and r.closes_at is null))
  ), events as (
    select m.user_id, a.id as subject_id, 'announcement' as kind, c.name as company_name,
           a.title, a.significance, a.source_url, null::text as source_label, a.published_at as occurred_at
    from monitored m
    join public.private_companies c on c.id = m.company_id and c.published
    join public.corporate_actions a on a.company_id = c.id and a.published
    where a.published_at between now() - interval '7 days' and now()
    union all
    select m.user_id, f.id, case f.status when 'open' then 'open_round' else 'interest' end, f.name, f.stage,
           case f.status when 'open' then 'The source listed the round as open at the recorded verification time.'
                        else 'The source published an expression of interest.' end,
           f.source_url, null, f.verified_at
    from monitored m join funding f on f.company_id = m.company_id
    union all
    select distinct a.user_id, f.id, 'eligible_round', f.name, f.stage,
           'This round matched your recorded provider classification when checked. Confirm current eligibility with the provider.',
           f.source_url, null, f.verified_at
    from active a
    join public.investor_profiles p on p.user_id = a.user_id and p.country = 'AU'
    join public.investor_eligibility e on e.user_id = a.user_id and e.jurisdiction = p.country
      and e.verified_at <= now() and e.expires_at > now()
    join public.provider_connections pc on (pc.id, pc.user_id, pc.provider) = (e.connection_id, e.user_id, e.provider)
      and pc.revoked_at is null
    join public.private_provider_approvals pa on pa.provider = e.provider and pa.jurisdiction = e.jurisdiction
      and pa.enabled and pa.expires_at > now()
    join public.private_market_rules rule on (rule.jurisdiction, rule.version) = (pa.jurisdiction, pa.rule_version)
      and rule.handoff_enabled and rule.reviewed_at <= now() and rule.effective_at <= now()
      and not exists (select 1 from public.private_market_rules newer
        where newer.jurisdiction = rule.jurisdiction and newer.effective_at <= now()
          and (newer.effective_at, newer.version) > (rule.effective_at, rule.version))
    join funding f on f.provider = e.provider and f.status = 'open' and p.country = any(f.jurisdictions)
      and (f.eligibility = 'retail' or (f.eligibility = 'wholesale' and e.verified_class = 'wholesale'))
    where a.eligible_opportunities and not exists (
      select 1 from monitored m where m.user_id = a.user_id and m.company_id = f.company_id)
    union all
    select h.user_id, call.id, 'capital_call', h.name, 'Capital call due',
           'A provider-recorded payment is due ' || to_char(call.due_on, 'YYYY-MM-DD') || '.',
           null, call.source, coalesce(call.provider_event_at, now())
    from public.capital_calls call
    join public.private_holdings h on (h.id, h.user_id) = (call.holding_id, call.user_id) and h.confirmed_at is not null
    join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id) and k.status = 'confirmed'
    where call.settled_on is null and call.provider_event_at is not null
      and call.due_on between (now() at time zone 'Australia/Sydney')::date
                          and (now() at time zone 'Australia/Sydney')::date + 7
      and exists (select 1 from active a where a.user_id = h.user_id)
  )
  insert into public.private_market_alerts
    (user_id, subject_id, kind, company_name, title, significance, source_url, source_label, occurred_at)
  select user_id, subject_id, kind, company_name, title, significance, source_url, source_label, occurred_at from events
  on conflict (user_id, kind, subject_id) do nothing;
  get diagnostics inserted = row_count;
  return inserted;
end $$;

create function public.private_market_alert_inbox(p_user uuid)
returns table (id uuid, subject_id uuid, kind text, company_name text, title text,
  significance text, source_url text, source_label text, occurred_at timestamptz, recorded_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with active as materialized (
    select company_ids, eligible_opportunities from public.private_monitor_devices
    where user_id = p_user and refreshed_at >= now() - interval '90 days'
  ), monitored as (
    select unnest(company_ids) as company_id from active
    union
    select h.company_id from public.private_holdings h
    join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
    where h.user_id = p_user and h.confirmed_at is not null and k.status = 'confirmed'
  )
  select n.id, n.subject_id, n.kind, n.company_name, n.title,
         case when n.kind = 'capital_call' then 'A provider-recorded payment is due ' || to_char(call.due_on, 'YYYY-MM-DD') || '.'
              when n.kind in ('open_round', 'eligible_round') and not coalesce(opportunity.status = 'open' and
                opportunity.verified_at between now() - interval '24 hours' and now() and
                round.verified_at between now() - interval '24 hours' and now() and round.closes_at > now(), false)
              then 'The source previously listed this round as open. Current availability is unverified.'
              else n.significance end,
         n.source_url, case when n.kind = 'capital_call' then call.source else n.source_label end,
         case when n.kind = 'capital_call' then call.provider_event_at else n.occurred_at end, n.recorded_at
  from public.private_market_alerts n
  left join public.capital_calls call on n.kind = 'capital_call' and (call.id, call.user_id) = (n.subject_id, p_user)
  left join public.investment_opportunities opportunity on n.kind in ('open_round', 'eligible_round') and opportunity.id = n.subject_id
  left join public.funding_rounds round on round.id = opportunity.round_id
  where n.user_id = p_user and exists (select 1 from active)
    and n.recorded_at >= now() - interval '90 days'
    and case n.kind
      when 'capital_call' then call.id is not null and call.settled_on is null
        and call.due_on between (now() at time zone 'Australia/Sydney')::date and (now() at time zone 'Australia/Sydney')::date + 7
      when 'announcement' then exists (
        select 1 from public.corporate_actions a join public.private_companies c on c.id = a.company_id and c.published
          join monitored m on m.company_id = c.id where a.id = n.subject_id and a.published)
      else exists (
        select 1 from public.investment_opportunities o
          join public.funding_rounds r on r.id = o.round_id and r.published
          join public.private_companies c on c.id = r.company_id and c.published
        where o.id = n.subject_id and o.published and (
          (n.kind = 'eligible_round' and exists (select 1 from active where eligible_opportunities)) or
          (n.kind <> 'eligible_round' and exists (select 1 from monitored m where m.company_id = c.id))))
    end
  order by n.recorded_at desc, n.id
  limit 100;
$$;

create function public.run_private_market_monitor() returns integer
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(412345, 41);
  delete from public.private_monitor_devices where refreshed_at < now() - interval '90 days';
  delete from public.private_market_alerts where recorded_at < now() - interval '90 days';
  return public.collect_private_market_alerts();
end $$;

revoke all on function public.configure_private_monitor(uuid, uuid, uuid[], boolean, boolean),
  public.collect_private_market_alerts(uuid), public.private_market_alert_inbox(uuid),
  public.run_private_market_monitor() from public, anon, authenticated;
grant execute on function public.configure_private_monitor(uuid, uuid, uuid[], boolean, boolean),
  public.collect_private_market_alerts(uuid), public.private_market_alert_inbox(uuid),
  public.run_private_market_monitor() to service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    execute $job$select cron.schedule('private-market-monitor', '*/15 * * * *',
      'select public.run_private_market_monitor()')$job$;
  end if;
end $$;
