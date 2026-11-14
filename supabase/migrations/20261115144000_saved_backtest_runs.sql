-- Personal, immutable snapshots of completed simulations. The values never feed order execution.
create table public.backtest_runs (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  saved_at timestamptz not null default now(),
  report jsonb not null,
  title text generated always as (report ->> 'title') stored not null,
  engine text generated always as (report ->> 'engine') stored not null,
  ran_at text generated always as (report ->> 'ranAt') stored not null,
  primary key (user_id, id),
  constraint backtest_run_snapshot check (
    (jsonb_typeof(report) = 'object'
    and report -> 'schemaVersion' = '1'::jsonb
    and char_length(title) between 1 and 200
    and char_length(engine) between 1 and 200
    and char_length(ran_at) between 20 and 30
    and jsonb_typeof(report -> 'inputs') = 'object'
    and jsonb_typeof(report #> '{inputs,spec}') = 'object'
    and jsonb_typeof(report #> '{inputs,config}') = 'object'
    and report #> '{inputs,config,allowFixtureData}' = 'false'::jsonb
    and report #> '{result,usedRealMarketData}' = 'true'::jsonb
    and report #> '{result,config}' = report #> '{inputs,config}'
    and jsonb_typeof(report #> '{result,overall}') = 'object'
    and jsonb_typeof(report #> '{result,trades}') = 'array'
    and jsonb_typeof(report #> '{result,equityCurve}') = 'array'
    and jsonb_typeof(report -> 'datasets') = 'array'
    and jsonb_typeof(report -> 'failures') = 'array') is true
  ),
  constraint backtest_run_payload_limit check (octet_length(report::text) <= 4500000)
);

create index backtest_runs_owner_latest_idx on public.backtest_runs (user_id, saved_at desc, id desc);
alter table public.backtest_runs enable row level security;
revoke all on public.backtest_runs from public, anon, authenticated;
grant select, delete on public.backtest_runs to authenticated;
grant insert (user_id, id, report) on public.backtest_runs to authenticated;
create policy "Owner reads backtest reports" on public.backtest_runs for select to authenticated using (user_id = (select auth.uid()));
create policy "Owner saves backtest reports" on public.backtest_runs for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Owner removes backtest reports" on public.backtest_runs for delete to authenticated using (user_id = (select auth.uid()));
