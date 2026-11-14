\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;

select case when not has_schema_privilege('authenticated', 'provider_operations', 'USAGE')
  and not has_table_privilege('authenticated', 'provider_operations.alert_deliveries', 'SELECT')
  and not has_table_privilege('anon', 'provider_operations.alert_deliveries', 'SELECT')
  and not has_function_privilege('authenticated', 'provider_operations.invoke_alert_delivery()', 'EXECUTE')
  and not has_function_privilege('service_role', 'provider_operations.queue_alert_transition()', 'EXECUTE')
  and has_table_privilege('service_role', 'provider_operations.alert_deliveries', 'SELECT')
  and has_column_privilege('service_role', 'provider_operations.alert_deliveries', 'attempts', 'UPDATE')
  and not has_column_privilege('service_role', 'provider_operations.alert_deliveries', 'subject', 'UPDATE')
  and not has_table_privilege('service_role', 'provider_operations.alert_deliveries', 'INSERT')
  then 'ok private outbox and narrow worker grants' else 'FAIL outbox privacy' end;

select case when provider_operations.invoke_alert_delivery() = 'idle'
  then 'ok empty outbox schedules no request' else 'FAIL empty outbox invoked worker' end;

insert into provider_operations.alerts (condition, subject, observed_count, opened_at, last_seen_at)
values ('worker_missing', 'provider-maintenance', 0, now() - interval '1 minute', now()),
       ('worker_missing', 'unlisted.example.net', 0, now() - interval '1 minute', now());
update provider_operations.alerts set observed_count = 8, last_seen_at = now();
update provider_operations.alerts set resolved_at = now() where subject = 'provider-maintenance';
update provider_operations.alerts set resolved_at = now() + interval '1 minute' where subject = 'provider-maintenance';

select case when (select count(*) from provider_operations.alert_deliveries) = 2
  and exists (select from provider_operations.alert_deliveries where transition = 'opened'
    and subject = 'provider-maintenance' and occurred_at = now() - interval '1 minute' and observed_count = 0)
  and exists (select from provider_operations.alert_deliveries where transition = 'resolved'
    and subject = 'provider-maintenance' and occurred_at = now() and observed_count = 8)
  then 'ok one immutable aggregate snapshot per allowlisted transition' else 'FAIL alert transition snapshots' end;

update provider_operations.alert_deliveries set available_at = now() + interval '1 minute' where transition = 'opened';
update provider_operations.alert_deliveries set available_at = now() - interval '1 second' where transition = 'resolved';
select case when provider_operations.invoke_alert_delivery() = 'idle'
  then 'ok resolution waits for the opening delivery' else 'FAIL resolution invoked prematurely' end;

delete from provider_operations.alerts where subject = 'provider-maintenance';
select case when not exists (select from provider_operations.alert_deliveries)
  then 'ok incident retention also removes its outbox records' else 'FAIL alert retention' end;

rollback;
