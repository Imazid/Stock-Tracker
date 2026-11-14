-- A single statement entry supplies both the income record and its acquisition.
create table public.portfolio_dividend_reinvestments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  holding_id uuid not null references public.portfolio_holdings(id) on delete cascade,
  paid_on date not null check (paid_on between '1900-01-01' and (now() at time zone 'Australia/Sydney')::date),
  acquired_on date not null check (acquired_on between '1900-01-01' and (now() at time zone 'Australia/Sydney')::date),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  dividend_amount numeric not null check (dividend_amount > 0 and dividend_amount < 1000000000000 and scale(dividend_amount) <= 8),
  reinvested_amount numeric not null check (reinvested_amount > 0 and reinvested_amount < 1000000000000 and scale(reinvested_amount) <= 8),
  shares numeric not null check (shares > 0 and shares < 1000000000000 and scale(shares) <= 18),
  basis_usd numeric check (basis_usd > 0 and basis_usd < 1000000000000 and scale(basis_usd) <= 8),
  franking_credit_aud numeric check (franking_credit_aud >= 0 and franking_credit_aud < 1000000000000 and scale(franking_credit_aud) <= 8),
  statement_reference text not null default '' check (char_length(statement_reference) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (currency <> 'USD' or basis_usd is null or basis_usd = reinvested_amount),
  unique (holding_id, paid_on, acquired_on, currency, dividend_amount, reinvested_amount, shares)
);

create index portfolio_dividend_reinvestments_owner_idx on public.portfolio_dividend_reinvestments (user_id, id);
create trigger portfolio_dividend_reinvestments_touch before update on public.portfolio_dividend_reinvestments
  for each row execute function public.touch_updated_at();

alter table public.portfolio_dividend_reinvestments enable row level security;
revoke all on public.portfolio_dividend_reinvestments from public, anon, authenticated;
grant select, delete on public.portfolio_dividend_reinvestments to authenticated;
grant insert (user_id,holding_id,paid_on,acquired_on,currency,dividend_amount,reinvested_amount,shares,basis_usd,
  franking_credit_aud,statement_reference) on public.portfolio_dividend_reinvestments to authenticated;
grant update (holding_id,paid_on,acquired_on,currency,dividend_amount,reinvested_amount,shares,basis_usd,
  franking_credit_aud,statement_reference) on public.portfolio_dividend_reinvestments to authenticated;

create policy "Read own reinvestments" on public.portfolio_dividend_reinvestments for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Add reinvestments to own stocks" on public.portfolio_dividend_reinvestments for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select from public.portfolio_holdings h
    where h.id = holding_id and h.user_id = (select auth.uid()) and h.asset_kind = 'Stock'));
create policy "Update reinvestments on own stocks" on public.portfolio_dividend_reinvestments for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and exists (select from public.portfolio_holdings h
    where h.id = holding_id and h.user_id = (select auth.uid()) and h.asset_kind = 'Stock'));
create policy "Delete own reinvestments" on public.portfolio_dividend_reinvestments for delete to authenticated
  using (user_id = (select auth.uid()));
