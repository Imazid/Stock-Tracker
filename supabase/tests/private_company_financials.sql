\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;
set local role anon;

select case when count(*) = 1 and max(annual_recurring_revenue) = 50000000 and count(revenue) = 0
  and bool_and(currency = 'USD' and assurance = 'issuer_reported' and period_kind = 'month_snapshot'
    and period_end_on = date '2026-04-01' and published_on = date '2026-09-22')
  then 'ok   Heidi reports a dated USD ARR observation independently of accounting revenue'
  else 'FAIL Heidi ARR classification' end
from public.private_company_financials where id = 'a21a931d-2af3-42e8-89ca-812684ba4301';

select case when array_agg(revenue order by period_end_on) = array[1705901,1057652]::numeric[]
    and array_agg(net_profit_loss order by period_end_on) = array[-274547,-3171479]::numeric[]
    and bool_and(assurance = 'audited' and currency = 'AUD' and period_kind = 'financial_year')
    and count(annual_recurring_revenue) = 0
    and min(operating_cash_flow) = -2086708 and max(cash_and_equivalents) = 1046924
  then 'ok   Capability X periods preserve audited revenue, signed amounts and unavailable values'
  else 'FAIL Capability X annual statements' end
from public.private_company_financials where id in ('a21a931d-2af3-42e8-89ca-812684ba4302','a21a931d-2af3-42e8-89ca-812684ba4303');

reset role;
set local role service_role;
update public.private_company_financials set published = false where id = 'a21a931d-2af3-42e8-89ca-812684ba4302';
update public.private_company_financials set verified_at = now() + interval '1 day' where id = 'a21a931d-2af3-42e8-89ca-812684ba4303';
update public.private_companies set published = false where id = 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e01';

reset role;
set local role authenticated;
select case when count(*) = 0 and not has_table_privilege('public.private_company_financials', 'UPDATE')
  then 'ok   unpublished, future and unpublished-parent financials are hidden and cannot be written by clients'
  else 'FAIL financial publication or access' end
from public.private_company_financials where id in
  ('a21a931d-2af3-42e8-89ca-812684ba4301','a21a931d-2af3-42e8-89ca-812684ba4302','a21a931d-2af3-42e8-89ca-812684ba4303');
reset role;
rollback;
