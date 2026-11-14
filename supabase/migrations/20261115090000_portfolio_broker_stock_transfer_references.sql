-- A reviewed pair retains the broker's observations separately from statement dates and shares.
alter table public.portfolio_stock_transfers add column snaptrade_reference jsonb;

alter table public.portfolio_stock_transfers add constraint portfolio_stock_transfer_broker_reference_check check (
  snaptrade_reference is null or coalesce(
    jsonb_typeof(snaptrade_reference) = 'object'
    and (snaptrade_reference - array['sentId', 'receivedId', 'sentOn', 'receivedOn',
      'fromAccountId', 'toAccountId', 'symbol', 'exchange', 'shares']) = '{}'::jsonb
    and jsonb_typeof(snaptrade_reference->'shares') = 'string'
    and (snaptrade_reference->>'sentId') ~ '^[0-9a-f]{64}$'
    and (snaptrade_reference->>'receivedId') ~ '^[0-9a-f]{64}$'
    and snaptrade_reference->>'sentId' <> snaptrade_reference->>'receivedId'
    and (snaptrade_reference->>'sentOn') ~ '^\d{4}-\d{2}-\d{2}$'
    and (snaptrade_reference->>'receivedOn') ~ '^\d{4}-\d{2}-\d{2}$'
    and (snaptrade_reference->>'sentOn')::date <= (snaptrade_reference->>'receivedOn')::date
    and (snaptrade_reference->>'sentOn')::date >= date '1900-01-01'
    and (snaptrade_reference->>'receivedOn')::date <= date '9999-12-31'
    and (snaptrade_reference->>'receivedOn')::date - (snaptrade_reference->>'sentOn')::date <= 7
    and (snaptrade_reference->>'fromAccountId') ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
    and (snaptrade_reference->>'toAccountId') ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
    and snaptrade_reference->>'fromAccountId' <> snaptrade_reference->>'toAccountId'
    and char_length(btrim(snaptrade_reference->>'symbol')) between 1 and 40
    and char_length(btrim(snaptrade_reference->>'exchange')) between 1 and 12
    and (snaptrade_reference->>'shares') ~ '^(0|[1-9][0-9]{0,11})(\.[0-9]{1,18})?$'
    and (snaptrade_reference->>'shares')::numeric > 0,
    false)
);

create unique index portfolio_stock_transfer_broker_sent_key on public.portfolio_stock_transfers
  (user_id, (snaptrade_reference->>'sentId')) where snaptrade_reference is not null;
create unique index portfolio_stock_transfer_broker_received_key on public.portfolio_stock_transfers
  (user_id, (snaptrade_reference->>'receivedId')) where snaptrade_reference is not null;

grant insert (snaptrade_reference), update (snaptrade_reference) on public.portfolio_stock_transfers to authenticated;

create function public.check_stock_transfer_broker_reference() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and old.snaptrade_reference is not null and
    (old.snaptrade_reference, old.from_holding_id, old.to_holding_id) is distinct from
    (new.snaptrade_reference, new.from_holding_id, new.to_holding_id) then
    raise exception using errcode = '23514', message = 'The reviewed transfer reference and its holdings are immutable.';
  end if;
  if new.snaptrade_reference is not null and not exists (
    select from public.portfolio_holdings source
    join public.portfolio_holdings destination on destination.id = new.to_holding_id
    where source.id = new.from_holding_id and source.user_id = new.user_id and destination.user_id = new.user_id
      and source.broker_account->>'account_id' = new.snaptrade_reference->>'fromAccountId'
      and destination.broker_account->>'account_id' = new.snaptrade_reference->>'toAccountId'
      and (case upper(btrim(new.snaptrade_reference->>'exchange'))
        when 'XASX' then 'ASX' when 'XNAS' then 'NASDAQ' when 'XNYS' then 'NYSE'
        else upper(btrim(new.snaptrade_reference->>'exchange')) end) =
        (case upper(btrim(source.asset_exchange))
        when 'XASX' then 'ASX' when 'XNAS' then 'NASDAQ' when 'XNYS' then 'NYSE'
        else upper(btrim(source.asset_exchange)) end)
      and (case when upper(btrim(source.asset_exchange)) in ('ASX','XASX')
        then regexp_replace(upper(btrim(new.snaptrade_reference->>'symbol')), '\.AX$', '')
        else upper(btrim(new.snaptrade_reference->>'symbol')) end) =
        (case when upper(btrim(source.asset_exchange)) in ('ASX','XASX')
        then regexp_replace(upper(btrim(source.asset_symbol)), '\.AX$', '')
        else upper(btrim(source.asset_symbol)) end)
  ) then
    raise exception using errcode = '23514', message = 'The reviewed broker accounts must match the two holdings.';
  end if;
  return new;
end;
$$;
revoke all on function public.check_stock_transfer_broker_reference() from public, anon, authenticated;
create trigger portfolio_stock_transfer_check_broker_reference
before insert or update of snaptrade_reference, from_holding_id, to_holding_id on public.portfolio_stock_transfers
for each row execute function public.check_stock_transfer_broker_reference();
