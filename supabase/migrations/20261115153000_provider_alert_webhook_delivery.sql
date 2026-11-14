create table provider_operations.alert_deliveries (
  alert_id bigint not null references provider_operations.alerts (id) on delete cascade,
  transition text not null check (transition in ('opened', 'resolved')),
  occurred_at timestamptz not null,
  condition text not null check (condition in ('worker_missing', 'worker_errors', 'order_submitting', 'order_reconciling')),
  subject text not null check (subject in (
    'provider-maintenance', 'snaptrade-activity-sync', 'alpaca-paper-order-stream',
    'alpaca/paper', 'alpaca/sandbox', 'alpaca/live', 'coinbase/paper', 'coinbase/sandbox', 'coinbase/live'
  )),
  observed_count integer not null check (observed_count >= 0),
  available_at timestamptz not null default clock_timestamp(),
  lease_token uuid,
  attempts integer not null default 0 check (attempts >= 0),
  delivered_at timestamptz,
  failed_at timestamptz,
  last_failure text check (last_failure in ('network', 'http')),
  last_http_status integer check (last_http_status between 100 and 599),
  primary key (alert_id, transition),
  check (delivered_at is null or failed_at is null),
  check (lease_token is null or (delivered_at is null and failed_at is null))
);

alter table provider_operations.alert_deliveries enable row level security;
revoke all on provider_operations.alert_deliveries from public, anon, authenticated, service_role;
grant select on provider_operations.alert_deliveries to service_role;
grant update (available_at, lease_token, attempts, delivered_at, failed_at, last_failure, last_http_status)
  on provider_operations.alert_deliveries to service_role;

create index provider_alert_deliveries_due on provider_operations.alert_deliveries (available_at, alert_id, transition)
  where delivered_at is null and failed_at is null;

-- Match the detector's own incident transaction so failed checks leave no alert to send.
create function provider_operations.queue_alert_transition() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.subject not in (
    'provider-maintenance', 'snaptrade-activity-sync', 'alpaca-paper-order-stream',
    'alpaca/paper', 'alpaca/sandbox', 'alpaca/live', 'coinbase/paper', 'coinbase/sandbox', 'coinbase/live'
  ) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    insert into provider_operations.alert_deliveries (alert_id, transition, occurred_at, condition, subject, observed_count)
    values (new.id, 'opened', new.opened_at, new.condition, new.subject, new.observed_count)
    on conflict (alert_id, transition) do nothing;
  elsif old.resolved_at is null and new.resolved_at is not null then
    if exists (select 1 from provider_operations.alert_deliveries where alert_id = new.id and transition = 'opened') then
      insert into provider_operations.alert_deliveries (alert_id, transition, occurred_at, condition, subject, observed_count)
      values (new.id, 'resolved', new.resolved_at, new.condition, new.subject, new.observed_count)
      on conflict (alert_id, transition) do nothing;
    end if;
  end if;
  return new;
end $$;
revoke all on function provider_operations.queue_alert_transition() from public, anon, authenticated, service_role;

create trigger queue_provider_alert_transition after insert or update of resolved_at
on provider_operations.alerts for each row execute function provider_operations.queue_alert_transition();

-- Page on currently open incidents when an operator first configures delivery. Closed historical
-- incidents stay in the alert log.
insert into provider_operations.alert_deliveries (alert_id, transition, occurred_at, condition, subject, observed_count)
select id, 'opened', opened_at, condition, subject, observed_count from provider_operations.alerts
where resolved_at is null and subject in (
  'provider-maintenance', 'snaptrade-activity-sync', 'alpaca-paper-order-stream',
  'alpaca/paper', 'alpaca/sandbox', 'alpaca/live', 'coinbase/paper', 'coinbase/sandbox', 'coinbase/live'
);

create function provider_operations.invoke_alert_delivery() returns text
language plpgsql security invoker set search_path = '' as $$
declare
  worker_url text;
  worker_secret text;
begin
  if not exists (
    select 1 from provider_operations.alert_deliveries delivery
    where delivery.delivered_at is null and delivery.failed_at is null and delivery.available_at <= now()
      and (delivery.transition = 'opened' or exists (
        select 1 from provider_operations.alert_deliveries opened
        where opened.alert_id = delivery.alert_id and opened.transition = 'opened' and opened.delivered_at is not null
      ))
  ) then
    return 'idle';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net')
     or pg_catalog.to_regclass('vault.decrypted_secrets') is null then
    return 'skipped: pg_net or Vault is not installed';
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_url using 'provider_maintenance_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_secret using 'provider_maintenance_secret';
  if coalesce(worker_url, '') = '' or coalesce(worker_secret, '') = '' then
    return 'skipped: worker address or secret missing';
  end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 20000)'
    using worker_url, jsonb_build_object('content-type', 'application/json',
      'x-scheduler-secret', worker_secret, 'x-provider-maintenance-mode', 'alert-delivery'), '{}'::jsonb;
  return 'requested';
end $$;
revoke all on function provider_operations.invoke_alert_delivery() from public, anon, authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $job$select cron.schedule('provider-alert-delivery', '* * * * *',
      'select provider_operations.invoke_alert_delivery()')$job$;
  end if;
end $$;
