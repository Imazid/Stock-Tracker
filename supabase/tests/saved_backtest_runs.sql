\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users(id) values ('e1510000-0000-4000-9000-000000000001'), ('e1510000-0000-4000-9000-000000000002');
set local role authenticated;
do $$
declare
  owner uuid := 'e1510000-0000-4000-9000-000000000001';
  stranger uuid := 'e1510000-0000-4000-9000-000000000002';
  run uuid := 'e1510000-0000-4000-9000-000000000003';
  snapshot jsonb := '{"schemaVersion":1,"title":"Tested strategy","engine":"Simulation","ranAt":"2026-11-14T12:00:00.000Z","inputs":{"spec":{},"config":{"allowFixtureData":false}},"result":{"config":{"allowFixtureData":false},"usedRealMarketData":true,"overall":{},"trades":[],"equityCurve":[]},"datasets":[],"failures":[]}';
begin
  perform set_config('request.jwt.claim.sub', owner::text, true);
  insert into public.backtest_runs(user_id, id, report) values (owner, run, snapshot);
  insert into public.backtest_runs(user_id, id, report) values (owner, run, snapshot || '{"title":"Do not overwrite"}') on conflict (user_id, id) do nothing;
  assert (select report from public.backtest_runs where id = run) = snapshot, 'Retry changed the report';
  assert (select title from public.backtest_runs where id = run) = 'Tested strategy', 'List title did not come from the snapshot';

  begin
    update public.backtest_runs set report = snapshot where id = run;
    raise exception 'Authenticated user updated a historical report';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.backtest_runs (user_id, id, report) values (stranger, gen_random_uuid(), snapshot);
    raise exception 'A client chose another owner';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.backtest_runs(user_id, id, report) values (owner, gen_random_uuid(), jsonb_set(snapshot,'{result,usedRealMarketData}','false'));
    raise exception 'Storage accepted a fixture-only report';
  exception when check_violation then null;
  end;
  begin
    insert into public.backtest_runs(user_id, id, report) values (owner, gen_random_uuid(), snapshot - 'datasets');
    raise exception 'Storage accepted a report without source references';
  exception when check_violation then null;
  end;
  perform set_config('request.jwt.claim.sub', stranger::text, true);
  assert not exists (select from public.backtest_runs where id = run), 'Other user read private report';
  delete from public.backtest_runs where id = run;
  perform set_config('request.jwt.claim.sub', owner::text, true);
  assert exists (select from public.backtest_runs where id = run), 'Other user removed private report';
  delete from public.backtest_runs where id = run;
  assert not exists (select from public.backtest_runs where id = run), 'Owner could not remove a report';
  assert not has_table_privilege('anon','public.backtest_runs','select'), 'Anonymous access was granted';
end $$;
select 'ok   saved backtest snapshots are immutable, owner-scoped and retry-safe';
rollback;
