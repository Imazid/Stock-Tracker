\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id) values ('39dea9fb-37ab-4dbd-ac04-b6228d2a0011'), ('39dea9fb-37ab-4dbd-ac04-b6228d2a0012');
insert into public.portfolio_holdings (id,user_id,asset_symbol,asset_kind,shares,avg_cost,deleted_at) values
('39dea9fb-37ab-4dbd-ac04-b6228d2a0013','39dea9fb-37ab-4dbd-ac04-b6228d2a0011','BHP','Stock',0,10,now()),
('39dea9fb-37ab-4dbd-ac04-b6228d2a0014','39dea9fb-37ab-4dbd-ac04-b6228d2a0012','BHP','Stock',3,10,null),
('39dea9fb-37ab-4dbd-ac04-b6228d2a0015','39dea9fb-37ab-4dbd-ac04-b6228d2a0011','BTC','Crypto',3,10,null);

set local role authenticated;
do $$
declare
  owner_id uuid := '39dea9fb-37ab-4dbd-ac04-b6228d2a0011';
  other_id uuid := '39dea9fb-37ab-4dbd-ac04-b6228d2a0012';
  holding uuid := '39dea9fb-37ab-4dbd-ac04-b6228d2a0013';
  other_holding uuid := '39dea9fb-37ab-4dbd-ac04-b6228d2a0014';
  crypto_holding uuid := '39dea9fb-37ab-4dbd-ac04-b6228d2a0015';
  split_id uuid;
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  insert into public.portfolio_stock_splits(user_id,holding_id,effective_date,new_shares,old_shares,statement_reference)
  values(owner_id,holding,'2026-06-01',4,1,'June statement') returning id into split_id;

  begin
    insert into public.portfolio_stock_splits(user_id,holding_id,effective_date,new_shares,old_shares)
    values(owner_id,holding,'2026-06-01',2,1);
    raise exception 'Duplicate split accepted';
  exception when unique_violation then null;
  end;
  begin
    update public.portfolio_stock_splits set new_shares=1 where id=split_id;
    raise exception 'A 1-for-1 split was accepted';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_splits set effective_date=current_date+7 where id=split_id;
    raise exception 'A future split was accepted';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_splits set holding_id=other_holding where id=split_id;
    raise exception 'Split reassigned to a different account';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.portfolio_stock_splits(user_id,holding_id,effective_date,new_shares,old_shares)
    values(owner_id,crypto_holding,'2026-06-01',2,1);
    raise exception 'Crypto holding received a stock split';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.portfolio_stock_splits(user_id,holding_id,effective_date,new_shares,old_shares)
    values(other_id,other_holding,'2026-06-01',2,1);
    raise exception 'Caller impersonated a different user';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub',other_id::text,true);
  if exists (select from public.portfolio_stock_splits where id=split_id) then
    raise exception 'Split visible to another account';
  end if;
  update public.portfolio_stock_splits set new_shares=2 where id=split_id;
  if found then raise exception 'Another account edited a split'; end if;
  delete from public.portfolio_stock_splits where id=split_id;
  if found then raise exception 'Another account deleted a split'; end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  update public.portfolio_stock_splits set new_shares=2 where id=split_id;
  if not exists (select from public.portfolio_stock_splits where id=split_id and new_shares=2) then
    raise exception 'Owner edit failed';
  end if;
  delete from public.portfolio_stock_splits where id=split_id;
  if not found then raise exception 'Owner removal failed'; end if;
end $$;
reset role;
select case when not has_table_privilege('anon','public.portfolio_stock_splits','select')
  and not has_column_privilege('authenticated','public.portfolio_stock_splits','user_id','update')
  then 'ok stock splits allow only owner actions, enforce ratios and dates, and prevent duplicates'
  else 'FAIL stock split grants' end;
rollback;
