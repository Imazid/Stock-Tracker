create schema provider_operations;
revoke all on schema provider_operations from public, anon, authenticated;

create table provider_operations.workers (
  name text primary key,
  monitored_since timestamptz not null default now()
);
insert into provider_operations.workers (name) values ('provider-maintenance'), ('snaptrade-activity-sync');

create table provider_operations.worker_runs (
  id bigint generated always as identity primary key,
  worker text not null references provider_operations.workers (name),
  finished_at timestamptz not null default clock_timestamp(),
  duration_ms integer not null check (duration_ms >= 0),
  jobs integer not null check (jobs >= 0),
  errors integer not null check (errors >= 0),
  failure_codes text[] not null default '{}' check (
    cardinality(failure_codes) <= 8 and
    failure_codes <@ array['worker_error','database','provider_auth','provider_rate_limit',
      'provider_unavailable','provider_response','provider_order','internal']
  )
);
create index provider_worker_runs_worker_time_idx on provider_operations.worker_runs (worker, finished_at desc);
create index provider_worker_runs_time_idx on provider_operations.worker_runs (finished_at);

create table provider_operations.alerts (
  id bigint generated always as identity primary key,
  condition text not null check (condition in ('worker_missing', 'worker_errors', 'order_submitting', 'order_reconciling')),
  subject text not null,
  observed_count integer not null check (observed_count >= 0),
  opened_at timestamptz not null,
  last_seen_at timestamptz not null,
  resolved_at timestamptz
);
create unique index provider_alerts_open_key on provider_operations.alerts (condition, subject)
  where resolved_at is null;
create index provider_alerts_resolved_idx on provider_operations.alerts (resolved_at)
  where resolved_at is not null;

alter table provider_operations.workers enable row level security;
alter table provider_operations.worker_runs enable row level security;
alter table provider_operations.alerts enable row level security;
revoke all on all tables in schema provider_operations from public, anon, authenticated, service_role;
grant usage on schema provider_operations to service_role;
grant insert (worker, duration_ms, jobs, errors, failure_codes) on provider_operations.worker_runs to service_role;

-- Invoked by the cron owner. The lock keeps concurrent checks from resolving an
-- incident with an older observation. Only aggregate counts appear in database logs.
create function provider_operations.check_alerts() returns void
language plpgsql security invoker set search_path = '' as $$
declare
  checked_at timestamptz;
  incident record;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(145013, 39101) then return; end if;
  checked_at := clock_timestamp();

  for incident in
    with worker_checks as (
      select w.name, greatest(w.monitored_since, max(r.finished_at)) as last_finished,
        count(*) filter (where r.errors > 0)::integer as failing_runs
      from provider_operations.workers w
      left join provider_operations.worker_runs r on r.worker = w.name
        and r.finished_at >= checked_at - interval '15 minutes'
      group by w.name, w.monitored_since
    ),
    active as (
      select 'worker_missing' as condition, name as subject, 0 as observed_count
        from worker_checks where last_finished < checked_at - interval '5 minutes'
      union all
      select 'worker_errors', name, failing_runs from worker_checks where failing_runs >= 3
      union all
      select 'order_submitting', i.provider || '/' || i.environment, count(*)::integer
        from public.order_intents i where i.status = 'submitting'
          and coalesce(i.provider_submitting_at, i.created_at) < checked_at - interval '5 minutes'
        group by i.provider, i.environment
      union all
      select 'order_reconciling', i.provider || '/' || i.environment, count(*)::integer
        from public.order_intents i where i.status = 'reconciliation_required'
          and coalesce(i.reconciling_since, i.created_at) < checked_at - interval '10 minutes'
        group by i.provider, i.environment
    ),
    closed as (
      update provider_operations.alerts a set resolved_at = checked_at
        where a.resolved_at is null and not exists (
          select 1 from active x where x.condition = a.condition and x.subject = a.subject
        )
        returning a.condition, a.subject, a.observed_count
    ),
    opened as (
      insert into provider_operations.alerts (condition, subject, observed_count, opened_at, last_seen_at)
        select condition, subject, observed_count, checked_at, checked_at from active
        on conflict (condition, subject) where resolved_at is null do update
          set last_seen_at = excluded.last_seen_at, observed_count = excluded.observed_count
        returning condition, subject, observed_count, opened_at
    )
    select 'opened' as state, condition, subject, observed_count from opened where opened_at = checked_at
    union all
    select 'resolved', condition, subject, observed_count from closed
  loop
    raise log 'provider_operations_alert % % % count=%', incident.state, incident.condition,
      incident.subject, incident.observed_count;
  end loop;
end $$;
revoke all on function provider_operations.check_alerts() from public, anon, authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    execute $job$select cron.schedule('provider-operations-check', '* * * * *',
      'select provider_operations.check_alerts()')$job$;
    execute $job$select cron.schedule('provider-operations-retention', '41 3 * * *',
      'delete from provider_operations.worker_runs where finished_at < now() - interval ''30 days'';
       delete from provider_operations.alerts where resolved_at < now() - interval ''90 days''')$job$;
  end if;
end $$;

-- SnapTrade's worker uses the service-role Data API. The RPC only appends
-- validated counters, so the private schema never needs to be exposed.
create function public.record_provider_worker_run(
  p_worker text, p_duration_ms integer, p_jobs integer, p_errors integer, p_failure_codes text[]
) returns void language sql security invoker set search_path = '' as $$
  insert into provider_operations.worker_runs (worker, duration_ms, jobs, errors, failure_codes)
    values (p_worker, p_duration_ms, p_jobs, p_errors, p_failure_codes);
$$;
revoke all on function public.record_provider_worker_run(text,integer,integer,integer,text[]) from public, anon, authenticated;
grant execute on function public.record_provider_worker_run(text,integer,integer,integer,text[]) to service_role;

-- Older events predate the latency sample. Keep them visible in the outcome
-- count and report how many events contributed to each percentile.
create index oms_events_submission_time_idx on public.oms_events (at desc)
  where kind in ('oms.submitted', 'oms.provider_rejected', 'oms.outcome_unknown', 'oms.submit_refused');

create view provider_operations.submit_summary_24h with (security_invoker = true) as
select i.provider, i.environment, count(*) as attempts,
  count(*) filter (where e.kind = 'oms.provider_rejected') as rejected,
  count(*) filter (where e.kind = 'oms.outcome_unknown') as unknown_outcomes,
  count(*) filter (where e.kind = 'oms.submit_refused') as refused,
  count(*) filter (where jsonb_typeof(e.detail->'submitLatencyMs') = 'number') as latency_samples,
  percentile_disc(0.95) within group (order by (e.detail->>'submitLatencyMs')::numeric)
    filter (where jsonb_typeof(e.detail->'submitLatencyMs') = 'number') as p95_latency_ms
from public.oms_events e join public.order_intents i on i.id = e.intent_id
where e.at >= now() - interval '24 hours'
  and e.kind in ('oms.submitted', 'oms.provider_rejected', 'oms.outcome_unknown', 'oms.submit_refused')
group by i.provider, i.environment;
revoke all on provider_operations.submit_summary_24h from public, anon, authenticated, service_role;
