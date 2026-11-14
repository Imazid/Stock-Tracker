-- A broker payment for less than one post-split share is recorded with its split.
-- Keep decimal inputs as text so PostgREST returns exactly the entered precision.
alter table public.portfolio_stock_splits
  add column fraction_shares text,
  add column fraction_paid_on date,
  add column fraction_currency text,
  add column fraction_proceeds text,
  add column fraction_fees text,
  add column fraction_net_usd text,
  add constraint portfolio_stock_splits_fraction_cash_check check (
    num_nonnulls(fraction_shares, fraction_paid_on, fraction_currency, fraction_proceeds, fraction_fees, fraction_net_usd) = 0
    or (
      num_nonnulls(fraction_shares, fraction_paid_on, fraction_currency, fraction_proceeds, fraction_fees) = 5
      and fraction_paid_on between effective_date and (now() at time zone 'Australia/Sydney')::date
      and fraction_currency ~ '^[A-Z]{3}$'
      and char_length(btrim(statement_reference)) > 0
      and fraction_shares ~ '^0\.[0-9]{1,18}$'
      and fraction_shares !~ '^0\.0+$'
      and case when fraction_proceeds ~ '^(0|[1-9][0-9]{0,10})(\.[0-9]{1,8})?$'
        and fraction_fees ~ '^(0|[1-9][0-9]{0,10})(\.[0-9]{1,8})?$'
        then fraction_proceeds::numeric > 0 and fraction_fees::numeric <= fraction_proceeds::numeric
        else false end
      and (fraction_net_usd is null or (fraction_currency <> 'USD' and
        fraction_net_usd ~ '^(0|[1-9][0-9]{0,10})(\.[0-9]{1,8})?$'))
    )
  );

grant insert (fraction_shares, fraction_paid_on, fraction_currency, fraction_proceeds, fraction_fees, fraction_net_usd)
  on public.portfolio_stock_splits to authenticated;
grant update (fraction_shares, fraction_paid_on, fraction_currency, fraction_proceeds, fraction_fees, fraction_net_usd)
  on public.portfolio_stock_splits to authenticated;
