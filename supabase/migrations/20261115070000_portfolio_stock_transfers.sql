create table public.portfolio_stock_transfers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  from_holding_id uuid not null references public.portfolio_holdings(id) on delete cascade,
  to_holding_id uuid not null references public.portfolio_holdings(id) on delete cascade,
  sent_on date not null check (sent_on between '1900-01-01' and (now() at time zone 'Australia/Sydney')::date),
  received_on date not null check (received_on between sent_on and (now() at time zone 'Australia/Sydney')::date),
  shares numeric not null check (shares > 0 and shares < 1000000000000 and scale(shares) <= 18),
  same_day_order smallint not null default 1 check (same_day_order between 1 and 999),
  from_account text not null check (char_length(btrim(from_account)) between 1 and 100),
  to_account text not null check (char_length(btrim(to_account)) between 1 and 100),
  statement_reference text not null default '' check (char_length(statement_reference) <= 200),
  receiving_snapshot_id uuid unique references public.transactions(id) on delete set null,
  updated_at timestamptz not null default now(),
  check (from_holding_id <> to_holding_id and lower(btrim(from_account)) <> lower(btrim(to_account))),
  unique (from_holding_id, to_holding_id, sent_on, received_on, shares),
  unique (user_id, sent_on, same_day_order)
);

create index portfolio_stock_transfers_owner_idx on public.portfolio_stock_transfers (user_id, id);
create index portfolio_stock_transfers_to_holding_idx on public.portfolio_stock_transfers (to_holding_id);
create trigger portfolio_stock_transfers_touch before update on public.portfolio_stock_transfers
  for each row execute function public.touch_updated_at();

create function public.check_stock_transfer_holdings() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (
    select from public.portfolio_holdings source
    join public.portfolio_holdings destination on destination.id = new.to_holding_id
    where source.id = new.from_holding_id and source.user_id = new.user_id and destination.user_id = new.user_id
      and source.asset_kind = 'Stock' and destination.asset_kind = 'Stock'
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
revoke all on function public.check_stock_transfer_holdings() from public, anon, authenticated;

create trigger portfolio_stock_transfers_check before insert or update of from_holding_id,to_holding_id,
  receiving_snapshot_id,received_on,shares on public.portfolio_stock_transfers
  for each row execute function public.check_stock_transfer_holdings();

alter table public.portfolio_stock_transfers enable row level security;
revoke all on public.portfolio_stock_transfers from public, anon, authenticated;
grant select, delete on public.portfolio_stock_transfers to authenticated;
grant insert (user_id,from_holding_id,to_holding_id,sent_on,received_on,shares,same_day_order,
  from_account,to_account,statement_reference,receiving_snapshot_id) on public.portfolio_stock_transfers to authenticated;
grant update (from_holding_id,to_holding_id,sent_on,received_on,shares,same_day_order,
  from_account,to_account,statement_reference,receiving_snapshot_id) on public.portfolio_stock_transfers to authenticated;
create policy "Read own stock transfers" on public.portfolio_stock_transfers for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Insert own stock transfers" on public.portfolio_stock_transfers for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "Edit own stock transfers" on public.portfolio_stock_transfers for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own stock transfers" on public.portfolio_stock_transfers for delete to authenticated
  using (user_id = (select auth.uid()));
