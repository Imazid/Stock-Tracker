-- Scheduled AI summaries are a separate, device-scoped opt-in.
alter table public.private_monitor_devices add column digest_enabled boolean not null default false;
alter table public.research_reports add column kind text not null default 'research'
  check (kind in ('research', 'monitor_digest'));

create function public.configure_private_monitor(
  p_user uuid, p_device uuid, p_companies uuid[], p_eligible boolean, p_enabled boolean, p_digest boolean
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
  insert into public.private_monitor_devices (user_id, device_id, company_ids, eligible_opportunities, digest_enabled)
  values (p_user, p_device,
          array(select c.id from public.private_companies c where c.published and c.id = any(p_companies)),
          p_eligible, coalesce(p_digest, false))
  on conflict (user_id, device_id) do update
    set company_ids = excluded.company_ids, eligible_opportunities = excluded.eligible_opportunities,
        digest_enabled = coalesce(p_digest, private_monitor_devices.digest_enabled), refreshed_at = now();
end $$;

-- Older app builds omit the digest choice when refreshing their preferences.
create or replace function public.configure_private_monitor(
  p_user uuid, p_device uuid, p_companies uuid[], p_eligible boolean, p_enabled boolean
) returns void language sql security definer set search_path = '' as $$
  select public.configure_private_monitor(p_user, p_device, p_companies, p_eligible, p_enabled, null);
$$;

create table public.private_market_digest_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  digest_day date not null,
  source_ids uuid[] not null check (cardinality(source_ids) between 1 and 3),
  lease_token uuid not null,
  next_attempt_at timestamptz not null,
  attempts smallint not null check (attempts between 1 and 3),
  finished_at timestamptz,
  unique (user_id, digest_day)
);
create index private_market_digest_jobs_retention on public.private_market_digest_jobs (digest_day);
alter table public.private_market_digest_jobs enable row level security;
revoke all on public.private_market_digest_jobs from public, anon, authenticated, service_role;

-- Use the live public catalogue, including edits and withdrawals. Explicitly
-- shared company IDs are the only account preferences used to select sources.
create function public.private_market_digest_sources(p_user uuid, p_day date)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'company', s.company, 'title', s.title, 'summary', s.significance,
    'url', s.source_url, 'published_at', s.published_at
  ) order by s.published_at desc, s.id), '[]'::jsonb)
  from (
    select a.id, c.name as company, a.title, a.significance, a.source_url, a.published_at
    from public.corporate_actions a
    join public.private_companies c on c.id = a.company_id and c.published
    where a.published and a.published_at between now() - interval '7 days' and now()
      and exists (
        select 1 from public.private_monitor_devices d where d.user_id = p_user and d.digest_enabled
          and d.refreshed_at >= now() - interval '90 days' and a.company_id = any(d.company_ids)
      )
      and not exists (
        select 1 from public.private_market_digest_jobs j where j.user_id = p_user
          and j.digest_day between p_day - 7 and p_day and j.finished_at is not null and a.id = any(j.source_ids)
      )
    order by a.published_at desc, a.id
    limit 3
  ) s;
$$;

create function public.claim_private_market_digests()
returns table (job_id uuid, owner_id uuid, lease uuid, sources jsonb)
language plpgsql security definer set search_path = '' as $$
declare
  today date := (now() at time zone 'Australia/Sydney')::date;
begin
  -- Keep simultaneous scheduler invocations from dispatching the same account.
  if not pg_catalog.pg_try_advisory_xact_lock(412345, 42) then return; end if;
  return query
  with candidates as materialized (
    select d.user_id, max(d.refreshed_at) as refreshed_at
    from public.private_monitor_devices d
    left join public.private_market_digest_jobs j on j.user_id = d.user_id and j.digest_day = today
    where d.digest_enabled and d.refreshed_at >= now() - interval '90 days'
      and (j.id is null or (j.finished_at is null and j.attempts < 3 and j.next_attempt_at <= now()))
      and not exists (select 1 from public.private_market_digest_jobs older
        where older.user_id = d.user_id and older.digest_day = today - 1
          and older.finished_at is null and older.next_attempt_at > now())
    group by d.user_id
  ), ready as materialized (
    select c.user_id, s.sources
    from candidates c
    cross join lateral (select public.private_market_digest_sources(c.user_id, today) as sources) s
    where jsonb_array_length(s.sources) > 0
    order by c.refreshed_at, c.user_id
    limit 4
  ), claimed as (
    insert into public.private_market_digest_jobs as j (user_id, digest_day, source_ids, lease_token, next_attempt_at, attempts)
    select r.user_id, today, array(select (s->>'id')::uuid from jsonb_array_elements(r.sources) s),
           gen_random_uuid(), now() + interval '15 minutes', 1
    from ready r
    on conflict (user_id, digest_day) do update
      set source_ids = excluded.source_ids, lease_token = excluded.lease_token,
          next_attempt_at = excluded.next_attempt_at, attempts = j.attempts + 1
      where j.finished_at is null and j.attempts < 3 and j.next_attempt_at <= now()
    returning j.id, j.user_id, j.lease_token
  )
  select j.id, j.user_id, j.lease_token, r.sources from claimed j join ready r on r.user_id = j.user_id;
end $$;

create function public.finish_private_market_digest(p_job uuid, p_lease uuid, p_sources jsonb, p_sealed jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  job public.private_market_digest_jobs;
begin
  select * into job from public.private_market_digest_jobs
    where id = p_job and lease_token = p_lease and finished_at is null and next_attempt_at > now()
    for update;
  if not found then return false; end if;
  -- Serialize with preference changes. A withdrawal, edit, or opt-out since
  -- the claim invalidates the result. A later run can pick up current sources.
  perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(job.user_id::text, 41));
  if p_sources is null or p_sealed is null or jsonb_array_length(p_sources) = 0
    or job.source_ids <> array(select (s->>'id')::uuid from jsonb_array_elements(p_sources) s)
    or p_sources <> public.private_market_digest_sources(job.user_id, job.digest_day) then
    return false;
  end if;
  insert into public.research_reports (id, user_id, kind, title, sealed)
    values (job.id, job.user_id, 'monitor_digest', 'Private Markets monitoring summary', p_sealed);
  update public.private_market_digest_jobs set finished_at = now() where id = job.id;
  insert into public.investment_audit_logs (user_id, action, subject_id)
    values (job.user_id, 'scheduled_research_complete', job.id);
  return true;
end $$;

create function public.invoke_private_market_digest()
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  worker_url text;
  worker_secret text;
  request_id bigint;
begin
  delete from public.private_market_digest_jobs where digest_day < (now() at time zone 'Australia/Sydney')::date - 7;
  if pg_catalog.to_regclass('vault.decrypted_secrets') is null
    or not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net')
    or not exists (select 1 from public.private_monitor_devices where digest_enabled
                  and refreshed_at >= now() - interval '90 days') then
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_url using 'private_market_digest_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_secret using 'private_market_digest_secret';
  if coalesce(worker_url, '') = '' or coalesce(worker_secret, '') = '' then return null; end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 55000)'
    into request_id using worker_url, jsonb_build_object(
      'content-type', 'application/json', 'x-scheduler-secret', worker_secret
    ), '{"action":"scheduled_digest"}'::jsonb;
  return request_id;
end $$;

revoke all on function public.configure_private_monitor(uuid,uuid,uuid[],boolean,boolean,boolean),
  public.private_market_digest_sources(uuid,date), public.claim_private_market_digests(),
  public.finish_private_market_digest(uuid,uuid,jsonb,jsonb), public.invoke_private_market_digest()
  from public, anon, authenticated, service_role;
grant execute on function public.configure_private_monitor(uuid,uuid,uuid[],boolean,boolean,boolean),
  public.claim_private_market_digests(), public.finish_private_market_digest(uuid,uuid,jsonb,jsonb) to service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
    and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $job$select cron.schedule('private-market-digest', '*/15 * * * *', 'select public.invoke_private_market_digest()')$job$;
  end if;
end $$;
