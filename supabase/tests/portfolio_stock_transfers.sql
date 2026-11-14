\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users(id) values ('aa6adefa-745c-4947-a095-cc9000000001'), ('aa6adefa-745c-4947-a095-cc9000000002');
insert into public.portfolio_holdings(id,user_id,asset_symbol,asset_exchange,asset_kind,shares,avg_cost) values
  ('aa6adefa-745c-4947-a095-cc9000000003','aa6adefa-745c-4947-a095-cc9000000001','BHP','ASX','Stock',3,5),
  ('aa6adefa-745c-4947-a095-cc9000000004','aa6adefa-745c-4947-a095-cc9000000001','BHP','ASX','Stock',2,0),
  ('aa6adefa-745c-4947-a095-cc9000000005','aa6adefa-745c-4947-a095-cc9000000001','BHP','NYSE','Stock',2,0),
  ('aa6adefa-745c-4947-a095-cc9000000006','aa6adefa-745c-4947-a095-cc9000000002','BHP','ASX','Stock',2,0);
insert into public.transactions(id,user_id,holding_id,transaction_date,shares,price_per_share,type,trade_provenance) values
  ('aa6adefa-745c-4947-a095-cc9000000007','aa6adefa-745c-4947-a095-cc9000000001','aa6adefa-745c-4947-a095-cc9000000004',
    '2026-07-03T00:00:00Z',2.25,0,'Buy','{"source":"broker_position"}');
set local role authenticated;
do $$
declare
  owner_id uuid := 'aa6adefa-745c-4947-a095-cc9000000001';
  other_id uuid := 'aa6adefa-745c-4947-a095-cc9000000002';
  sender uuid := 'aa6adefa-745c-4947-a095-cc9000000003';
  receiver uuid := 'aa6adefa-745c-4947-a095-cc9000000004';
  different_listing uuid := 'aa6adefa-745c-4947-a095-cc9000000005';
  other_receiver uuid := 'aa6adefa-745c-4947-a095-cc9000000006';
  snapshot uuid := 'aa6adefa-745c-4947-a095-cc9000000007';
  transfer_id uuid;
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  insert into public.portfolio_stock_transfers(user_id,from_holding_id,to_holding_id,sent_on,received_on,shares,from_account,to_account,receiving_snapshot_id)
  values(owner_id,sender,receiver,'2026-07-01','2026-07-02',2.25,'Broker A','Broker B',snapshot) returning id into transfer_id;
  begin
    update public.portfolio_stock_transfers set to_holding_id=different_listing,receiving_snapshot_id=null where id=transfer_id;
    raise exception 'Different listing was accepted';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_transfers set to_holding_id=other_receiver,receiving_snapshot_id=null where id=transfer_id;
    raise exception 'Different owner was accepted';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_transfers set shares=2.5 where id=transfer_id;
    raise exception 'Mismatched snapshot was accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.portfolio_stock_transfers(user_id,from_holding_id,to_holding_id,sent_on,received_on,shares,from_account,to_account,same_day_order,receiving_snapshot_id)
    values(owner_id,sender,receiver,'2026-06-29','2026-07-03',2.25,'Broker A','Broker B',2,snapshot);
    raise exception 'Reused snapshot was accepted';
  exception when unique_violation then null;
  end;
  begin
    insert into public.portfolio_stock_transfers(user_id,from_holding_id,to_holding_id,sent_on,received_on,shares,from_account,to_account)
    values(owner_id,sender,receiver,'2026-07-01','2026-07-02',1,'Broker A','Broker B');
    raise exception 'Ambiguous same-day transfer order was accepted';
  exception when unique_violation then null;
  end;
  perform set_config('request.jwt.claim.sub',other_id::text,true);
  if exists (select from public.portfolio_stock_transfers where id=transfer_id) then
    raise exception 'Outsider read a transfer';
  end if;
  delete from public.portfolio_stock_transfers where id=transfer_id;
  if found then raise exception 'Outsider removed a transfer'; end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  update public.portfolio_stock_transfers set statement_reference='reconciled' where id=transfer_id;
  if not found then raise exception 'Owner could not update a transfer'; end if;
end
$$;
reset role;
select case when not has_table_privilege('anon','public.portfolio_stock_transfers','select')
  then 'ok stock transfers enforce ownership, listing, ordered departures and unique receiving snapshot'
  else 'FAIL anonymous stock transfer grants' end;
rollback;
