create table portfolio_metrics.snaptrade_activity_jobs (
  credential_id uuid primary key references public.secure_credentials(id) on delete cascade,
  due_at timestamptz not null default now(),
  lease_id uuid,
  lease_until timestamptz,
  snapshot_id uuid,
  snapshot_from date,
  snapshot_to date,
  synced_at timestamptz,
  accounts uuid[] not null default '{}',
  omitted jsonb not null default '{}',
  pending_id uuid,
  pending_from date,
  pending_to date,
  pending_accounts uuid[] not null default '{}',
  pending_omitted jsonb not null default '{}',
  account_index integer not null default 1,
  page_offset integer not null default 0
);
create index snaptrade_activity_jobs_due on portfolio_metrics.snaptrade_activity_jobs(due_at, credential_id);

create table portfolio_metrics.snaptrade_activities (
  credential_id uuid not null references portfolio_metrics.snaptrade_activity_jobs(credential_id) on delete cascade,
  snapshot_id uuid not null,
  account_id uuid not null,
  activity_id text not null,
  activity_date date not null,
  activity jsonb not null,
  primary key (credential_id, snapshot_id, account_id, activity_id)
);
create index snaptrade_activities_range on portfolio_metrics.snaptrade_activities
  (credential_id, snapshot_id, account_id, activity_date desc, activity_id);

alter table portfolio_metrics.snaptrade_activity_jobs enable row level security;
alter table portfolio_metrics.snaptrade_activities enable row level security;
revoke all on portfolio_metrics.snaptrade_activity_jobs, portfolio_metrics.snaptrade_activities from public, anon, authenticated;
grant select, insert, update, delete on portfolio_metrics.snaptrade_activity_jobs, portfolio_metrics.snaptrade_activities to service_role;

create function portfolio_metrics.track_snaptrade_activity_credentials()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.purpose = 'snaptrade_user' and new.provider = 'snaptrade' then
    if new.revoked_at is null then
      insert into portfolio_metrics.snaptrade_activity_jobs(credential_id) values (new.id) on conflict do nothing;
    else
      delete from portfolio_metrics.snaptrade_activity_jobs where credential_id = new.id;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function portfolio_metrics.track_snaptrade_activity_credentials() from public, anon, authenticated;
create trigger track_snaptrade_activity_credentials
after insert or update of revoked_at on public.secure_credentials
for each row execute function portfolio_metrics.track_snaptrade_activity_credentials();

insert into portfolio_metrics.snaptrade_activity_jobs(credential_id)
select id from public.secure_credentials
where purpose = 'snaptrade_user' and provider = 'snaptrade' and revoked_at is null;

create function public.claim_snaptrade_activity_jobs()
returns table (credential_id uuid, user_id uuid, lease_id uuid, pending_id uuid, start_date date,
  end_date date, account_id uuid, page_offset integer)
language sql security invoker set search_path = '' as $$
  with due as (
    select j.credential_id, c.user_id
    from portfolio_metrics.snaptrade_activity_jobs j
    join public.secure_credentials c on c.id = j.credential_id and c.revoked_at is null
    where j.due_at <= now() and (j.lease_until is null or j.lease_until <= now())
    order by j.due_at, j.credential_id limit 3 for update of j skip locked
  )
  update portfolio_metrics.snaptrade_activity_jobs j
  set lease_id = gen_random_uuid(), lease_until = now() + interval '90 seconds',
    pending_id = case when j.pending_to < (now() at time zone 'UTC')::date - 1 then null else j.pending_id end
  from due where j.credential_id = due.credential_id
  returning j.credential_id, due.user_id, j.lease_id, j.pending_id,
    j.pending_from, j.pending_to, j.pending_accounts[j.account_index], j.page_offset;
$$;

create function public.advance_snaptrade_activity_job(
  p_credential uuid, p_lease uuid, p_accounts uuid[] default null, p_rows jsonb default null,
  p_omitted integer default 0, p_next_offset integer default null
) returns boolean language plpgsql security invoker set search_path = '' as $$
declare
  j portfolio_metrics.snaptrade_activity_jobs%rowtype;
  v_day date := (now() at time zone 'UTC')::date;
  v_account uuid;
begin
  perform 1 from public.secure_credentials c where c.id = p_credential and c.revoked_at is null for share;
  if not found then return false; end if;
  select * into j from portfolio_metrics.snaptrade_activity_jobs
  where credential_id = p_credential and lease_id = p_lease and lease_until > now() for update;
  if not found then return false; end if;

  if j.pending_id is null then
    if p_accounts is null then raise exception 'Missing account list'; end if;
    delete from portfolio_metrics.snaptrade_activities
    where credential_id = p_credential and snapshot_id is distinct from j.snapshot_id;
    j.pending_id := gen_random_uuid();
    j.pending_from := v_day - 89;
    j.pending_to := v_day;
    j.pending_accounts := p_accounts;
    j.pending_omitted := '{}'::jsonb;
    j.account_index := 1;
    j.page_offset := 0;
  else
    if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 50
      or p_omitted < 0 or (p_next_offset is not null and p_next_offset <= j.page_offset)
    then raise exception 'Invalid activity page'; end if;
    v_account := j.pending_accounts[j.account_index];
    insert into portfolio_metrics.snaptrade_activities (credential_id,snapshot_id,account_id,activity_id,activity_date,activity)
    select p_credential, j.pending_id, v_account, row->>'id', (row->>'date')::date, row
    from jsonb_array_elements(p_rows) row
    where (row->>'date')::date between j.pending_from and j.pending_to
    on conflict (credential_id,snapshot_id,account_id,activity_id)
    do update set activity_date = excluded.activity_date, activity = excluded.activity;
    j.pending_omitted := jsonb_set(j.pending_omitted, array[v_account::text],
      to_jsonb(coalesce((j.pending_omitted->>v_account::text)::integer,0) + p_omitted));
    j.page_offset := coalesce(p_next_offset,0);
    if p_next_offset is null then j.account_index := j.account_index + 1; end if;
  end if;

  if j.account_index > cardinality(j.pending_accounts) then
    delete from portfolio_metrics.snaptrade_activities where credential_id = p_credential and snapshot_id <> j.pending_id;
    update portfolio_metrics.snaptrade_activity_jobs
    set snapshot_id = j.pending_id, snapshot_from = j.pending_from, snapshot_to = j.pending_to,
      synced_at = now(), accounts = j.pending_accounts, omitted = j.pending_omitted, pending_id = null,
      pending_from = null, pending_to = null, pending_accounts = '{}', pending_omitted = '{}',
      due_at = now() + interval '1 day', lease_id = null, lease_until = null
    where credential_id = p_credential;
  else
    update portfolio_metrics.snaptrade_activity_jobs
    set pending_id = j.pending_id, pending_from = j.pending_from, pending_to = j.pending_to,
      pending_accounts = j.pending_accounts, pending_omitted = j.pending_omitted,
      account_index = j.account_index, page_offset = j.page_offset,
      due_at = now(), lease_id = null, lease_until = null where credential_id = p_credential;
  end if;
  return true;
end;
$$;

create function public.defer_snaptrade_activity_job(p_credential uuid, p_lease uuid, p_reset boolean)
returns void language plpgsql security invoker set search_path = '' as $$
declare
  staged uuid;
begin
  update portfolio_metrics.snaptrade_activity_jobs
  set due_at = now() + case when p_reset then interval '1 hour' else interval '10 minutes' end,
    lease_id = null, lease_until = null, pending_id = case when p_reset then null else pending_id end
  where credential_id = p_credential and lease_id = p_lease
  returning snapshot_id into staged;
  if found and p_reset then
    delete from portfolio_metrics.snaptrade_activities
    where credential_id = p_credential and snapshot_id is distinct from staged;
  end if;
end;
$$;

create function public.read_snaptrade_activity_cache(
  p_user uuid, p_account uuid, p_start date, p_end date, p_offset integer, p_snapshot uuid default null
) returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'activities', (select coalesce(jsonb_agg(a.activity order by a.activity_date desc, a.activity_id), '[]'::jsonb)
      from (
        select activity, activity_date, activity_id from portfolio_metrics.snaptrade_activities
        where credential_id = j.credential_id and snapshot_id = j.snapshot_id and account_id = p_account
          and activity_date between p_start and p_end
        order by activity_date desc, activity_id offset p_offset limit 50
      ) a),
    'omitted', case when p_offset = 0 then coalesce((j.omitted->>p_account::text)::integer,0) else 0 end,
    'nextOffset', case when (select count(*) from (
      select 1 from portfolio_metrics.snaptrade_activities
      where credential_id = j.credential_id and snapshot_id = j.snapshot_id and account_id = p_account
        and activity_date between p_start and p_end
      offset p_offset limit 51
    ) remaining) > 50 then p_offset + 50 end,
    'syncedAt', j.synced_at, 'snapshot', j.snapshot_id
  )
  from portfolio_metrics.snaptrade_activity_jobs j join public.secure_credentials c on c.id = j.credential_id
  where c.user_id = p_user and c.revoked_at is null and p_account = any(j.accounts)
    and (p_snapshot is null or j.snapshot_id = p_snapshot)
    and j.snapshot_from <= p_start and j.snapshot_to >= p_end and j.synced_at >= now() - interval '36 hours';
$$;

revoke all on function public.claim_snaptrade_activity_jobs(), public.advance_snaptrade_activity_job(uuid,uuid,uuid[],jsonb,integer,integer),
  public.defer_snaptrade_activity_job(uuid,uuid,boolean), public.read_snaptrade_activity_cache(uuid,uuid,date,date,integer,uuid) from public, anon, authenticated;
grant execute on function public.claim_snaptrade_activity_jobs(), public.advance_snaptrade_activity_job(uuid,uuid,uuid[],jsonb,integer,integer),
  public.defer_snaptrade_activity_job(uuid,uuid,boolean), public.read_snaptrade_activity_cache(uuid,uuid,date,date,integer,uuid) to service_role;

create function public.invoke_snaptrade_activity_sync() returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net')
     or pg_catalog.to_regclass('vault.decrypted_secrets') is null then
    return 'skipped: pg_net or Vault is not installed';
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_url using 'snaptrade_activity_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_secret using 'snaptrade_activity_secret';
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return 'skipped: worker address or secret missing';
  end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 50000)'
    using v_url, jsonb_build_object('content-type', 'application/json', 'x-scheduler-secret', v_secret), '{}'::jsonb;
  return 'requested';
end;
$$;
revoke all on function public.invoke_snaptrade_activity_sync() from public, anon, authenticated;
grant execute on function public.invoke_snaptrade_activity_sync() to service_role;
do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
    and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $job$select cron.schedule('snaptrade-activity-sync', '* * * * *', 'select public.invoke_snaptrade_activity_sync()')$job$;
  end if;
end $$;
