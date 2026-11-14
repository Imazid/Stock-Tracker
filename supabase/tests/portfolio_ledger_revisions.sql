\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users(id) values
 ('92c00000-0000-4000-8000-000000000001'), ('92c00000-0000-4000-8000-000000000002');
set local role authenticated;

do $$
declare
  owner_id uuid := '92c00000-0000-4000-8000-000000000001';
  another_id uuid := '92c00000-0000-4000-8000-000000000002';
  holding_id uuid := gen_random_uuid();
  opening_id uuid := gen_random_uuid();
  first_buy uuid := gen_random_uuid();
  second_buy uuid := gen_random_uuid();
  sale_id uuid := gen_random_uuid();
  second_mutation uuid := gen_random_uuid();
  base jsonb := jsonb_build_object('id',holding_id,'asset_symbol','QQQ','asset_name','Invesco QQQ',
    'asset_kind','ETF','asset_exchange','US','shares',10,'avg_cost',100,'date_added','2026-10-01T00:00:00Z');
  opening jsonb := jsonb_build_object('id',opening_id,'transaction_date','2026-10-01T00:00:00Z',
    'shares',10,'price_per_share',100,'type','Buy','fees',0);
  buy_a jsonb := jsonb_build_object('id',first_buy,'transaction_date','2026-10-02T00:00:00Z',
    'shares',2,'price_per_share',124,'type','Buy','fees',2);
  buy_b jsonb := jsonb_build_object('id',second_buy,'transaction_date','2026-10-03T00:00:00Z',
    'shares',3,'price_per_share',116,'type','Buy','fees',2);
  sale jsonb := jsonb_build_object('id',sale_id,'transaction_date','2026-10-04T00:00:00Z',
    'shares',9,'price_per_share',117,'type','Sell','fees',0,'avg_cost_at_sale',100);
  starting uuid;
  newest uuid;
  revision_after_web uuid;
  result jsonb;
  recovered jsonb;
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  result := public.apply_portfolio_ledger_change(owner_id,base,jsonb_build_array(opening),array[opening_id],
    '{}',null,null,gen_random_uuid(),null);
  starting := (result->>'revision')::uuid;
  assert result->>'status' = 'applied' and starting is not null, 'Create with a new holding ID failed';

  result := public.apply_portfolio_ledger_change(owner_id,base || jsonb_build_object('shares',12,'avg_cost',1250::numeric/12),
    jsonb_build_array(opening,buy_a),array[first_buy],'{}',null,null,gen_random_uuid(),starting);
  assert result->>'status' = 'applied' and result->>'merged' = 'false', 'Current edit failed';

  result := public.apply_portfolio_ledger_change(owner_id,base || jsonb_build_object('shares',13,'avg_cost',1350::numeric/13),
    jsonb_build_array(opening,buy_b),array[second_buy],'{}',null,null,second_mutation,starting);
  newest := (result->>'revision')::uuid;
  assert result->>'status' = 'applied' and result->>'merged' = 'true', 'Independent buys did not merge';
  assert (select shares=15 and abs(avg_cost-1600::double precision/15)<1e-9 from public.portfolio_holdings where id=holding_id),
    'Merge lost quantity, basis, or fees';

  result := public.apply_portfolio_ledger_change(owner_id,base || jsonb_build_object('shares',1),
    jsonb_build_array(opening,sale),array[sale_id],'{}',null,null,gen_random_uuid(),starting);
  assert result->>'status' = 'conflict' and not exists(select from public.transactions where id=sale_id),
    'Stale sale partly wrote to the ledger';
  result := public.apply_portfolio_ledger_change(owner_id,base,jsonb_build_array(opening),'{}',array[first_buy],null,null,gen_random_uuid(),starting);
  assert result->>'status' = 'conflict', 'Stale deletion succeeded';

  update public.portfolio_holdings set avg_cost=115 where id=holding_id;
  select ledger_revision into revision_after_web from public.portfolio_holdings where id=holding_id;
  assert revision_after_web is distinct from newest, 'A web update did not change the revision';
  result := public.apply_portfolio_ledger_change(owner_id,base,jsonb_build_array(opening),'{}','{}',null,null,second_mutation,starting);
  assert (result->>'revision')::uuid = newest and result->>'merged' = 'true', 'A retry did not return the original result';
  assert (select shares=15 and avg_cost=115 from public.portfolio_holdings where id=holding_id), 'A retry overwrote a later edit';

  update public.transactions set fees=4 where id = second_buy;
  select holding into recovered from public.read_portfolio_ledger_page(owner_id,null);
  assert (recovered->>'ledger_revision')::uuid is distinct from revision_after_web, 'Direct trade edit left the holding revision current';
  assert (select jsonb_array_length(transactions) from public.read_portfolio_ledger_page(owner_id,null)) = 3,
    'The holding snapshot did not include its current ledger';

  perform set_config('request.jwt.claim.sub',another_id::text,true);
  assert not exists(select from public.read_portfolio_ledger_page(owner_id,null)), 'Another owner could read the ledger';
  begin
    perform public.apply_portfolio_ledger_change(owner_id,base,jsonb_build_array(opening),'{}','{}',null,null,gen_random_uuid(),newest);
    raise exception 'Another owner could edit the ledger';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
-- Reproduce the Auth role's narrow permissions without granting the test
-- runner membership in Supabase's managed role.
create role ledger_auth_fixture nologin;
grant usage on schema auth to ledger_auth_fixture;
grant select(id), delete on auth.users to ledger_auth_fixture;
grant ledger_auth_fixture to postgres;
set local role ledger_auth_fixture;
delete from auth.users where id = '92c00000-0000-4000-8000-000000000001';
reset role;
do $$ begin
  assert not exists (select from public.portfolio_holdings where user_id='92c00000-0000-4000-8000-000000000001'),
    'Deleting a user left their holding behind';
  assert not exists (select from portfolio_sync.holding_change_receipts where user_id='92c00000-0000-4000-8000-000000000001'),
    'Deleting a user left their receipts behind';
end $$;
select 'ok   holding revisions guard stale writes and safe purchases reconcile atomically with replay receipts';
rollback;
