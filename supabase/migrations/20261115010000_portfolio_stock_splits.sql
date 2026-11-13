-- Statement-based lot adjustments use a separate ledger from actual trades.
create table public.portfolio_stock_splits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  holding_id uuid not null references public.portfolio_holdings(id) on delete cascade,
  effective_date date not null check (effective_date between '1900-01-01'::date and (now() at time zone 'Australia/Sydney')::date),
  new_shares integer not null check (new_shares between 1 and 1000000),
  old_shares integer not null check (old_shares between 1 and 1000000),
  statement_reference text not null default '' check (char_length(statement_reference) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (new_shares <> old_shares),
  unique (holding_id, effective_date)
);

create index portfolio_stock_splits_owner_id_idx on public.portfolio_stock_splits (user_id, id);
create trigger portfolio_stock_splits_touch before update on public.portfolio_stock_splits
for each row execute function public.touch_updated_at();

alter table public.portfolio_stock_splits enable row level security;
revoke all on public.portfolio_stock_splits from public, anon, authenticated;
grant select, delete on public.portfolio_stock_splits to authenticated;
grant insert (user_id, holding_id, effective_date, new_shares, old_shares, statement_reference)
  on public.portfolio_stock_splits to authenticated;
grant update (holding_id, effective_date, new_shares, old_shares, statement_reference)
  on public.portfolio_stock_splits to authenticated;

create policy "Read own splits" on public.portfolio_stock_splits for select to authenticated
using (user_id = (select auth.uid()));

create policy "Add splits to own stock holdings" on public.portfolio_stock_splits for insert to authenticated
with check (user_id = (select auth.uid()) and exists (
  select 1 from public.portfolio_holdings h
  where h.id = holding_id and h.user_id = (select auth.uid()) and h.asset_kind = 'Stock'
));

create policy "Edit splits on own stock holdings" on public.portfolio_stock_splits for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()) and exists (
  select 1 from public.portfolio_holdings h
  where h.id = holding_id and h.user_id = (select auth.uid()) and h.asset_kind = 'Stock'
));

create policy "Remove own splits" on public.portfolio_stock_splits for delete to authenticated
using (user_id = (select auth.uid()));
