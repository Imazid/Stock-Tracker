\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id) values ('29dea9fb-37ab-4dbd-ac04-b6228d2a0011'), ('29dea9fb-37ab-4dbd-ac04-b6228d2a0012');
set local role authenticated;
do $$
declare
  owner_id uuid := '29dea9fb-37ab-4dbd-ac04-b6228d2a0011';
  other_id uuid := '29dea9fb-37ab-4dbd-ac04-b6228d2a0012';
  holding_id uuid := '29dea9fb-37ab-4dbd-ac04-b6228d2a0013';
  buy_id uuid := '29dea9fb-37ab-4dbd-ac04-b6228d2a0014';
  legacy_id uuid := '29dea9fb-37ab-4dbd-ac04-b6228d2a0015';
  snapshot_id uuid := '29dea9fb-37ab-4dbd-ac04-b6228d2a0016';
  provenance jsonb := '{"source":"manual_trade","currency":"AUD","unitPrice":150,"fees":3,"usdPerUnit":0.65,
    "conversion":"app_reference","conversionRecordedAt":"2026-11-13T22:00:00Z"}';
  holding jsonb := jsonb_build_object('id',holding_id,'asset_symbol','BHP','asset_name','BHP','asset_kind','Stock',
    'asset_exchange','ASX','shares',6,'avg_cost',97.5,'date_added','2026-10-05T00:00:00Z');
  trade jsonb := jsonb_build_object('id',buy_id,'type','Buy','shares',2,'price_per_share',97.5,
    'fees',1.95,'transaction_date','2026-10-05T00:00:00.125Z');
  saved jsonb;
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.sync_portfolio_ledger(owner_id,holding,jsonb_build_array(
    trade || jsonb_build_object('trade_provenance',provenance),
    trade || jsonb_build_object('id',legacy_id),
    trade || jsonb_build_object('id',snapshot_id,'trade_provenance',jsonb_build_object('source','broker_position'))
  ),array[buy_id,legacy_id,snapshot_id],array[]::uuid[],null,null);
  if (select trade_provenance from public.transactions where id = buy_id) is distinct from provenance
    or not exists (select from public.transactions where id = legacy_id and trade_provenance is null)
    or not exists (select from public.transactions where id = snapshot_id and trade_provenance = '{"source":"broker_position"}')
  then raise exception 'Saved provenance differs from the input or legacy rows were populated'; end if;

  -- The previous iPhone client's RPC omits provenance even when the trade has it.
  perform public.sync_portfolio_ledger(owner_id,holding,jsonb_build_array(jsonb_set(trade,'{shares}','3')),
    array[buy_id],array[]::uuid[],null,null);
  if (select trade_provenance from public.transactions where id = buy_id) is distinct from provenance then
    raise exception 'A quantity edit discarded original amounts';
  end if;
  perform public.sync_portfolio_ledger(owner_id,holding,jsonb_build_array(jsonb_set(trade,'{fees}','4')),
    array[buy_id],array[]::uuid[],null,null);
  select trade_provenance into saved from public.transactions where id = buy_id;
  if saved is distinct from provenance - 'fees' then raise exception 'Stale fee or unchanged price was retained incorrectly'; end if;

  -- The older direct REST write path also keeps only original values it can still explain.
  update public.transactions set price_per_share = 98 where id = buy_id;
  if (select trade_provenance from public.transactions where id = buy_id) is distinct from '{"source":"manual_trade"}'::jsonb then
    raise exception 'The old write path left an incorrect original price';
  end if;

  begin
    perform public.sync_portfolio_ledger(owner_id,holding,jsonb_build_array(trade || jsonb_build_object('trade_provenance',
      jsonb_set(provenance,'{usdPerUnit}','0'))),array[buy_id],array[]::uuid[],null,null);
    raise exception 'An invalid FX factor was accepted';
  exception when check_violation then null;
  end;
  perform set_config('request.jwt.claim.sub',other_id::text,true);
  if exists (select from public.transactions where id in (buy_id,legacy_id,snapshot_id)) then
    raise exception 'Another account read the trade provenance';
  end if;
end $$;
reset role;
select 'ok original trade amounts, position snapshots, old-client updates, FX validation and account isolation';
rollback;
