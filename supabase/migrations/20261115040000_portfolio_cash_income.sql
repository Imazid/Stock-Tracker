create table public.portfolio_cash_income (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  paid_on date not null check (paid_on between '1900-01-01' and (now() at time zone 'Australia/Sydney')::date),
  kind text not null check (kind in ('dividend','distribution','substitute_dividend')),
  payer text not null check (char_length(btrim(payer)) between 1 and 100),
  account_label text not null default '' check (char_length(account_label) <= 100),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  cash_received numeric not null check (cash_received > 0 and cash_received < 1000000000000 and scale(cash_received) <= 8),
  gross_amount numeric check (gross_amount >= cash_received and gross_amount < 1000000000000 and scale(gross_amount) <= 8),
  withholding numeric check (withholding >= 0 and withholding < 1000000000000 and scale(withholding) <= 8
    and (gross_amount is null or cash_received + withholding <= gross_amount)),
  franking_credit_aud numeric check (franking_credit_aud >= 0 and franking_credit_aud < 1000000000000 and scale(franking_credit_aud) <= 8),
  statement_reference text not null default '' check (char_length(statement_reference) <= 200),
  snaptrade_activity_id text check (snaptrade_activity_id ~ '^[0-9a-f]{64}$'),
  snaptrade_reported_on date check (snaptrade_reported_on between '1900-01-01' and '9999-12-31'),
  snaptrade_reported_currency text check (snaptrade_reported_currency ~ '^[A-Z]{3}$'),
  snaptrade_reported_amount numeric check (snaptrade_reported_amount > 0 and snaptrade_reported_amount < 1000000000000 and scale(snaptrade_reported_amount) <= 8),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_currency,snaptrade_reported_amount) in (0,4)),
  constraint portfolio_cash_income_broker_key unique (user_id, snaptrade_activity_id)
);
create index portfolio_cash_income_owner_paid_idx on public.portfolio_cash_income (user_id, paid_on desc, id desc);
create trigger portfolio_cash_income_touch before update on public.portfolio_cash_income
  for each row execute function public.touch_updated_at();

alter table public.portfolio_cash_income enable row level security;
revoke all on public.portfolio_cash_income from public, anon, authenticated;
grant select, delete on public.portfolio_cash_income to authenticated;
grant insert (user_id,paid_on,kind,payer,account_label,currency,cash_received,gross_amount,withholding,franking_credit_aud,
  statement_reference,snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_currency,snaptrade_reported_amount)
  on public.portfolio_cash_income to authenticated;
grant update (paid_on,kind,payer,account_label,currency,cash_received,gross_amount,withholding,franking_credit_aud,statement_reference)
  on public.portfolio_cash_income to authenticated;

create policy "Read own income" on public.portfolio_cash_income for select to authenticated
using (user_id = (select auth.uid()));
create policy "Add own income" on public.portfolio_cash_income for insert to authenticated
with check (user_id = (select auth.uid()));
create policy "Update own income" on public.portfolio_cash_income for update to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own income" on public.portfolio_cash_income for delete to authenticated
using (user_id = (select auth.uid()));

create function public.portfolio_cash_income_totals(p_from date default null, p_through date default null)
returns table(currency text, cash_received text, payments integer)
language sql stable security invoker set search_path = '' as $$
  select p.currency, trim_scale(sum(p.cash_received))::text, count(*)::integer
  from public.portfolio_cash_income p where p.user_id = (select auth.uid())
    and (p_from is null or p.paid_on >= p_from) and (p_through is null or p.paid_on <= p_through)
  group by p.currency order by p.currency;
$$;
revoke all on function public.portfolio_cash_income_totals(date,date) from public, anon, authenticated;
grant execute on function public.portfolio_cash_income_totals(date,date) to authenticated;
