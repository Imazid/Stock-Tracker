\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;
set role anon;

select case when count(*) = 3
    and bool_and(o.status = 'closed' and o.provider = 'issuer' and o.offer_document_url is null
      and o.minimum is null and cardinality(o.jurisdictions) = 0 and o.source_url = r.source_url)
    and count(r.raised) = 0 and count(r.valuation) = 0 and count(r.closes_at) = 0
    and array_agg(r.capital_commitments order by c.name) = array[1050000000, 3200000000, null]::numeric[]
    and array_agg(o.category order by c.name) = array['Venture fund', 'Private equity', 'Syndicate or SPV']
    and array_agg(r.financing_structure order by c.name) = array['fund', 'fund', 'spv']
    and array_agg(r.announced_on order by c.name) = array[date '2026-08-25', date '2025-08-05', null]
  then 'ok   public records preserve published commitments, dates and structure'
  else 'FAIL historical fund and vehicle records' end
from public.investment_opportunities o
join public.funding_rounds r on r.id = o.round_id
join public.private_companies c on c.id = r.company_id
where o.id in ('d959a869-785e-465c-9af8-978d10f608cd', '7e62db81-26b8-4807-b211-fa738b0d816a',
               '9009357f-e507-43b0-9eba-76944953e4aa');

reset role;
set role service_role;

select case when count(*) = 2
    and bool_and(source_label = 'Fund disclosure' and position('Reported capital commitments were AUD' in significance) > 0
      and position('Reported valuation' in significance) = 0 and source_revised_at is null)
  then 'ok   dated fund disclosures show commitment amounts in issuer updates'
  else 'FAIL fund closure update evidence' end
from public.published_private_company_updates
where id in ('00128d15-425d-47d8-98e1-bc18e1c325be', '591e60a5-b4e7-4919-a57e-40e8cd4fe2d4',
             '34469849-92f5-4093-8a13-12777702a517');

select case when count(*) = 3 and count(handoff_url) = 0
  then 'ok   historical research records have no application route'
  else 'FAIL unexpected historical handoff' end
from public.investment_opportunities
where id in ('d959a869-785e-465c-9af8-978d10f608cd', '7e62db81-26b8-4807-b211-fa738b0d816a',
             '9009357f-e507-43b0-9eba-76944953e4aa');

reset role;
update public.funding_rounds set capital_commitments = 1050000001 where id = '00128d15-425d-47d8-98e1-bc18e1c325be';
select case when source_revised_at is not null and position('1050000001' in significance) > 0
  then 'ok   a fund commitment correction updates its dated disclosure'
  else 'FAIL revised fund commitment missing' end
from public.published_private_company_updates where id = '00128d15-425d-47d8-98e1-bc18e1c325be';

rollback;
