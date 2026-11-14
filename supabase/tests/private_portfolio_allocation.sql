\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id,email) values
  ('ad000000-0000-4000-8000-000000000001','private-allocation-fixture@example.test'),
  ('ad000000-0000-4000-8000-000000000002','second-private-allocation-fixture@example.test');

create temporary table allocation_fixture (id uuid, class text, currency text, value numeric, mark_age integer, remaining numeric, sale_age integer, revision_age integer, reported_age integer);
insert into allocation_fixture values
  ('ad000000-0000-4000-8000-000000000010','Startup equity','AUD',250,1,10,null,null,1),
  ('ad000000-0000-4000-8000-000000000011','Startup equity','AUD',100,95,10,null,null,95),
  ('ad000000-0000-4000-8000-000000000012','Startup equity','AUD',120,15,5,14,13,15),
  ('ad000000-0000-4000-8000-000000000013','Startup equity','AUD',888,20,0,19,18,20),
  ('ad000000-0000-4000-8000-000000000014','Venture fund','USD',0,1,10,null,null,1),
  ('ad000000-0000-4000-8000-000000000015','Venture fund','USD',9000,-2,10,null,null,-1),
  ('ad000000-0000-4000-8000-000000000016','Private equity','EUR',780,3,6,6,5,2);

insert into public.private_companies (id,name,sector,country,source_url,verified_at) values
  ('ad000000-0000-4000-8000-000000000004','Private allocation test issuer','Technology','AU','https://example.test/company',now());
insert into public.funding_rounds (id,company_id,stage,currency,source_url,verified_at) values
  ('ad000000-0000-4000-8000-000000000005','ad000000-0000-4000-8000-000000000004','Seed','AUD','https://example.test/round',now());
insert into public.investment_opportunities
  (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,verified_at)
select id, 'ad000000-0000-4000-8000-000000000005', 'birchal','Crowdfunding','closed',50,'retail',
  array['AU'],'https://example.test/round/' || id,now() from allocation_fixture;
insert into public.investment_commitments
  (id,user_id,opportunity_id,provider,jurisdiction,rule_version,reviewed_document_url,requested_amount,currency,
   acknowledged_at,status,provider_reference,confirmed_at)
select gen_random_uuid(), 'ad000000-0000-4000-8000-000000000001',f.id,
 'birchal','AU',r.version,'https://example.test/round',100,f.currency,now()-interval '150 days','confirmed',f.id::text,now()-interval '149 days'
from allocation_fixture f cross join lateral (select version from public.private_market_rules where jurisdiction='AU' order by version desc limit 1) r;
insert into public.private_holdings
  (id,user_id,commitment_id,name,asset_class,currency,units,remaining_units,settled_amount,
    confirmed_at,last_disposition_on,disposition_revision_at,exit_source)
select f.id,c.user_id,c.id,'Private test holding',f.class,f.currency,10,f.remaining,100,c.confirmed_at,
  (now() at time zone 'Australia/Sydney')::date-f.sale_age,now()-f.revision_age*interval '1 day',
  case when f.remaining=0 then 'Sale confirmation' end
from allocation_fixture f join public.investment_commitments c on c.provider_reference=f.id::text;
insert into public.valuation_history (user_id,holding_id,value,valued_on,source,methodology,provider_event_at)
select 'ad000000-0000-4000-8000-000000000001',f.id,f.value,
  (now() at time zone 'Australia/Sydney')::date-f.mark_age,'Provider statement','NAV',now()-f.reported_age*interval '1 day'
from allocation_fixture f;
-- Two reports on the same date. The newer provider event takes precedence.
insert into public.valuation_history (user_id,holding_id,value,valued_on,source,methodology,provider_event_at)
values ('ad000000-0000-4000-8000-000000000001','ad000000-0000-4000-8000-000000000010',400,
  (now() at time zone 'Australia/Sydney')::date-1,'Provider revision','NAV',now()-interval '12 hours');

select case when not has_function_privilege('anon','public.private_portfolio_allocation(uuid)','execute')
  and not has_function_privilege('authenticated','public.private_portfolio_allocation(uuid)','execute')
  and has_function_privilege('service_role','public.private_portfolio_allocation(uuid)','execute')
  then 'ok allocation RPC requires the service role' else 'FAIL allocation grants' end;
set role service_role;
select case when count(*)=1 and bool_and(position_count=3 and valued_count=2 and stale_count=1 and carrying_value::numeric=500
  and oldest_valuation=(now() at time zone 'Australia/Sydney')::date-95)
  then 'ok allocation uses the revised mark, labels stale values and excludes confirmed exits'
  else 'FAIL wrong startup totals' end
from public.private_portfolio_allocation('ad000000-0000-4000-8000-000000000001') where asset_class='Startup equity';
select case when count(*)=1 and bool_and(position_count=2 and valued_count=1 and carrying_value::numeric=0)
  then 'ok zero mark remains valid and a future mark adds no value'
  else 'FAIL wrong venture fund totals' end
from public.private_portfolio_allocation('ad000000-0000-4000-8000-000000000001') where asset_class='Venture fund';
select case when count(*)=1 and bool_and(position_count=1 and valued_count=1 and carrying_value::numeric=780)
  then 'ok only a post-sale valuation contributes after a partial disposition'
  else 'FAIL partial sale mark' end
from public.private_portfolio_allocation('ad000000-0000-4000-8000-000000000001') where asset_class='Private equity';
select case when count(*)=0 then 'ok second account has no provider allocation' else 'FAIL cross-account exposure' end
from public.private_portfolio_allocation('ad000000-0000-4000-8000-000000000002');
reset role;
rollback;
