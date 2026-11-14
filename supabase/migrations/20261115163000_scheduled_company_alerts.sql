-- Quote-based rules advance only on a newer source observation.
alter table public.company_research_alerts add column last_observed_at timestamptz;

drop function public.finish_company_research_alert(uuid, uuid, boolean, text, jsonb);

create function public.finish_company_research_alert(
  target_id uuid, token uuid, observed_condition boolean, problem text, new_events jsonb,
  observed_at timestamptz default null
) returns boolean language plpgsql security invoker set search_path = ''
as $$
declare
  owner_id uuid;
  alert_kind text;
  created timestamptz;
  previous_observation timestamptz;
  advances boolean;
begin
  select user_id, kind, created_at, last_observed_at
    into owner_id, alert_kind, created, previous_observation
  from public.company_research_alerts
  where id = target_id and lease_token = token and lease_until > clock_timestamp()
  for update;
  if owner_id is null then return false; end if;

  advances := observed_at is not null and observed_at >= created and observed_at <= clock_timestamp()
    and (previous_observation is null or observed_at > previous_observation)
    and problem is null and observed_condition is not null;
  update public.company_research_alerts
  set lease_token = null, lease_until = null,
      last_checked_at = case when problem is null then now() else last_checked_at end,
      last_condition = case when advances then observed_condition else last_condition end,
      last_observed_at = case when advances then observed_at else last_observed_at end,
      last_problem = problem, next_check_at = now() + interval '10 minutes'
  where id = target_id;

  if advances or alert_kind in ('filing', 'insider', 'news') then
    insert into public.company_research_alert_events (alert_id, user_id, event_key, title, url, occurred_at)
    select target_id, owner_id, event_key, title, url, event.occurred_at
    from jsonb_to_recordset(new_events) as event(event_key text, title text, url text, occurred_at timestamptz)
    where event.occurred_at between created and clock_timestamp()
    on conflict (alert_id, event_key) do nothing;
  end if;
  return true;
end;
$$;

revoke all on function public.finish_company_research_alert(uuid, uuid, boolean, text, jsonb, timestamptz)
  from public, anon, authenticated;
grant execute on function public.finish_company_research_alert(uuid, uuid, boolean, text, jsonb, timestamptz) to service_role;

create schema company_alert_operations;
revoke all on schema company_alert_operations from public, anon, authenticated;

create function company_alert_operations.invoke_due()
returns bigint language plpgsql security invoker set search_path = ''
as $$
declare
  endpoint text;
  scheduler_secret text;
  deployment_bypass text;
  request_headers jsonb;
  request_id bigint;
begin
  if not exists (select from pg_catalog.pg_extension where extname = 'pg_net')
    or pg_catalog.to_regclass('vault.decrypted_secrets') is null then
    return null;
  end if;

  if not exists (
    select from public.company_research_alerts
    where next_check_at <= now() and (lease_until is null or lease_until <= now())
  ) then
    return null;
  end if;

  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into endpoint using 'company_alert_worker_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into scheduler_secret using 'company_alert_scheduler_secret';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into deployment_bypass using 'company_alert_deployment_bypass';

  if coalesce(endpoint, '') !~ '^https://[a-zA-Z0-9.-]+/api/cron/company-alerts$'
    or length(coalesce(scheduler_secret, '')) < 32 then
    return null;
  end if;
  request_headers := jsonb_build_object('authorization', 'Bearer ' || scheduler_secret);
  if coalesce(deployment_bypass, '') <> '' then
    request_headers := request_headers || jsonb_build_object('x-vercel-protection-bypass', deployment_bypass);
  end if;
  execute 'select net.http_get(url := $1, headers := $2, timeout_milliseconds := 55000)'
    into request_id using endpoint, request_headers;
  return request_id;
end;
$$;
revoke all on function company_alert_operations.invoke_due() from public, anon, authenticated;

do $$
begin
  -- HTTP requests can carry scheduler credentials while queued. These tables
  -- are only used by infrastructure and have no browser callers.
  if pg_catalog.to_regclass('net.http_request_queue') is not null then
    execute 'revoke all on net.http_request_queue from public, anon, authenticated';
    execute 'revoke all on net._http_response from public, anon, authenticated';
  end if;
  if exists (select from pg_catalog.pg_extension where extname = 'pg_cron')
    and exists (select from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $cron$select cron.schedule('company-alerts', '* * * * *', 'select company_alert_operations.invoke_due()')$cron$;
  end if;
end;
$$;
