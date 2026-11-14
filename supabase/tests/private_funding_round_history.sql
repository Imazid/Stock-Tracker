\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;
set role anon;

select case when array_agg(r.stage order by r.announced_on) =
    array['Series A follow-on', 'Series B', 'Series C']::text[]
  and array_agg(r.announced_on order by r.announced_on) =
    array[date '2025-03-03', date '2025-10-06', date '2026-09-22']
  and array_agg(r.raised order by r.announced_on) =
    array[16600000,65000000,100000000]::numeric[]
  and bool_and(r.currency = 'USD')
  and bool_and(o.status = 'closed' and o.provider = 'issuer' and o.offer_document_url is null)
  then 'ok   public Heidi round history is dated, sourced and closed' else 'FAIL Heidi round history' end
from public.funding_rounds r
join public.investment_opportunities o on o.round_id = r.id
where r.company_id = 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e01';

select case when array_agg(r.stage order by r.announced_on) = array['Series C', 'Series D']::text[]
  and array_agg(r.raised order by r.announced_on) = array[112000000,315000000]::numeric[]
  and count(r.valuation) = 0 and bool_and(o.status = 'closed')
  then 'ok   AdvanCell financing history leaves undisclosed valuations empty' else 'FAIL AdvanCell round history' end
from public.funding_rounds r
join public.investment_opportunities o on o.round_id = r.id
where r.company_id = 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e02';

select case when r.announced_on = date '2023-10-24' and r.raised is null and
    r.traction like '%over A$580,000%' and r.source_url like '%2nd-csf-raise-now-officially-closed/'
  then 'ok   rounded solar financing uses the dated issuer disclosure' else 'FAIL closed solar round source' end
from public.funding_rounds r
where r.id = 'd83bc2fc-1a39-483f-a4d5-f02cbb1e3403';

reset role;
set role service_role;
select case when count(*) = 3 and count(handoff_url) = 0
  then 'ok   newly published history has no application routes' else 'FAIL unexpected handoff route' end
from public.investment_opportunities
where id in ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e24', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e25',
             'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e26');
reset role;
rollback;
