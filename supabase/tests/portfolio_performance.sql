\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users (id) values ('d281d805-11b1-4615-b88e-639e56de0001'), ('d281d805-11b1-4615-b88e-639e56de0002');
set local role authenticated;
set local request.jwt.claim.sub = 'd281d805-11b1-4615-b88e-639e56de0001';

insert into public.portfolio_performance_periods (starts_on, ends_on, opening_value_usd, closing_value_usd, external_flows)
values ('2026-01-01', '2026-01-31', 1000, 1700, '[{"date":"2026-01-16","kind":"deposit","amount":600}]'),
       ('2026-01-31', '2026-02-28', 1700, 1500, '[{"date":"2026-02-28","kind":"withdrawal","amount":200}]'),
       ('2026-03-01', '2026-03-31', 0, 100, '[{"date":"2026-03-31","kind":"deposit","amount":100}]');

select case when deposits_usd = 600 and withdrawals_usd = 0 and investment_change_usd = 100 and return_pct = 7.69230769
  then 'ok weighted deposit and investment change' else 'FAIL weighted deposit' end
  from public.portfolio_performance_results where starts_on = '2026-01-01';
select case when withdrawals_usd = 200 and investment_change_usd = 0 and return_pct = 0
  then 'ok closing-day withdrawal and adjacent intervals' else 'FAIL withdrawal' end
  from public.portfolio_performance_results where starts_on = '2026-01-31';
select case when investment_change_usd = 0 and return_pct is null
  then 'ok no denominator produces unavailable return' else 'FAIL zero capital' end
  from public.portfolio_performance_results where starts_on = '2026-03-01';
select case when time_weighted_return_pct is null and abs(money_weighted_return_pct - 7.72547104) < 0.000001
  then 'ok missing transfer valuation preserves the dated money-weighted result' else 'FAIL incomplete transfer-day values' end
  from public.portfolio_performance_results where starts_on = '2026-01-01';
update public.portfolio_performance_periods set transfer_values_usd = '{"2026-01-16":1650}' where starts_on = '2026-01-01';
select case when time_weighted_return_pct = 8.18181818 and transfer_values_usd = '{"2026-01-16":1650}'
  then 'ok link subperiods around the dated deposit' else 'FAIL time-weighted return' end
  from public.portfolio_performance_results where starts_on = '2026-01-01';
select case when time_weighted_return_pct = 0 and money_weighted_return_pct = 0
  then 'ok use closing value after a closing-day withdrawal' else 'FAIL closing-date transfer treatment' end
  from public.portfolio_performance_results where starts_on = '2026-01-31';
select case when periods = 1 and starts_on = '2026-03-01' and return_pct is null
  then 'ok gap starts a new chain' else 'FAIL chained gap' end from public.portfolio_performance_summary;
delete from public.portfolio_performance_periods where starts_on = '2026-03-01';
select case when periods = 2 and deposits_usd = 600 and withdrawals_usd = 200
  and investment_change_usd = 100 and return_pct = 7.69230769 and time_weighted_return_pct = 8.18181818
  and abs(money_weighted_return_pct - 6.93987772) < 0.000001
  then 'ok link adjacent returns with matching valuations' else 'FAIL chained return' end
  from public.portfolio_performance_summary;
update public.portfolio_performance_periods set opening_value_usd = 1600 where starts_on = '2026-01-31';
select case when periods = 1 and starts_on = '2026-01-31'
  then 'ok changed boundary value starts a new chain' else 'FAIL chained value mismatch' end
  from public.portfolio_performance_summary;

do $$
begin
  begin
    insert into public.portfolio_performance_periods (starts_on, ends_on, opening_value_usd, closing_value_usd)
      values ('2026-01-15', '2026-02-15', 100, 200);
    raise exception 'Overlapping intervals were accepted';
  exception when exclusion_violation then raise notice 'Overlapping intervals rejected';
  end;
  begin
    update public.portfolio_performance_periods set external_flows = '[{"date":"2026-02-30","kind":"deposit","amount":100}]';
    raise exception 'Invalid flow was accepted';
  exception when check_violation then raise notice 'Invalid flow rejected';
  end;
  begin
    update public.portfolio_performance_periods set transfer_values_usd = '{"2026-01-12":1100}' where starts_on = '2026-01-01';
    raise exception 'Unrelated valuation accepted';
  exception when check_violation then raise notice 'Unrelated transfer date rejected';
  end;
  begin
    update public.portfolio_performance_periods set user_id = 'd281d805-11b1-4615-b88e-639e56de0002';
    raise exception 'Period ownership was changed';
  exception when insufficient_privilege then raise notice 'Ownership reassignment rejected';
  end;
end $$;

set local request.jwt.claim.sub = 'd281d805-11b1-4615-b88e-639e56de0002';
select case when count(*) = 0 then 'ok second user cannot read results' else 'FAIL second user read results' end
  from public.portfolio_performance_results;
select case when count(*) = 0 then 'ok second user cannot read summary' else 'FAIL second user read summary' end
  from public.portfolio_performance_summary;
insert into public.portfolio_performance_periods (starts_on, ends_on, opening_value_usd, closing_value_usd)
values ('2026-01-01', '2026-01-31', 100, 110);
select case when count(*) = 1 and min(return_pct) = 10 and min(time_weighted_return_pct) = 10 and min(money_weighted_return_pct) = 10 then 'ok second user has independent periods' else 'FAIL user scoping' end
  from public.portfolio_performance_results;
insert into public.portfolio_performance_periods
  (starts_on, ends_on, opening_value_usd, closing_value_usd, external_flows, transfer_values_usd)
values ('2027-01-01', '2027-01-31', 0, 100, '[{"date":"2027-01-31","kind":"deposit","amount":100}]', '{}'),
       ('2027-01-31', '2027-02-28', 100, 110, '[]', '{}');
select case when periods = 2 and time_weighted_return_pct = 10 and money_weighted_return_pct is not null
  then 'ok start a continuous chain at initial funding' else 'FAIL initial funding chain' end from public.portfolio_performance_summary;
insert into public.portfolio_performance_periods
  (starts_on, ends_on, opening_value_usd, closing_value_usd, external_flows, transfer_values_usd)
values ('2028-01-01', '2028-01-31', 100, 180, '[{"date":"2028-01-16","kind":"deposit","amount":50},{"date":"2028-01-16","kind":"withdrawal","amount":20}]', '{"2028-01-16":150}');
set local datestyle to 'SQL, DMY';
select case when time_weighted_return_pct = 44
  then 'ok same-day transfers use one valuation in any date style' else 'FAIL same-day transfers' end
  from public.portfolio_performance_results where starts_on = '2028-01-01';
set local datestyle to 'ISO, MDY';
update public.portfolio_performance_periods set external_flows = '[]'
where starts_on = '2028-01-01';
select case when transfer_values_usd = '{}' and time_weighted_return_pct = 80
  then 'ok older clients can remove transfers and clear their valuations' else 'FAIL stale transfer valuations' end
  from public.portfolio_performance_results where starts_on = '2028-01-01';
select case when portfolio_metrics.money_weighted_return(
  '2026-01-01', '2026-01-31', 100, 0,
  '[{"date":"2026-01-11","kind":"withdrawal","amount":350},{"date":"2026-01-21","kind":"deposit","amount":350},{"date":"2026-01-31","kind":"withdrawal","amount":100}]'
) is null then 'ok ambiguous cash flows have no displayed IRR' else 'FAIL ambiguous money-weighted return' end;
select case when portfolio_metrics.money_weighted_return(
  '2026-01-01', '2026-01-31', 100, 160,
  '[{"date":"2026-01-11","kind":"withdrawal","amount":10},{"date":"2026-01-21","kind":"deposit","amount":60}]'
) = 8.86015229 then 'ok certify a unique IRR with alternating cash flow signs' else 'FAIL alternating but unique money-weighted return' end;
reset role;
select case when not has_table_privilege('anon', 'public.portfolio_performance_results', 'SELECT')
  and not has_table_privilege('anon', 'public.portfolio_performance_periods', 'INSERT')
  then 'ok anonymous access revoked' else 'FAIL anonymous access' end;
rollback;
