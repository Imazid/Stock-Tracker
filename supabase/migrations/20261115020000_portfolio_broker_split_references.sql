-- Store the broker reference reviewed by the owner alongside the statement ratio.
alter table public.portfolio_stock_splits
  add column snaptrade_activity_id text,
  add column snaptrade_activity_date date,
  add column snaptrade_activity_label text,
  add column snaptrade_activity_symbol text,
  add constraint portfolio_stock_splits_snaptrade_reference_check check (
    (snaptrade_activity_id is null and snaptrade_activity_date is null
      and snaptrade_activity_label is null and snaptrade_activity_symbol is null)
    or (snaptrade_activity_id is not null and snaptrade_activity_id ~ '^[0-9a-f]{64}$'
      and snaptrade_activity_date is not null and snaptrade_activity_date between '1900-01-01' and '9999-12-31'
      and snaptrade_activity_label is not null and snaptrade_activity_label in ('Stock split', 'Reverse stock split')
      and (snaptrade_activity_symbol is null or char_length(snaptrade_activity_symbol) between 1 and 40))
  );

create unique index portfolio_stock_splits_snaptrade_activity_key
  on public.portfolio_stock_splits (user_id, snaptrade_activity_id)
  where snaptrade_activity_id is not null;

grant insert (snaptrade_activity_id, snaptrade_activity_date, snaptrade_activity_label, snaptrade_activity_symbol)
  on public.portfolio_stock_splits to authenticated;
