begin;

do $$
begin
  if has_schema_privilege('authenticated', 'company_alert_operations', 'usage')
    or has_function_privilege('anon', 'company_alert_operations.invoke_due()', 'execute') then
    raise exception 'Clients must not invoke the alert scheduler';
  end if;
  if to_regclass('net.http_request_queue') is not null and
    (has_table_privilege('authenticated', 'net.http_request_queue', 'select')
    or has_table_privilege('anon', 'net.http_request_queue', 'select')) then
    raise exception 'Clients must not read scheduler credentials from pg_net';
  end if;
  if exists (select from pg_extension where extname = 'pg_cron') and
    exists (select from pg_extension where extname = 'pg_net') then
    if not exists (select from cron.job where jobname = 'company-alerts' and active and schedule = '* * * * *') then
      raise exception 'Alert scheduler is missing';
    end if;
  end if;
end;
$$;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000163', 'scheduled-company-alert@example.test');

insert into public.company_research_alerts (id, user_id, instrument_id, kind, threshold, currency, created_at)
values ('00000000-0000-0000-0000-000000000164', '00000000-0000-0000-0000-000000000163',
  'us:AAPL', 'price_above', 200, 'USD', now() - interval '2 hours');

set local role service_role;

do $$
declare
  claimed public.company_research_alerts;
  older timestamptz := now() - interval '40 minutes';
  first_seen timestamptz := now() - interval '30 minutes';
  later_seen timestamptz := now() - interval '20 minutes';
  final_seen timestamptz := now() - interval '10 minutes';
  events jsonb := jsonb_build_array(jsonb_build_object(
    'event_key','first', 'title','Price reached target', 'occurred_at', first_seen));
begin
  select * into claimed from public.claim_company_research_alerts(1);
  if not public.finish_company_research_alert(claimed.id, claimed.lease_token, true, null, events, first_seen) then
    raise exception 'The fresh observation should be stored';
  end if;
  if public.finish_company_research_alert(claimed.id, claimed.lease_token, true, null, events, first_seen) then
    raise exception 'A completed lease must be single-use';
  end if;

  update public.company_research_alerts set next_check_at = now();
  select * into claimed from public.claim_company_research_alerts(1);
  perform public.finish_company_research_alert(claimed.id, claimed.lease_token, false, null, '[]', older);
  if not (select last_condition and last_observed_at = first_seen from public.company_research_alerts where id = claimed.id) then
    raise exception 'An older observation must not re-arm the alert';
  end if;

  update public.company_research_alerts set next_check_at = now();
  select * into claimed from public.claim_company_research_alerts(1);
  perform public.finish_company_research_alert(claimed.id, claimed.lease_token, false, null, '[]', later_seen);
  if not (select not last_condition and last_observed_at = later_seen from public.company_research_alerts where id = claimed.id) then
    raise exception 'A fresh off-target observation should re-arm the alert';
  end if;

  update public.company_research_alerts set next_check_at = now();
  select * into claimed from public.claim_company_research_alerts(1);
  perform public.finish_company_research_alert(claimed.id, claimed.lease_token, true, null,
    jsonb_build_array(jsonb_build_object('event_key','second','title','Price crossed again','occurred_at', final_seen)), final_seen);
  if (select count(*) from public.company_research_alert_events where alert_id = claimed.id) <> 2 then
    raise exception 'Each new threshold crossing should be recorded once';
  end if;

  update public.company_research_alerts set next_check_at = now();
  select * into claimed from public.claim_company_research_alerts(1);
  update public.company_research_alerts set lease_until = now() - interval '1 second';
  if public.finish_company_research_alert(claimed.id, claimed.lease_token, false, null, '[]', now()) then
    raise exception 'An expired lease may not overwrite state';
  end if;
end;
$$;

rollback;

\echo ok  company alert scheduler is private and quote evaluations reject stale observations and leases
