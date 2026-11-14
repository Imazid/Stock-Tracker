\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users(id,email) values
  ('bbaa0000-0000-4000-8000-000000000001','spin-off-one@example.test'),
  ('bbaa0000-0000-4000-8000-000000000002','spin-off-two@example.test');
insert into public.portfolio_holdings (id,user_id,asset_symbol,asset_kind,asset_exchange,shares,avg_cost) values
  ('bbaa0000-0000-4000-8000-000000000011','bbaa0000-0000-4000-8000-000000000001','BHP','Stock','ASX',280,10),
  ('bbaa0000-0000-4000-8000-000000000012','bbaa0000-0000-4000-8000-000000000001','BSL','Stock','ASX',56,0),
  ('bbaa0000-0000-4000-8000-000000000013','bbaa0000-0000-4000-8000-000000000002','BSL','Stock','ASX',56,0),
  ('bbaa0000-0000-4000-8000-000000000014','bbaa0000-0000-4000-8000-000000000001','bhp','Stock','asx',50,0);
insert into public.transactions (id,user_id,holding_id,transaction_date,shares,price_per_share,type,trade_provenance) values
  ('bbaa0000-0000-4000-8000-000000000021','bbaa0000-0000-4000-8000-000000000001',
   'bbaa0000-0000-4000-8000-000000000012','2025-06-03',56,0,'Buy','{"source":"broker_position"}'),
  ('bbaa0000-0000-4000-8000-000000000022','bbaa0000-0000-4000-8000-000000000001',
   'bbaa0000-0000-4000-8000-000000000012','2025-06-03',56,2,'Buy','{"source":"manual_trade","currency":"USD","unitPrice":2,"fees":0,"usdPerUnit":1,"conversion":"usd","conversionRecordedAt":"2025-06-03T00:00:00Z"}');

set local role authenticated;
select set_config('request.jwt.claim.sub','bbaa0000-0000-4000-8000-000000000001',true);
insert into public.portfolio_stock_spin_offs
  (user_id,parent_holding_id,child_holding_id,effective_on,parent_shares,child_shares,child_basis_pct_usd,child_basis_pct_aud,
   average_aud_basis,statement_reference,child_snapshot_id)
values ('bbaa0000-0000-4000-8000-000000000001','bbaa0000-0000-4000-8000-000000000011',
  'bbaa0000-0000-4000-8000-000000000012','2025-06-01',280.000000000000000001,56,null,5.063000000001,true,'Illustrative issuer reference',
  'bbaa0000-0000-4000-8000-000000000021');

select case when exists (select from public.portfolio_stock_spin_offs
  where parent_shares::text = '280.000000000000000001' and child_basis_pct_aud::text = '5.063000000001')
  then 'ok statement quantities and percentages retain exact precision' else 'FAIL precision' end;

do $$
begin
  begin
    update public.portfolio_stock_spin_offs set child_holding_id='bbaa0000-0000-4000-8000-000000000013', child_snapshot_id=null;
    raise exception 'accepted a holding from another owner';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_spin_offs set child_holding_id='bbaa0000-0000-4000-8000-000000000014', child_snapshot_id=null;
    raise exception 'accepted a duplicate listing';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_spin_offs set child_snapshot_id='bbaa0000-0000-4000-8000-000000000022';
    raise exception 'accepted an actual trade as a snapshot';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_spin_offs set child_basis_pct_aud=null;
    raise exception 'accepted a missing allocation';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_spin_offs set child_shares=55;
    raise exception 'accepted a snapshot quantity mismatch';
  exception when check_violation then null;
  end;
end $$;
select 'ok distinct owned holdings, valid allocation and matching imported snapshot are enforced';

select set_config('request.jwt.claim.sub','bbaa0000-0000-4000-8000-000000000002',true);
select case when not exists (select from public.portfolio_stock_spin_offs)
  and (select count(*) from (select id from public.portfolio_stock_spin_offs) records) = 0
  then 'ok another account cannot view the spin-off' else 'FAIL owner isolation' end;
do $$
begin
  update public.portfolio_stock_spin_offs set statement_reference='another owner';
  if found then raise exception 'edited another owner spin-off'; end if;
  delete from public.portfolio_stock_spin_offs;
  if found then raise exception 'removed another owner spin-off'; end if;
end $$;

select set_config('request.jwt.claim.sub','bbaa0000-0000-4000-8000-000000000001',true);
update public.portfolio_stock_spin_offs set child_basis_pct_usd=12, statement_reference='Corrected statement';
select case when exists (select from public.portfolio_stock_spin_offs where child_basis_pct_usd=12 and statement_reference='Corrected statement')
  then 'ok owner can correct a reported allocation' else 'FAIL correction' end;
delete from public.portfolio_stock_spin_offs;
select case when not exists (select from public.portfolio_stock_spin_offs) and exists (select from public.transactions
  where id='bbaa0000-0000-4000-8000-000000000021')
  then 'ok removing the action preserves the imported transaction' else 'FAIL removal' end;
set local role anon;
do $$
begin
  begin
    perform id from public.portfolio_stock_spin_offs;
    raise exception 'guest has table access';
  exception when insufficient_privilege then null;
  end;
end $$;
select 'ok guests cannot access the table';
rollback;
