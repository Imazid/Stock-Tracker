begin;

do $$
begin
  if has_table_privilege('anon', 'public.research_instruments', 'SELECT')
     or has_table_privilege('authenticated', 'public.research_snapshots', 'SELECT') then
    raise exception 'Research tables must be server-only';
  end if;
  if (select count(*) from pg_class where oid in ('public.research_instruments'::regclass, 'public.research_snapshots'::regclass)
      and relrowsecurity) <> 2 then
    raise exception 'Both research tables must enable RLS';
  end if;
end;
$$;

set local role service_role;
insert into public.research_instruments values
  ('us:TEST', 'us', 'TEST', 'Test filer', 'NYSE', '0000000001', 'https://www.sec.gov/', now());
insert into public.research_snapshots values
  ('us:TEST', 'sec-companyfacts', '2026-11-12T00:00:00Z', 'https://data.sec.gov/', '[]'),
  ('us:TEST', 'sec-companyfacts', '2026-11-13T00:00:00Z', 'https://data.sec.gov/', '[]');

do $$
begin
  if (select retrieved_at from public.research_snapshots where instrument_id = 'us:TEST'
      order by retrieved_at desc limit 1) <> '2026-11-13T00:00:00Z' then
    raise exception 'The most recent version should be readable by the research server';
  end if;
end;
$$;

reset role;
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000101', 'company-research-a@example.test'),
  ('00000000-0000-0000-0000-000000000102', 'company-research-b@example.test');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000101', true);
insert into public.company_research_alerts (user_id, instrument_id, kind)
values ('00000000-0000-0000-0000-000000000101', 'us:AAPL', 'filing');
do $$
begin
  if (select count(*) from public.company_research_alerts) <> 1 then
    raise exception 'The owner should see the alert';
  end if;
  if has_function_privilege(current_user, 'public.claim_company_research_alerts(integer)', 'execute') then
    raise exception 'Users must not claim worker leases';
  end if;
  begin
    update public.company_research_alerts set last_problem = 'user-controlled';
    raise exception 'Users must not update worker fields';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.company_research_alerts (user_id, instrument_id, kind)
    values ('00000000-0000-0000-0000-000000000102', 'us:AAPL', 'filing');
    raise exception 'Users must not create rules for others';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
set local role service_role;
do $$
declare
  claimed public.company_research_alerts;
  sample_events jsonb := '[{"event_key":"filing1","title":"A new filing","url":"https://www.sec.gov/","occurred_at":"2026-11-13T00:00:00Z"}]';
begin
  select * into claimed from public.claim_company_research_alerts(5);
  if claimed.id is null or claimed.lease_token is null then
    raise exception 'The worker should lease the due alert';
  end if;
  if exists (select 1 from public.claim_company_research_alerts(5)) then
    raise exception 'A concurrent worker must not claim the same alert';
  end if;
  if public.finish_company_research_alert(claimed.id, gen_random_uuid(), null, null, sample_events) then
    raise exception 'An invalid lease must not finish an alert';
  end if;
  if not public.finish_company_research_alert(claimed.id, claimed.lease_token, null, null, sample_events) then
    raise exception 'The active lease should finish the alert';
  end if;
  update public.company_research_alerts set next_check_at = now() where id = claimed.id;
  select * into claimed from public.claim_company_research_alerts(5);
  perform public.finish_company_research_alert(claimed.id, claimed.lease_token, null, null, sample_events);
  if (select count(*) from public.company_research_alert_events where alert_id = claimed.id) <> 1 then
    raise exception 'Repeated provider events should be deduplicated';
  end if;
end;
$$;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000102', true);
do $$
begin
  if exists (select 1 from public.company_research_alerts) or exists (select 1 from public.company_research_alert_events) then
    raise exception 'A second user must not see rules or triggers';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000101', true);
do $$
begin
  if (select count(*) from public.company_research_alert_events) <> 1 then
    raise exception 'The alert owner should see the trigger';
  end if;
end;
$$;
delete from public.company_research_alerts where kind = 'filing';
do $$
begin
  if exists (select 1 from public.company_research_alert_events) then
    raise exception 'Deleting an alert must remove its trigger history';
  end if;
end;
$$;

rollback;

\echo ok  company intelligence storage, alert access, leases and deduplication
