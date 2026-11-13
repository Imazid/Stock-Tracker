-- Durable queues for read-only background provider maintenance.
alter table public.order_intents add column provider_check_due_at timestamptz not null default now();
alter table public.order_intents add column provider_submitting_at timestamptz;
alter table public.broker_connections add column fill_sync_due_at timestamptz not null default now();
alter table public.broker_connections add column fill_sync_lease_until timestamptz;
alter table public.provider_sync_cursors add column window_start timestamptz, add column window_end timestamptz;

-- An old fills cursor is a page token without time bounds. Start a fresh, idempotent scan.
delete from public.provider_sync_cursors where stream = 'fills';

update public.order_intents set provider_submitting_at = updated_at where status = 'submitting';
create function public.stamp_provider_submission() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  new.provider_submitting_at := clock_timestamp();
  return new;
end $$;
revoke all on function public.stamp_provider_submission() from public, anon, authenticated;
create trigger stamp_provider_submission before update of status on public.order_intents
  for each row when (new.status = 'submitting' and old.status is distinct from new.status)
  execute function public.stamp_provider_submission();

create index order_intents_provider_check_idx on public.order_intents (provider_check_due_at, id)
  where status in ('submitting', 'submitted', 'partially_filled', 'reconciliation_required');
create index broker_connections_fill_sync_idx on public.broker_connections (fill_sync_due_at, id)
  where status = 'active' and adapter_id in ('alpaca', 'coinbase');

-- Called by the cron owner. Vault stores a dedicated worker URL and scheduler secret.
create function public.invoke_provider_maintenance() returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net')
     or pg_catalog.to_regclass('vault.decrypted_secrets') is null then
    return 'skipped: pg_net or Vault is not installed';
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_url using 'provider_maintenance_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_secret using 'provider_maintenance_secret';
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return 'skipped: worker address or secret missing';
  end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 55000)'
    using v_url, jsonb_build_object('content-type', 'application/json', 'x-scheduler-secret', v_secret), '{}'::jsonb;
  return 'requested';
end $$;
revoke all on function public.invoke_provider_maintenance() from public, anon, authenticated;
grant execute on function public.invoke_provider_maintenance() to service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
    and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $job$select cron.schedule('provider-maintenance', '* * * * *', 'select public.invoke_provider_maintenance()')$job$;
  end if;
end $$;
