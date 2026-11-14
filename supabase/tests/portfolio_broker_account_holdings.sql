\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users(id) values ('ccfea891-145a-44c7-a111-000000000001'), ('ccfea891-145a-44c7-a111-000000000002');

set local role authenticated;
do $$
declare
  owner_id uuid := 'ccfea891-145a-44c7-a111-000000000001';
  other_id uuid := 'ccfea891-145a-44c7-a111-000000000002';
  sender uuid := 'ccfea891-145a-44c7-a111-000000000003';
  receiver uuid := 'ccfea891-145a-44c7-a111-000000000004';
  opening uuid := 'ccfea891-145a-44c7-a111-000000000005';
  account_a text := 'ccfea891-145a-44c7-a111-000000000006';
  account_b text := 'ccfea891-145a-44c7-a111-000000000007';
  source_holding jsonb;
  destination_holding jsonb;
  snapshot jsonb;
  send_change jsonb;
  receive_change jsonb;
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  source_holding := jsonb_build_object('id',sender,'asset_symbol','BHP','asset_name','BHP','asset_kind','Stock',
    'asset_exchange','ASX','shares',50,'avg_cost',5,'date_added','2026-06-01T00:00:00Z',
    'broker_account',jsonb_build_object('account_id',account_a,'label','Broker ••••1234','institution','Broker',
      'observed_at','2026-07-01T00:00:00.010Z','tracking',true));
  destination_holding := source_holding || jsonb_build_object('id',receiver,'shares',20);
  destination_holding := jsonb_set(destination_holding,'{broker_account,account_id}',to_jsonb(account_b));
  snapshot := jsonb_build_object('id',opening,'transaction_date','2026-06-01T00:00:00Z','shares',50,
    'price_per_share',5,'fees',0,'type','Buy','trade_provenance','{"source":"broker_position"}'::jsonb);
  send_change := jsonb_build_object('p_user_id',owner_id,'p_holding',source_holding,'p_transactions',jsonb_build_array(snapshot),
    'p_changed_ids','[]'::jsonb,'p_deleted_ids','[]'::jsonb);
  receive_change := send_change || jsonb_build_object('p_holding',destination_holding,'p_transactions','[]'::jsonb);
  perform public.sync_broker_portfolio_ledger(jsonb_build_array(send_change,receive_change));
  if (select count(*) from public.portfolio_holdings where user_id=owner_id and deleted_at is null) <> 2 then
    raise exception 'Holdings in two accounts were collapsed';
  end if;

  perform public.sync_portfolio_ledger(owner_id,(source_holding-'broker_account') || '{"shares":70}'::jsonb,'[]','{}','{}',null,null);
  update public.portfolio_holdings set deleted_at='2026-07-02T00:00:00Z' where id=sender;
  if not exists (select from public.portfolio_holdings where id=sender and shares=50 and deleted_at is null) then
    raise exception 'Old-client ticker merge affected a linked holding';
  end if;

  source_holding := jsonb_set(source_holding || '{"shares":0}', '{broker_account,observed_at}', '"2026-07-03T00:00:00.01Z"');
  destination_holding := jsonb_set(destination_holding || '{"shares":70}', '{broker_account,observed_at}', '"2026-07-03T00:00:00.01Z"');
  begin
    perform public.sync_broker_portfolio_ledger(jsonb_build_array(
      send_change || jsonb_build_object('p_holding',source_holding),
      receive_change || jsonb_build_object('p_holding',destination_holding,'p_user_id',other_id)));
    raise exception 'Wrong owner in a batch was accepted';
  exception when insufficient_privilege then null;
  end;
  if not exists (select from public.portfolio_holdings where id=sender and shares=50) then
    raise exception 'Failed batch left a partial balance update';
  end if;

  perform public.sync_broker_portfolio_ledger(jsonb_build_array(
    send_change || jsonb_build_object('p_holding',source_holding),
    receive_change || jsonb_build_object('p_holding',destination_holding)));
  perform public.sync_broker_portfolio_ledger(jsonb_build_array(send_change,receive_change));
  if not exists (select from public.portfolio_holdings where id=sender and shares=0) or
     not exists (select from public.portfolio_holdings where id=receiver and shares=70) then
    raise exception 'Batch replay changed newer account quantities';
  end if;
  if not exists (select from public.transactions where id=opening and shares=50 and deleted_at is null) then
    raise exception 'Position sync overwrote the historical snapshot';
  end if;

  begin
    perform public.sync_portfolio_ledger(owner_id,source_holding || jsonb_build_object('id',gen_random_uuid()),'[]','{}','{}',null,null);
    raise exception 'Duplicate open account listing was accepted';
  exception when unique_violation then null;
  end;
  perform set_config('request.jwt.claim.sub',other_id::text,true);
  if exists (select from public.portfolio_holdings where id in (sender,receiver)) then
    raise exception 'Another portfolio owner read brokerage account metadata';
  end if;
end
$$;
reset role;
select case when not has_function_privilege('anon','public.sync_broker_portfolio_ledger(jsonb)','execute')
  then 'ok brokerage balances publish together, retain history and reject stale writes and duplicates'
  else 'FAIL anonymous brokerage ledger permission' end;
rollback;
