alter table public.portfolio_holdings add column closed_at timestamptz;

-- Keep a holding change and its ledger writes visible together to report readers.
create function public.sync_portfolio_ledger(
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
    (id, user_id, holding_id, transaction_date, shares, price_per_share, type, fees, avg_cost_at_sale, deleted_at)
  select row.id, owner_id, saved_id, row.transaction_date, row.shares, row.price_per_share,
    row.type, row.fees, row.avg_cost_at_sale, case when row.id = any(p_deleted_ids) then now() end
  from jsonb_to_recordset(p_transactions) as row(
    id uuid, transaction_date timestamptz, shares double precision, price_per_share double precision,
    type text, fees double precision, avg_cost_at_sale double precision
  )
  on conflict (id) do update set
    transaction_date = excluded.transaction_date,
    shares = excluded.shares,
    price_per_share = excluded.price_per_share,
    type = excluded.type,
    fees = excluded.fees,
    avg_cost_at_sale = excluded.avg_cost_at_sale,
    deleted_at = excluded.deleted_at
  where t.user_id = owner_id and t.holding_id = saved_id and t.deleted_at is null
    and (t.id = any(p_changed_ids) or t.id = any(p_deleted_ids));
end;
$$;

revoke execute on function public.sync_portfolio_ledger(uuid, jsonb, jsonb, uuid[], uuid[], timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.sync_portfolio_ledger(uuid, jsonb, jsonb, uuid[], uuid[], timestamptz, timestamptz)
  to authenticated;
