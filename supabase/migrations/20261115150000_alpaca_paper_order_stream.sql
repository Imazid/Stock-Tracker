-- Lease each connection independently of the existing REST reconciliation worker.
create table provider_operations.alpaca_stream_leases (
  connection_id uuid primary key references public.broker_connections(id) on delete cascade,
  token uuid not null,
  last_started_at timestamptz not null,
  available_at timestamptz not null
);
alter table provider_operations.alpaca_stream_leases enable row level security;
revoke all on provider_operations.alpaca_stream_leases from public, anon, authenticated;
grant select, insert, update on provider_operations.alpaca_stream_leases to service_role;

create index order_intents_alpaca_stream_idx on public.order_intents (connection_id)
  where provider = 'alpaca' and environment = 'paper'
    and status in ('submitted', 'partially_filled', 'reconciliation_required');

insert into provider_operations.workers (name) values ('alpaca-paper-order-stream');

-- The same secret authenticates both modes of the provider-maintenance endpoint.
-- The regular reconciliation job keeps its own timeout, counters and schedule.
create function provider_operations.invoke_alpaca_paper_stream() returns text
language plpgsql security invoker set search_path = '' as $$
declare
  worker_url text;
  worker_secret text;
begin
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
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 58000)'
    using worker_url, jsonb_build_object('content-type', 'application/json',
      'x-scheduler-secret', worker_secret, 'x-provider-maintenance-mode', 'alpaca-paper-stream'), '{}'::jsonb;
  return 'requested';
end $$;
revoke all on function provider_operations.invoke_alpaca_paper_stream() from public, anon, authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $job$select cron.schedule('alpaca-paper-order-stream', '* * * * *',
      'select provider_operations.invoke_alpaca_paper_stream()')$job$;
  end if;
end $$;
