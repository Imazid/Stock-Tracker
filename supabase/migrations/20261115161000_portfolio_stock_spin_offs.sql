create table public.portfolio_stock_spin_offs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_holding_id uuid not null references public.portfolio_holdings(id) on delete cascade,
  child_holding_id uuid not null references public.portfolio_holdings(id) on delete cascade,
  effective_on date not null check (effective_on between '1900-01-01' and (now() at time zone 'Australia/Sydney')::date),
  parent_shares numeric not null check (parent_shares > 0 and parent_shares < 1000000000000 and scale(parent_shares) <= 18),
  child_shares numeric not null check (child_shares > 0 and child_shares < 1000000000000 and scale(child_shares) <= 18),
  child_basis_pct_usd numeric check (child_basis_pct_usd > 0 and child_basis_pct_usd < 100 and scale(child_basis_pct_usd) <= 12),
  child_basis_pct_aud numeric check (child_basis_pct_aud > 0 and child_basis_pct_aud < 100 and scale(child_basis_pct_aud) <= 12),
  average_aud_basis boolean not null default false,
  statement_reference text not null check (char_length(btrim(statement_reference)) between 1 and 200),
  child_snapshot_id uuid unique references public.transactions(id) on delete set null,
  updated_at timestamptz not null default now(),
  check (parent_holding_id <> child_holding_id),
  check (child_basis_pct_usd is not null or child_basis_pct_aud is not null),
  check (not average_aud_basis or child_basis_pct_aud is not null),
  unique (parent_holding_id, child_holding_id, effective_on)
);

create index portfolio_stock_spin_offs_owner_idx on public.portfolio_stock_spin_offs (user_id, id);
create index portfolio_stock_spin_offs_child_idx on public.portfolio_stock_spin_offs (child_holding_id);
create trigger portfolio_stock_spin_offs_touch before update on public.portfolio_stock_spin_offs
  for each row execute function public.touch_updated_at();

create function public.check_stock_spin_off() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (
    select from public.portfolio_holdings parent
    join public.portfolio_holdings child on child.id = new.child_holding_id
    where parent.id = new.parent_holding_id and parent.user_id = new.user_id and child.user_id = new.user_id
      and parent.asset_kind = 'Stock' and child.asset_kind = 'Stock'
      and nullif(btrim(parent.asset_symbol), '') is not null and nullif(btrim(child.asset_symbol), '') is not null
      and nullif(btrim(parent.asset_exchange), '') is not null and nullif(btrim(child.asset_exchange), '') is not null
      and (upper(btrim(parent.asset_symbol)), upper(btrim(parent.asset_exchange))) <>
          (upper(btrim(child.asset_symbol)), upper(btrim(child.asset_exchange)))
      and (parent.broker_account is null or child.broker_account is null or
        parent.broker_account->>'account_id' = child.broker_account->>'account_id')
  ) then
    raise exception using errcode = '23514', message = 'Choose distinct stock listings from the same account.';
  end if;

  if new.child_snapshot_id is not null and not exists (
    select from public.transactions t
    where t.id = new.child_snapshot_id and t.user_id = new.user_id and t.holding_id = new.child_holding_id
      and t.deleted_at is null and t.type = 'Buy'
      and t.trade_provenance->>'source' in ('broker_position', 'csv_position')
      and t.shares::text::numeric = new.child_shares
      and (t.transaction_date at time zone 'Australia/Sydney')::date >= new.effective_on
  ) then
    raise exception using errcode = '23514', message = 'Choose a matching child position snapshot on or after the spin-off.';
  end if;
  return new;
end;
$$;
revoke all on function public.check_stock_spin_off() from public, anon, authenticated;

create trigger portfolio_stock_spin_offs_validate before insert or update of parent_holding_id, child_holding_id,
  effective_on, child_shares, child_snapshot_id on public.portfolio_stock_spin_offs
  for each row execute function public.check_stock_spin_off();

alter table public.portfolio_stock_spin_offs enable row level security;
revoke all on public.portfolio_stock_spin_offs from public, anon, authenticated;
grant select, delete on public.portfolio_stock_spin_offs to authenticated;
grant insert (user_id, parent_holding_id, child_holding_id, effective_on, parent_shares, child_shares,
  child_basis_pct_usd, child_basis_pct_aud, average_aud_basis, statement_reference, child_snapshot_id)
  on public.portfolio_stock_spin_offs to authenticated;
grant update (parent_holding_id, child_holding_id, effective_on, parent_shares, child_shares,
  child_basis_pct_usd, child_basis_pct_aud, average_aud_basis, statement_reference, child_snapshot_id)
  on public.portfolio_stock_spin_offs to authenticated;
create policy "Read own spin-offs" on public.portfolio_stock_spin_offs for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Insert own spin-offs" on public.portfolio_stock_spin_offs for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "Edit own spin-offs" on public.portfolio_stock_spin_offs for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own spin-offs" on public.portfolio_stock_spin_offs for delete to authenticated
  using (user_id = (select auth.uid()));
