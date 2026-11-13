-- The ledger stays USD. The optional provenance records the actual input and
-- the bookkeeping multiplier. Historical rows keep NULL provenance.
alter table public.transactions add column trade_provenance jsonb;
alter table public.transactions add constraint transactions_trade_provenance_check check (
  trade_provenance is null or coalesce(
    jsonb_typeof(trade_provenance) = 'object'
    and trade_provenance->>'source' in ('manual_trade', 'opening_position', 'csv_position', 'broker_position')
    and (
      (trade_provenance->>'currency' is null and trade_provenance->>'unitPrice' is null
        and trade_provenance->>'fees' is null and trade_provenance->>'usdPerUnit' is null
        and trade_provenance->>'conversion' is null and trade_provenance->>'conversionRecordedAt' is null)
      or (
        trade_provenance->>'currency' ~ '^[A-Z]{3}$'
        and (trade_provenance->>'unitPrice' is not null or trade_provenance->>'fees' is not null)
        and (trade_provenance->>'unitPrice' is null or
          (jsonb_typeof(trade_provenance->'unitPrice') = 'number' and (trade_provenance->>'unitPrice')::numeric >= 0))
        and (trade_provenance->>'fees' is null or
          (jsonb_typeof(trade_provenance->'fees') = 'number' and (trade_provenance->>'fees')::numeric >= 0))
        and jsonb_typeof(trade_provenance->'usdPerUnit') = 'number'
        and (trade_provenance->>'usdPerUnit')::numeric > 0
        and trade_provenance->>'conversionRecordedAt' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        and ((trade_provenance->>'currency' = 'USD' and trade_provenance->>'conversion' = 'usd'
          and (trade_provenance->>'usdPerUnit')::numeric = 1)
          or (trade_provenance->>'currency' <> 'USD'
          and trade_provenance->>'conversion' in ('app_reference', 'app_fallback')))
      )
    ), false
  )
);

-- A client without provenance can still edit USD values. Retain the metadata
-- when those amounts are unchanged, and discard it when they no longer agree.
create function public.clear_stale_trade_amounts()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.trade_provenance is not distinct from old.trade_provenance and new.deleted_at is null then
    if new.price_per_share is distinct from old.price_per_share then
      new.trade_provenance := new.trade_provenance - 'unitPrice';
    end if;
    if new.fees is distinct from old.fees then
      new.trade_provenance := new.trade_provenance - 'fees';
    end if;
    if new.trade_provenance->>'unitPrice' is null and new.trade_provenance->>'fees' is null then
      new.trade_provenance := jsonb_build_object('source', new.trade_provenance->>'source');
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.clear_stale_trade_amounts() from public, anon, authenticated;
create trigger transactions_clear_stale_trade_amounts
before update of price_per_share, fees on public.transactions
for each row when (old.trade_provenance is not null)
execute function public.clear_stale_trade_amounts();

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
    (id, user_id, asset_symbol, asset_name, asset_kind, asset_exchange, shares, avg_cost, date_added, deleted_at, closed_at)
  select holding_id, owner_id, row.asset_symbol, row.asset_name, row.asset_kind, row.asset_exchange,
    row.shares, row.avg_cost, row.date_added, p_archived_at, p_closed_at
  from jsonb_to_record(p_holding) as row(
    asset_symbol text, asset_name text, asset_kind text, asset_exchange text,
    shares double precision, avg_cost double precision, date_added timestamptz
  )
  on conflict (id) do update set
    asset_symbol = excluded.asset_symbol,
    asset_name = excluded.asset_name,
    asset_kind = excluded.asset_kind,
    asset_exchange = excluded.asset_exchange,
    shares = excluded.shares,
    avg_cost = excluded.avg_cost,
    date_added = excluded.date_added,
    deleted_at = coalesce(h.deleted_at, excluded.deleted_at),
    closed_at = coalesce(h.closed_at, excluded.closed_at)
  where h.user_id = owner_id and (h.deleted_at is null or h.deleted_at = p_archived_at)
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
