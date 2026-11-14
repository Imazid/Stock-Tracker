-- SnapTrade account identity stays scoped to the owner's existing RLS-protected holding.
-- Store a masked display label. No account numbers or provider credentials are needed.
alter table public.portfolio_holdings add column broker_account jsonb;
alter table public.portfolio_holdings add constraint portfolio_broker_account_shape check (
  broker_account is null or coalesce(
    jsonb_typeof(broker_account) = 'object' and
    broker_account->>'account_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and
    char_length(btrim(broker_account->>'label')) between 1 and 100 and
    char_length(btrim(broker_account->>'institution')) between 1 and 80 and
    pg_input_is_valid(broker_account->>'observed_at', 'timestamp with time zone') and
    broker_account->>'observed_at' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?Z$' and
    jsonb_typeof(broker_account->'tracking') = 'boolean',
    false)
);

create unique index portfolio_broker_account_listing_idx
  on public.portfolio_holdings (user_id, (broker_account->>'account_id'), asset_kind, asset_exchange, asset_symbol)
  where deleted_at is null and broker_account->>'tracking' = 'true';

-- Older clients used this direct archive when collapsing rows by ticker. Keep
-- account-linked positions intact when an old client attempts that cleanup.
create function public.protect_linked_portfolio_archive() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.broker_account->>'tracking' = 'true' and old.deleted_at is null and new.deleted_at is not null and
     new.broker_account is not distinct from old.broker_account then
    return null;
  end if;
  return new;
end;
$$;
revoke all on function public.protect_linked_portfolio_archive() from public, anon, authenticated;
create trigger portfolio_holdings_protect_linked_archive before update of deleted_at on public.portfolio_holdings
for each row execute function public.protect_linked_portfolio_archive();

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
begin
  if owner_id is null or owner_id is distinct from p_user_id then
    raise exception 'Portfolio account changed' using errcode = '42501';
  end if;
  if p_closed_at is not null and (p_archived_at is null or (p_holding ->> 'shares')::double precision <> 0) then
    raise exception 'A closed holding must be archived with zero shares' using errcode = '22023';
  end if;

  insert into public.portfolio_holdings as h
    (id, user_id, asset_symbol, asset_name, asset_kind, asset_exchange, shares, avg_cost, date_added, deleted_at, closed_at, broker_account)
  select holding_id, owner_id, row.asset_symbol, row.asset_name, row.asset_kind, row.asset_exchange,
    row.shares, row.avg_cost, row.date_added, p_archived_at, p_closed_at, row.broker_account
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

-- Publish a complete refresh in one transaction. Other readers see either the
-- previous positions or the whole refreshed set of sending and receiving accounts.
create function public.sync_broker_portfolio_ledger(p_changes jsonb) returns void
language plpgsql security invoker set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  change jsonb;
begin
  if owner_id is null or jsonb_typeof(p_changes) is distinct from 'array' then
    raise exception using errcode = '42501', message = 'A signed-in portfolio account is required.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('stock-tracker-broker-portfolio:' || owner_id::text, 0));
  for change in select value from jsonb_array_elements(p_changes) order by value->'p_holding'->>'id'
  loop
    if change->'p_holding'->'broker_account' is null or
       change->'p_holding'->'broker_account' = 'null'::jsonb or
       (change->>'p_user_id')::uuid is distinct from owner_id then
      raise exception using errcode = '42501', message = 'The broker portfolio owner changed.';
    end if;
    perform public.sync_portfolio_ledger(
      owner_id, change->'p_holding', change->'p_transactions',
      array(select value::uuid from jsonb_array_elements_text(change->'p_changed_ids')),
      array(select value::uuid from jsonb_array_elements_text(change->'p_deleted_ids')),
      (change->>'p_archived_at')::timestamptz, (change->>'p_closed_at')::timestamptz
    );
  end loop;
end;
$$;
revoke all on function public.sync_broker_portfolio_ledger(jsonb) from public, anon, authenticated;
grant execute on function public.sync_broker_portfolio_ledger(jsonb) to authenticated;

create or replace function public.check_stock_transfer_holdings() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (
    select from public.portfolio_holdings source
    join public.portfolio_holdings destination on destination.id = new.to_holding_id
    where source.id = new.from_holding_id and source.user_id = new.user_id and destination.user_id = new.user_id
      and source.asset_kind = 'Stock' and destination.asset_kind = 'Stock'
      and (source.broker_account is null or destination.broker_account is null or
        source.broker_account->>'account_id' <> destination.broker_account->>'account_id')
      and upper(btrim(source.asset_symbol)) = upper(btrim(destination.asset_symbol))
      and nullif(upper(btrim(source.asset_exchange)), '') = upper(btrim(destination.asset_exchange))
  ) then
    raise exception using errcode = '23514', message = 'Choose two owned holdings of the same listed stock.';
  end if;

  if new.receiving_snapshot_id is not null and not exists (
    select from public.transactions t
    where t.id = new.receiving_snapshot_id and t.user_id = new.user_id and t.holding_id = new.to_holding_id
      and t.deleted_at is null and t.type = 'Buy'
      and t.trade_provenance->>'source' in ('broker_position', 'csv_position')
      and t.shares::text::numeric = new.shares
      and (t.transaction_date at time zone 'Australia/Sydney')::date >= new.received_on
  ) then
    raise exception using errcode = '23514', message = 'Choose a receiving position snapshot with the same shares on or after receipt.';
  end if;
  return new;
end;
$$;
