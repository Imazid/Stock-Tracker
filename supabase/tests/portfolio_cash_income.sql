\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users (id) values ('f1c92b09-e488-45a2-b720-587b14dca001'), ('f1c92b09-e488-45a2-b720-587b14dca002');

set local role authenticated;
do $$
declare
  owner_id uuid := 'f1c92b09-e488-45a2-b720-587b14dca001';
  other_id uuid := 'f1c92b09-e488-45a2-b720-587b14dca002';
  activity_id text := repeat('a',64);
  payment_id uuid;
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  insert into public.portfolio_cash_income(user_id,paid_on,kind,payer,currency,cash_received,gross_amount,withholding,
    franking_credit_aud,snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_currency,snaptrade_reported_amount)
  values(owner_id,'2026-06-30','dividend','BHP','AUD',0.10000001,0.20000001,0.10,0.05,
    activity_id,'2026-07-01','AUD',0.20000001) returning id into payment_id;
  insert into public.portfolio_cash_income(user_id,paid_on,kind,payer,currency,cash_received)
  values (owner_id,'2026-06-30','distribution','ETF','AUD',0.2),
    (owner_id,'2026-07-01','substitute_dividend','Example','USD',7.35);
  if not exists (select from public.portfolio_cash_income_totals(null,null)
    where currency='AUD' and cash_received='0.30000001' and payments=2)
    or not exists (select from public.portfolio_cash_income_totals('2026-07-01',null)
      where currency='USD' and cash_received='7.35' and payments=1)
    or (select count(*) from public.portfolio_cash_income_totals('2026-07-01',null)) <> 1 then
    raise exception 'Currency totals or date filters failed';
  end if;

  begin
    insert into public.portfolio_cash_income(user_id,paid_on,kind,payer,currency,cash_received,
      snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_currency,snaptrade_reported_amount)
    values(owner_id,'2026-07-01','dividend','BHP','AUD',0.2,activity_id,'2026-07-01','AUD',0.2);
    raise exception 'Duplicate broker activity was accepted';
  exception when unique_violation then null;
  end;
  begin
    update public.portfolio_cash_income set snaptrade_reported_amount=0.1 where id=payment_id;
    raise exception 'Original reported amount could be overwritten';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.portfolio_cash_income set withholding=0.10000001 where id=payment_id;
    raise exception 'Withholding plus cash exceeded gross';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_cash_income set cash_received=0.000000001 where id=payment_id;
    raise exception 'Excess precision was accepted';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_cash_income set cash_received='NaN' where id=payment_id;
    raise exception 'Invalid amount was accepted';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_cash_income set paid_on=current_date+7 where id=payment_id;
    raise exception 'Future payment date was accepted';
  exception when check_violation then null;
  end;

  perform set_config('request.jwt.claim.sub',other_id::text,true);
  if exists (select from public.portfolio_cash_income) or exists (select from public.portfolio_cash_income_totals()) then
    raise exception 'Another owner saw private records or totals';
  end if;
  update public.portfolio_cash_income set cash_received=1 where id=payment_id;
  if found then raise exception 'Another owner edited a payment'; end if;
  delete from public.portfolio_cash_income where id=payment_id;
  if found then raise exception 'Another owner deleted a payment'; end if;
  insert into public.portfolio_cash_income(user_id,paid_on,kind,payer,currency,cash_received,
    snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_currency,snaptrade_reported_amount)
  values(other_id,'2026-07-01','dividend','BHP','AUD',0.2,activity_id,'2026-07-01','AUD',0.2);

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  update public.portfolio_cash_income set payer='BHP Group',paid_on='2026-07-01' where id=payment_id;
  if not exists (select from public.portfolio_cash_income where id=payment_id
    and payer='BHP Group' and snaptrade_reported_amount=0.20000001) then
    raise exception 'Editing a payment did not preserve the broker amount';
  end if;
  delete from public.portfolio_cash_income where id=payment_id;
  if not found then raise exception 'Owner could not remove a payment'; end if;
end $$;
reset role;
select case when not has_table_privilege('anon','public.portfolio_cash_income','select')
  and not has_function_privilege('anon','public.portfolio_cash_income_totals(date,date)','execute')
  then 'ok cash income preserves precise currency totals, statement corrections and account isolation'
  else 'FAIL anonymous grants' end;
rollback;
