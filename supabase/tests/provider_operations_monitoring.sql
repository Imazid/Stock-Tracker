\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;

set local role service_role;
select public.record_provider_worker_run('provider-maintenance', 30, 1, 1, array['provider_rate_limit']);
select public.record_provider_worker_run('provider-maintenance', 31, 1, 1, array['provider_unavailable']);
select public.record_provider_worker_run('provider-maintenance', 32, 1, 1, array['provider_unavailable']);
do $$
begin
  begin
    perform public.record_provider_worker_run('provider-maintenance', 10, 1, 1, array['raw provider error']);
    raise exception 'An unrecognised failure code was accepted';
  exception when check_violation then null;
  end;
end $$;
reset role;

set local role authenticated;
do $$
begin
  begin
    perform public.record_provider_worker_run('provider-maintenance', 10, 0, 0, '{}');
    raise exception 'A user wrote monitoring data';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from provider_operations.worker_runs;
    raise exception 'A user read monitoring data';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

update provider_operations.workers set monitored_since = now() - interval '6 minutes' where name = 'snaptrade-activity-sync';
insert into auth.users(id) values ('752bd777-4761-424f-8ed7-ab51d0750041');
insert into public.broker_connections(id,user_id,adapter_id,name,environment,permissions,provider_account_id)
values ('752bd777-4761-424f-8ed7-ab51d0750042','752bd777-4761-424f-8ed7-ab51d0750041',
  'alpaca','Monitor test','paper',array['read','trade'],'monitor-account');
insert into public.order_intents(id,user_id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,
  quantity,origin_kind,client_order_id,intent_hash,expires_at)
select id,'752bd777-4761-424f-8ed7-ab51d0750041','752bd777-4761-424f-8ed7-ab51d0750042','alpaca','paper','AAPL',
  'us_equity','buy','market','day',1,'manual','st-ops-' || client,repeat('a',64),now()+interval '20 minutes'
from (values ('752bd777-4761-424f-8ed7-ab51d0750043'::uuid,'submit'), ('752bd777-4761-424f-8ed7-ab51d0750044','reconcile'),
  ('752bd777-4761-424f-8ed7-ab51d0750045','recent')) as intents(id, client);
update public.order_intents set status='risk_checked' where connection_id='752bd777-4761-424f-8ed7-ab51d0750042';
update public.order_intents set status='awaiting_approval' where connection_id='752bd777-4761-424f-8ed7-ab51d0750042';
update public.order_intents set status='approved' where connection_id='752bd777-4761-424f-8ed7-ab51d0750042';
update public.order_intents set status='submitting' where connection_id='752bd777-4761-424f-8ed7-ab51d0750042';
update public.order_intents set provider_submitting_at=now()-interval '6 minutes' where id='752bd777-4761-424f-8ed7-ab51d0750043';
update public.order_intents set status='reconciliation_required' where id='752bd777-4761-424f-8ed7-ab51d0750044';
update public.order_intents set reconciling_since=now()-interval '11 minutes' where id='752bd777-4761-424f-8ed7-ab51d0750044';

select provider_operations.check_alerts();
select provider_operations.check_alerts();
select case when (select count(*) from provider_operations.alerts) = 4 and
  (select observed_count from provider_operations.alerts where condition='worker_errors') = 3 and
  (select observed_count from provider_operations.alerts where condition='order_submitting') = 1 and
  exists (select from provider_operations.alerts where condition='worker_missing' and subject='snaptrade-activity-sync') and
  exists (select from provider_operations.alerts where condition='order_reconciling' and subject='alpaca/paper')
  then 'ok stale orders, stalled workers and repeated failures open one incident each'
  else 'FAIL incident checks or deduplication' end;

select public.record_provider_worker_run('snaptrade-activity-sync', 10, 0, 0, '{}');
update provider_operations.worker_runs set finished_at=now()-interval '20 minutes' where errors>0;
select public.record_provider_worker_run('provider-maintenance', 10, 0, 0, '{}');
update public.order_intents set status='submitted' where id in
  ('752bd777-4761-424f-8ed7-ab51d0750043','752bd777-4761-424f-8ed7-ab51d0750044');
select provider_operations.check_alerts();
select case when (select count(*) from provider_operations.alerts where resolved_at is not null) = 4
  then 'ok incidents close when the observed conditions clear' else 'FAIL incident recovery' end;

insert into public.oms_events(user_id,intent_id,kind,detail)
values ('752bd777-4761-424f-8ed7-ab51d0750041','752bd777-4761-424f-8ed7-ab51d0750043','oms.submitted','{"submitLatencyMs":35}'),
  ('752bd777-4761-424f-8ed7-ab51d0750041','752bd777-4761-424f-8ed7-ab51d0750044','oms.outcome_unknown','{"submitLatencyMs":1200}'),
  ('752bd777-4761-424f-8ed7-ab51d0750041','752bd777-4761-424f-8ed7-ab51d0750045','oms.provider_rejected','{}');
select case when exists (select from provider_operations.submit_summary_24h where provider='alpaca' and environment='paper'
  and attempts=3 and rejected=1 and unknown_outcomes=1 and latency_samples=2 and p95_latency_ms=1200)
  then 'ok submit summary counts outcomes and excludes older events without latency samples' else 'FAIL submit summary' end;
rollback;
