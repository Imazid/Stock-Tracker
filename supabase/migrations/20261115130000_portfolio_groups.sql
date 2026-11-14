-- The original holdings and daily-value tables remain the account's default portfolio.
-- A nullable group also lets existing rows and integrations retain their identifiers.
create table public.portfolio_groups (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 80),
  emoji text not null check (length(emoji) between 1 and 24),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id)
);

alter table public.portfolio_groups enable row level security;
create policy "owners can read portfolios" on public.portfolio_groups for select to authenticated
  using (user_id = auth.uid());
revoke all on public.portfolio_groups from public, anon, authenticated;
grant select on public.portfolio_groups to authenticated;

alter table public.portfolio_holdings add column portfolio_group_id uuid;
alter table public.portfolio_holdings add foreign key (user_id, portfolio_group_id)
  references public.portfolio_groups(user_id, id);
create index portfolio_holdings_group_idx on public.portfolio_holdings(user_id, portfolio_group_id);

create function public.check_holding_portfolio_group() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.portfolio_group_id is not distinct from old.portfolio_group_id then return new; end if;
    if old.portfolio_group_id is not null or current_user in ('authenticated', 'anon') then
      raise exception 'A named holding cannot be reassigned' using errcode = '22023';
    end if;
  end if;
  if new.portfolio_group_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('portfolio-groups:' || new.user_id::text, 0));
    if new.portfolio_group_id = '00000000-0000-0000-0000-000000000002' or not exists(
      select 1 from public.portfolio_groups where user_id = new.user_id and id = new.portfolio_group_id
        and deleted_at is null
    ) then
      raise exception 'The selected portfolio is unavailable' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger portfolio_holdings_validate_group before insert or update of portfolio_group_id
  on public.portfolio_holdings for each row execute function public.check_holding_portfolio_group();

-- Legacy reads and upserts continue to work. New app writes can compare the source time.
alter table public.portfolio_snapshots add column observed_at timestamptz;

create function public.stamp_legacy_portfolio_value() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.total_value is distinct from old.total_value
    and new.observed_at is not distinct from old.observed_at then
    new.observed_at := now();
  end if;
  return new;
end;
$$;
create trigger portfolio_snapshots_observed_at before update on public.portfolio_snapshots
for each row execute function public.stamp_legacy_portfolio_value();

create table public.portfolio_group_snapshots (
  user_id uuid not null,
  portfolio_group_id uuid not null,
  snapshot_date date not null,
  total_value double precision not null check (total_value >= 0 and total_value < 'Infinity'::double precision),
  observed_at timestamptz not null,
  primary key (user_id, portfolio_group_id, snapshot_date),
  foreign key (user_id, portfolio_group_id) references public.portfolio_groups(user_id, id) on delete cascade
);
alter table public.portfolio_group_snapshots enable row level security;
create policy "owners can read portfolio group values" on public.portfolio_group_snapshots for select to authenticated
  using (user_id = auth.uid());
revoke all on public.portfolio_group_snapshots from public, anon, authenticated;
grant select on public.portfolio_group_snapshots to authenticated;

create table public.portfolio_group_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  primary key (user_id, id)
);
alter table public.portfolio_group_receipts enable row level security;
revoke all on public.portfolio_group_receipts from public, anon, authenticated;

create function public.apply_portfolio_group_change(p_user_id uuid, p_id uuid, p_group_id uuid,
  p_action text, p_name text default null, p_emoji text default null, p_holdings uuid[] default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  default_id constant uuid := '00000000-0000-0000-0000-000000000002';
begin
  if owner_id is null or owner_id is distinct from p_user_id then
    raise exception 'The portfolio account changed' using errcode = '42501';
  end if;
  if p_id is null or p_group_id is null or p_action is null
    or p_action not in ('import', 'create', 'rename', 'delete') then
    raise exception 'Invalid portfolio change' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('portfolio-groups:' || owner_id::text, 0));
  insert into public.portfolio_group_receipts values (owner_id, p_id) on conflict do nothing;
  if not found then return; end if;

  if p_action in ('create', 'import') then
    insert into public.portfolio_groups(user_id, id, name, emoji)
      values(owner_id, p_group_id, btrim(p_name), p_emoji) on conflict do nothing;
    if found and p_action = 'import' and p_group_id <> default_id then
      -- A legacy device may know which locally named portfolio already-synced IDs belonged to.
      -- An existing assignment, even a deleted one, wins over a different device's import.
      update public.portfolio_holdings set portfolio_group_id = p_group_id
        where user_id = owner_id and portfolio_group_id is null and id = any(p_holdings);
    end if;
  elsif p_action = 'rename' then
    if p_group_id = default_id then
      insert into public.portfolio_groups(user_id,id,name,emoji) values(owner_id,default_id,btrim(p_name),'💼')
        on conflict (user_id,id) do update set name = excluded.name;
    else
      update public.portfolio_groups set name = btrim(p_name)
        where user_id = owner_id and id = p_group_id and deleted_at is null;
    end if;
  else
    if p_group_id = default_id then
      raise exception 'The main portfolio cannot be deleted' using errcode = '22023';
    end if;
    if exists(select from public.portfolio_holdings where user_id = owner_id and portfolio_group_id = p_group_id
        and deleted_at is null and broker_account->>'tracking' = 'true') then
      raise exception 'Stop brokerage tracking before deleting this portfolio' using errcode = '22023';
    end if;
    update public.portfolio_groups set deleted_at = now()
      where user_id = owner_id and id = p_group_id and deleted_at is null;
    -- Keep ledger rows available for reports and retain the existing archive semantics.
    update public.portfolio_holdings set deleted_at = now()
      where user_id = owner_id and portfolio_group_id = p_group_id and deleted_at is null;
  end if;
end;
$$;

-- Named portfolio valuations carry the actual observation time. An older offline
-- device cannot replace a newer value on the same day.
create function public.save_portfolio_group_value(p_user_id uuid, p_group_id uuid, p_snapshot_date date,
  p_total_value double precision, p_observed_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
begin
  if owner_id is null or owner_id is distinct from p_user_id then
    raise exception 'The portfolio account changed' using errcode = '42501';
  end if;
  if p_total_value is null or not (p_total_value >= 0 and p_total_value < 'Infinity'::double precision)
    or p_observed_at is null or p_observed_at > now() + interval '5 minutes'
    or p_snapshot_date is distinct from (p_observed_at at time zone 'UTC')::date then
    raise exception 'Invalid valuation observation date' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('portfolio-groups:' || owner_id::text, 0));
  if p_group_id = '00000000-0000-0000-0000-000000000002' then
    insert into public.portfolio_snapshots as s (user_id,snapshot_date,total_value,observed_at)
      values(owner_id,p_snapshot_date,p_total_value,p_observed_at)
    on conflict (user_id,snapshot_date) do update
      set total_value = excluded.total_value, observed_at = excluded.observed_at
      where coalesce(s.observed_at, s.updated_at) < excluded.observed_at;
    return;
  end if;
  insert into public.portfolio_group_snapshots as s
    (user_id, portfolio_group_id, snapshot_date, total_value, observed_at)
  select owner_id, p_group_id, p_snapshot_date, p_total_value, p_observed_at
  from public.portfolio_groups
  where user_id = owner_id and id = p_group_id and deleted_at is null
  on conflict (user_id, portfolio_group_id, snapshot_date) do update
    set total_value = excluded.total_value, observed_at = excluded.observed_at
    where s.observed_at < excluded.observed_at;
end;
$$;

revoke all on function public.apply_portfolio_group_change(uuid,uuid,uuid,text,text,text,uuid[]) from public, anon;
revoke all on function public.save_portfolio_group_value(uuid,uuid,date,double precision,timestamptz) from public, anon;
grant execute on function public.apply_portfolio_group_change(uuid,uuid,uuid,text,text,text,uuid[]) to authenticated;
grant execute on function public.save_portfolio_group_value(uuid,uuid,date,double precision,timestamptz) to authenticated;

create or replace function public.sync_portfolio_ledger(
  p_user_id uuid,
  p_holding jsonb,
  p_transactions jsonb,
  p_changed_ids uuid[],
  p_deleted_ids uuid[],
  p_archived_at timestamptz,
  p_closed_at timestamptz
) returns void
language plpgsql security invoker set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  holding_id uuid := (p_holding ->> 'id')::uuid;
  saved_id uuid;
  requested_group uuid := (p_holding->>'portfolio_group_id')::uuid;
  declares_group boolean := p_holding ? 'portfolio_group_id';
begin
  if owner_id is null or owner_id is distinct from p_user_id then
    raise exception 'Portfolio account changed' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('portfolio-groups:' || owner_id::text, 0));
  if requested_group is not null and not exists (
    select 1 from public.portfolio_groups where user_id = owner_id and id = requested_group
      and id <> '00000000-0000-0000-0000-000000000002' and deleted_at is null
  ) then return; end if;
  if p_closed_at is not null and (p_archived_at is null or (p_holding ->> 'shares')::double precision <> 0) then
    raise exception 'A closed holding must be archived with zero shares' using errcode = '22023';
  end if;

  insert into public.portfolio_holdings as h
    (id, user_id, asset_symbol, asset_name, asset_kind, asset_exchange, shares, avg_cost, date_added, deleted_at, closed_at, broker_account, portfolio_group_id)
  select holding_id, owner_id, row.asset_symbol, row.asset_name, row.asset_kind, row.asset_exchange,
    row.shares, row.avg_cost, row.date_added, p_archived_at, p_closed_at, row.broker_account, requested_group
  from jsonb_to_record(p_holding) as row(
    asset_symbol text, asset_name text, asset_kind text, asset_exchange text,
    shares double precision, avg_cost double precision, date_added timestamptz, broker_account jsonb
  )
  on conflict (id) do update set
    broker_account = coalesce(excluded.broker_account, h.broker_account),
    asset_symbol = excluded.asset_symbol,
    asset_name = excluded.asset_name,
    asset_kind = excluded.asset_kind,
    asset_exchange = excluded.asset_exchange,
    shares = excluded.shares,
    avg_cost = excluded.avg_cost,
    date_added = excluded.date_added,
    deleted_at = case when excluded.broker_account->>'tracking' = 'true' and p_archived_at is null
      and (excluded.broker_account->>'observed_at')::timestamptz > h.deleted_at and h.closed_at is null
      then null else coalesce(h.deleted_at, excluded.deleted_at) end,
    closed_at = coalesce(h.closed_at, excluded.closed_at)
  where h.user_id = owner_id and (
    h.portfolio_group_id is not distinct from requested_group
    or (not declares_group and h.broker_account is not null and excluded.broker_account is not null
      and exists (select 1 from public.portfolio_groups where user_id = owner_id and id = h.portfolio_group_id
        and deleted_at is null))
  ) and (
    h.broker_account is null or h.broker_account->>'tracking' = 'false' or excluded.broker_account is not null
  ) and (
    h.broker_account is null or excluded.broker_account is null or (
      h.broker_account->>'account_id' = excluded.broker_account->>'account_id' and
      (h.broker_account->>'tracking' = 'true' or excluded.broker_account->>'tracking' = 'false') and
      (excluded.broker_account->>'observed_at')::timestamptz >= (h.broker_account->>'observed_at')::timestamptz
    )
  ) and (h.deleted_at is null or h.deleted_at = p_archived_at or (
    excluded.broker_account->>'tracking' = 'true' and p_archived_at is null and h.closed_at is null
    and (excluded.broker_account->>'observed_at')::timestamptz > h.deleted_at
  ))
  returning h.id into saved_id;

  -- A newer archive wins over open writes from a device that has been offline.
  if saved_id is null then return; end if;

  insert into public.transactions as t
    (id, user_id, holding_id, transaction_date, shares, price_per_share, type, fees, avg_cost_at_sale, trade_provenance, deleted_at)
  select row.id, owner_id, saved_id, row.transaction_date, row.shares, row.price_per_share,
    row.type, row.fees, row.avg_cost_at_sale, row.trade_provenance, case when row.id = any(p_deleted_ids) then now() end
  from jsonb_to_recordset(p_transactions) as row(
    id uuid, transaction_date timestamptz, shares double precision, price_per_share double precision,
    type text, fees double precision, avg_cost_at_sale double precision, trade_provenance jsonb
  )
  on conflict (id) do update set
    transaction_date = excluded.transaction_date,
    shares = excluded.shares,
    price_per_share = excluded.price_per_share,
    type = excluded.type,
    fees = excluded.fees,
    avg_cost_at_sale = excluded.avg_cost_at_sale,
    trade_provenance = case
      when excluded.deleted_at is not null then t.trade_provenance
      else coalesce(excluded.trade_provenance, t.trade_provenance)
    end,
    deleted_at = excluded.deleted_at
  where t.user_id = owner_id and t.holding_id = saved_id and t.deleted_at is null
    and (t.id = any(p_changed_ids) or t.id = any(p_deleted_ids));
end;
$$;

