\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id) values ('19dea9fb-37ab-4dbd-ac04-b6228d2a0011'), ('19dea9fb-37ab-4dbd-ac04-b6228d2a0012');
set local role authenticated;
do $$
declare
  owner_id uuid := '19dea9fb-37ab-4dbd-ac04-b6228d2a0011';
  other_id uuid := '19dea9fb-37ab-4dbd-ac04-b6228d2a0012';
  holding_id uuid := '19dea9fb-37ab-4dbd-ac04-b6228d2a0013';
  buy_id uuid := '19dea9fb-37ab-4dbd-ac04-b6228d2a0014';
  removed_id uuid := '19dea9fb-37ab-4dbd-ac04-b6228d2a0015';
  sale_id uuid := '19dea9fb-37ab-4dbd-ac04-b6228d2a0016';
  trade_time timestamptz := '2026-10-09 01:30:00.125+00';
  archive_time timestamptz := '2026-10-09 01:32:00+00';
  holding jsonb := jsonb_build_object('id',holding_id,'asset_symbol','AAPL','asset_name','Apple',
    'asset_kind','Stock','asset_exchange','NASDAQ','shares',3,'avg_cost',100,'date_added','2026-10-05T00:00:00Z');
  trades jsonb := jsonb_build_array(
    jsonb_build_object('id',buy_id,'type','Buy','shares',3,'price_per_share',100,'fees',0,'transaction_date','2026-10-05T00:00:00Z'),
    jsonb_build_object('id',removed_id,'type','Buy','shares',1,'price_per_share',120,'fees',0,'transaction_date','2026-10-07T00:00:00Z')
  );
  closing_trade jsonb := jsonb_build_array(jsonb_build_object('id',sale_id,'type','Sell','shares',3,
    'price_per_share',120,'fees',1.20,'transaction_date',trade_time));
  closed jsonb := jsonb_set(holding,'{shares}','0');
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.sync_portfolio_ledger(owner_id,holding,trades,array[buy_id],array[removed_id],null,null);
  if not exists (select from public.transactions where id = removed_id and deleted_at is not null) then
    raise exception 'Offline add and delete did not create a tombstone';
  end if;
  perform public.sync_portfolio_ledger(owner_id,holding,trades,array[removed_id],array[]::uuid[],null,null);
  if exists (select from public.transactions where id = removed_id and deleted_at is null) then
    raise exception 'A stale device resurrected a deleted transaction';
  end if;
  perform public.sync_portfolio_ledger(owner_id,holding,
    jsonb_set(trades,'{0,price_per_share}','105'),array[buy_id],array[]::uuid[],null,null);
  perform public.sync_portfolio_ledger(owner_id,holding,trades,array[]::uuid[],array[]::uuid[],null,null);
  if not exists (select from public.transactions where id = buy_id and price_per_share = 105) then
    raise exception 'An unchanged snapshot overwrote a transaction edit';
  end if;

  begin
    perform public.sync_portfolio_ledger(owner_id,closed,jsonb_set(closing_trade,'{0,shares}','-1'),array[sale_id],
      array[]::uuid[],archive_time,trade_time);
    raise exception 'An invalid closing trade was accepted';
  exception when check_violation then null;
  end;
  if exists (select from public.portfolio_holdings where id = holding_id and deleted_at is not null) then
    raise exception 'The archive survived a failed closing trade';
  end if;
  for retry in 1..2 loop
    perform public.sync_portfolio_ledger(owner_id,closed,closing_trade,array[sale_id],array[]::uuid[],archive_time,trade_time);
  end loop;
  perform public.sync_portfolio_ledger(owner_id,holding,trades,array[]::uuid[],array[]::uuid[],null,null);
  if not exists (select from public.portfolio_holdings where id = holding_id and shares = 0
    and deleted_at = archive_time and closed_at = trade_time) or
    not exists (select from public.transactions where id = sale_id and transaction_date = trade_time and fees = 1.20)
  then raise exception 'The closing sale was lost, duplicated, or reopened'; end if;

  perform set_config('request.jwt.claim.sub',other_id::text,true);
  begin
    perform public.sync_portfolio_ledger(owner_id,holding,trades,array[]::uuid[],array[]::uuid[],null,null);
    raise exception 'Another account used the owner ID';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.sync_portfolio_ledger(other_id,holding,trades,array[]::uuid[],array[]::uuid[],null,null);
  exception when insufficient_privilege then null;
  end;
  if exists (select from public.portfolio_holdings where id = holding_id) or
    exists (select from public.transactions where id in (buy_id,sale_id)) then
    raise exception 'Another account read the ledger';
  end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  if not exists (select from public.portfolio_holdings where id = holding_id and closed_at = trade_time)
    or not exists (select from public.transactions where id = buy_id and price_per_share = 105) then
    raise exception 'Another account changed the ledger';
  end if;
end $$;
reset role;
select case when not has_function_privilege('anon','public.sync_portfolio_ledger(uuid,jsonb,jsonb,uuid[],uuid[],timestamptz,timestamptz)','execute')
  then 'ok ledger changes preserve edit history, tombstones, atomic closing trades, retries, and account isolation'
  else 'FAIL anonymous ledger access' end;
rollback;
