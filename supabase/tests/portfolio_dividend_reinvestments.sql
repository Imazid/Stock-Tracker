\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users (id) values ('ce0e3600-7749-4d32-8e40-2cd06e892001'), ('ce0e3600-7749-4d32-8e40-2cd06e892002');
insert into public.portfolio_holdings(id,user_id,asset_symbol,asset_kind,shares,avg_cost,deleted_at) values
  ('ce0e3600-7749-4d32-8e40-2cd06e892003','ce0e3600-7749-4d32-8e40-2cd06e892001','BHP','Stock',0,10,now()),
  ('ce0e3600-7749-4d32-8e40-2cd06e892004','ce0e3600-7749-4d32-8e40-2cd06e892002','BHP','Stock',1,10,null),
  ('ce0e3600-7749-4d32-8e40-2cd06e892005','ce0e3600-7749-4d32-8e40-2cd06e892001','BTC','Crypto',1,10,null);

set local role authenticated;
do $$
declare
  owner_id uuid := 'ce0e3600-7749-4d32-8e40-2cd06e892001';
  other_id uuid := 'ce0e3600-7749-4d32-8e40-2cd06e892002';
  owned_holding uuid := 'ce0e3600-7749-4d32-8e40-2cd06e892003';
  other_holding uuid := 'ce0e3600-7749-4d32-8e40-2cd06e892004';
  crypto_holding uuid := 'ce0e3600-7749-4d32-8e40-2cd06e892005';
  entry uuid;
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  insert into public.portfolio_dividend_reinvestments(user_id,holding_id,paid_on,acquired_on,currency,dividend_amount,reinvested_amount,shares)
  values(owner_id,owned_holding,'2026-06-30','2026-07-01','AUD',19,20,1.000000000000000001) returning id into entry;
  begin
    insert into public.portfolio_dividend_reinvestments(user_id,holding_id,paid_on,acquired_on,currency,dividend_amount,reinvested_amount,shares)
    values(owner_id,owned_holding,'2026-06-30','2026-07-01','AUD',19,20,1.000000000000000001);
    raise exception 'Identical reinvestment was accepted';
  exception when unique_violation then null;
  end;
  begin
    update public.portfolio_dividend_reinvestments set holding_id=other_holding where id=entry;
    raise exception 'Another owner holding accepted a reinvestment';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.portfolio_dividend_reinvestments set holding_id=crypto_holding where id=entry;
    raise exception 'Crypto holding accepted a reinvestment';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.portfolio_dividend_reinvestments set currency='USD',basis_usd=5 where id=entry;
    raise exception 'Inconsistent USD basis was accepted';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_dividend_reinvestments set shares=0.0000000000000000001 where id=entry;
    raise exception 'Excess share precision was accepted';
  exception when check_violation then null;
  end;
  if not exists (select from public.portfolio_dividend_reinvestments where id=entry and shares::text='1.000000000000000001') then
    raise exception 'The original quantity was rounded';
  end if;
  begin
    update public.portfolio_dividend_reinvestments set snaptrade_reported_on='2026-07-03' where id=entry;
    raise exception 'Incomplete broker reference was accepted';
  exception when check_violation then null;
  end;
  update public.portfolio_dividend_reinvestments set snaptrade_activity_id=repeat('c',64),
    snaptrade_reported_on='2026-07-03', snaptrade_reported_symbol='BHP', snaptrade_reported_currency='AUD',
    snaptrade_reported_amount=-20.01, snaptrade_reported_units=1.25 where id=entry;
  if not found then raise exception 'Could not link a manual record'; end if;
  begin
    update public.portfolio_dividend_reinvestments set snaptrade_reported_amount=-19 where id=entry;
    raise exception 'Saved broker metadata was overwritten';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_dividend_reinvestments set snaptrade_activity_id=null, snaptrade_reported_on=null,
      snaptrade_reported_symbol=null,snaptrade_reported_currency=null,snaptrade_reported_amount=null,
      snaptrade_reported_units=null where id=entry;
    raise exception 'Saved broker reference was cleared';
  exception when check_violation then null;
  end;
  begin
    insert into public.portfolio_dividend_reinvestments(user_id,holding_id,paid_on,acquired_on,currency,dividend_amount,
      reinvested_amount,shares,snaptrade_activity_id,snaptrade_reported_on)
    values(owner_id,owned_holding,'2026-07-01','2026-07-02','AUD',21,22,2,repeat('c',64),'2026-07-03');
    raise exception 'Duplicate broker reference was accepted';
  exception when unique_violation then null;
  end;
  perform set_config('request.jwt.claim.sub',other_id::text,true);
  if exists (select from public.portfolio_dividend_reinvestments where id=entry) then
    raise exception 'An outsider read a reinvestment';
  end if;
  delete from public.portfolio_dividend_reinvestments where id=entry;
  if found then raise exception 'An outsider deleted a reinvestment'; end if;
  update public.portfolio_dividend_reinvestments set statement_reference='Outsider' where id=entry;
  if found then raise exception 'An outsider edited a reinvestment'; end if;
  insert into public.portfolio_dividend_reinvestments(user_id,holding_id,paid_on,acquired_on,currency,dividend_amount,
    reinvested_amount,shares,snaptrade_activity_id,snaptrade_reported_on)
  values(other_id,other_holding,'2026-07-01','2026-07-02','AUD',21,22,2,repeat('c',64),'2026-07-03');
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  update public.portfolio_dividend_reinvestments set basis_usd=13.27 where id=entry;
  if not found then raise exception 'The owner could not edit'; end if;
  if not exists (select from public.portfolio_dividend_reinvestments where id=entry and
    snaptrade_reported_amount=-20.01 and snaptrade_reported_units=1.25 and snaptrade_reported_on='2026-07-03') then
    raise exception 'Statement edits changed reviewed source metadata';
  end if;
  if exists (select from public.portfolio_cash_income_totals(null,null)) then
    raise exception 'Reinvested amount was counted as cash';
  end if;
end $$;
reset role;
select case when not has_table_privilege('anon','public.portfolio_dividend_reinvestments','select')
  then 'ok reinvestments enforce ownership, exact decimals, immutable broker references, unique entries and separate cash totals'
  else 'FAIL anonymous reinvestment grants' end;
rollback;
