\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users(id,email) values
  ('11111111-0000-4000-8000-000000000011','fractions-one@example.test'),
  ('11111111-0000-4000-8000-000000000012','fractions-two@example.test');
insert into public.portfolio_holdings (id,user_id,asset_symbol,asset_name,asset_kind,asset_exchange,shares,avg_cost,date_added)
values ('11111111-0000-4000-8000-000000000013','11111111-0000-4000-8000-000000000011','BHP','BHP','Stock','ASX',1,75,'2025-01-08');

set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-0000-4000-8000-000000000011',true);
insert into public.portfolio_stock_splits (user_id,holding_id,effective_date,new_shares,old_shares,statement_reference,
  fraction_shares,fraction_paid_on,fraction_currency,fraction_proceeds,fraction_fees,fraction_net_usd)
values ('11111111-0000-4000-8000-000000000011','11111111-0000-4000-8000-000000000013','2025-02-03',1,2,'Statement A',
  '0.500000000000000001','2025-02-06','AUD','60.25000001','0.25','39.50');

do $$
begin
  begin
    update public.portfolio_stock_splits set fraction_paid_on='2025-02-02';
    raise exception 'accepted payment before split';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_splits set fraction_fees='61';
    raise exception 'accepted fees above gross cash';
  exception when check_violation then null;
  end;
  begin
    update public.portfolio_stock_splits set fraction_shares=null;
    raise exception 'accepted missing quantity';
  exception when check_violation then null;
  end;
end $$;

select case when exists (
  select from public.portfolio_stock_splits where fraction_shares='0.500000000000000001' and fraction_proceeds='60.25000001'
    and fraction_net_usd='39.50' and fraction_fees='0.25' and fraction_currency='AUD'
) then 'ok statement fractions retain entered decimal precision' else 'FAIL fraction precision' end;

select set_config('request.jwt.claim.sub','11111111-0000-4000-8000-000000000012',true);
select case when not exists (select from public.portfolio_stock_splits)
  then 'ok another account cannot see the fractional payment' else 'FAIL wrong user can read payment' end;

do $$
begin
  begin
    insert into public.portfolio_stock_splits (user_id,holding_id,effective_date,new_shares,old_shares)
    values ('11111111-0000-4000-8000-000000000012','11111111-0000-4000-8000-000000000013','2025-02-04',1,2);
    raise exception 'accepted a split for another account';
  exception when insufficient_privilege then null;
  end;
end $$;

select set_config('request.jwt.claim.sub','11111111-0000-4000-8000-000000000011',true);
update public.portfolio_stock_splits set fraction_shares=null,fraction_paid_on=null,fraction_currency=null,
  fraction_fees=null,fraction_proceeds=null,fraction_net_usd=null;
select case when exists (select from public.portfolio_stock_splits where fraction_shares is null and new_shares=1)
  then 'ok removing the payment keeps the original split adjustment' else 'FAIL split correction' end;
rollback;
