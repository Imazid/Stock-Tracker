-- SnapTrade activity identifies a reviewed event. Statement values remain independently editable.
alter table public.portfolio_dividend_reinvestments
  add column snaptrade_activity_id text,
  add column snaptrade_reported_on date,
  add column snaptrade_reported_symbol text,
  add column snaptrade_reported_currency text,
  add column snaptrade_reported_amount numeric,
  add column snaptrade_reported_units numeric,
  add constraint portfolio_reinvestment_snaptrade_reference_check check (
    (snaptrade_activity_id is null and snaptrade_reported_on is null and snaptrade_reported_symbol is null
      and snaptrade_reported_currency is null and snaptrade_reported_amount is null and snaptrade_reported_units is null)
    or (snaptrade_activity_id is not null and snaptrade_activity_id ~ '^[0-9a-f]{64}$'
      and snaptrade_reported_on is not null and snaptrade_reported_on between '1900-01-01' and '9999-12-31'
      and (snaptrade_reported_symbol is null or char_length(snaptrade_reported_symbol) between 1 and 40)
      and (snaptrade_reported_currency is null or snaptrade_reported_currency ~ '^[A-Z]{3}$')
      and (snaptrade_reported_amount is null or
        (abs(snaptrade_reported_amount) <= 9007199254740991 and scale(snaptrade_reported_amount) <= 30))
      and (snaptrade_reported_units is null or
        (abs(snaptrade_reported_units) <= 9007199254740991 and scale(snaptrade_reported_units) <= 30)))
  );

create unique index portfolio_reinvestment_snaptrade_activity_key
  on public.portfolio_dividend_reinvestments (user_id, snaptrade_activity_id)
  where snaptrade_activity_id is not null;

grant insert (snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_symbol,snaptrade_reported_currency,
  snaptrade_reported_amount,snaptrade_reported_units) on public.portfolio_dividend_reinvestments to authenticated;

-- An owner may attach a reference to an older statement entry once.
grant update (snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_symbol,snaptrade_reported_currency,
  snaptrade_reported_amount,snaptrade_reported_units) on public.portfolio_dividend_reinvestments to authenticated;

create function public.preserve_reinvestment_broker_reference() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.snaptrade_activity_id is not null and
    (new.snaptrade_activity_id,new.snaptrade_reported_on,new.snaptrade_reported_symbol,new.snaptrade_reported_currency,
     new.snaptrade_reported_amount,new.snaptrade_reported_units) is distinct from
    (old.snaptrade_activity_id,old.snaptrade_reported_on,old.snaptrade_reported_symbol,old.snaptrade_reported_currency,
     old.snaptrade_reported_amount,old.snaptrade_reported_units) then
    raise exception using errcode = '23514', message = 'The reviewed reinvestment reference is immutable.';
  end if;
  return new;
end;
$$;

revoke all on function public.preserve_reinvestment_broker_reference() from public, anon, authenticated;
create trigger portfolio_reinvestment_preserve_broker_reference
before update of snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_symbol,snaptrade_reported_currency,
  snaptrade_reported_amount,snaptrade_reported_units on public.portfolio_dividend_reinvestments
for each row execute function public.preserve_reinvestment_broker_reference();
