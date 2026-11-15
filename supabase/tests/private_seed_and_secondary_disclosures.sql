\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;
set role anon;

select case when count(*) = 2
    and bool_and(o.status = 'closed' and o.provider = 'issuer' and o.offer_document_url is null
      and o.minimum is null and r.target is null and r.valuation is null and o.source_url = r.source_url)
    and array_agg(o.category order by c.name) = array['Seed or angel', 'Private secondary']
    and array_agg(r.raised order by c.name) = array[7000000, null]::numeric[]
    and array_agg(r.secondary_purchase_amount order by c.name) = array[null, 566700000]::numeric[]
    and array_agg(r.secondary_closed_on order by c.name) = array[null, date '2024-07-03']
    and array_agg(r.announced_on order by c.name) = array[date '2026-02-11', date '2025-07-01']
  then 'ok   seed capital and secondary consideration are published separately'
  else 'FAIL historical seed or secondary terms' end
from public.investment_opportunities o
join public.funding_rounds r on r.id = o.round_id
join public.private_companies c on c.id = r.company_id
where o.id in ('aeb3425b-bda0-4ad2-98cc-7cc75ef87ed5', '0fa8a227-cf78-4a6c-9acb-593620756b26');

reset role;
set role service_role;

select case when count(*) = 1
    and bool_and(source_label = 'Secondary disclosure' and significance like '%USD 566700000%'
      and significance like '%2024-07-03%' and round_announced_on = date '2025-07-01')
  then 'ok   company updates contain a single dated tender disclosure'
  else 'FAIL misleading or duplicate tender disclosure' end
from public.published_private_company_updates
where company_id = '2bf9569c-da32-4b8b-9f82-dddb7dfd3d87';

select case when count(*) = 2 and count(handoff_url) = 0
  then 'ok   both historical transactions have no application link'
  else 'FAIL unexpected historical handoff' end
from public.investment_opportunities
where id in ('aeb3425b-bda0-4ad2-98cc-7cc75ef87ed5', '0fa8a227-cf78-4a6c-9acb-593620756b26');

reset role;
do $$
begin
  update public.funding_rounds set raised = 566700000 where id = '56c8601b-50ef-4f86-977d-1db321c256a4';
  raise exception 'Secondary purchase accepted as issuer capital';
exception when check_violation then
  null;
end;
$$;

update public.funding_rounds set secondary_purchase_amount = 566700001 where id = '56c8601b-50ef-4f86-977d-1db321c256a4';
select case when source_revised_at is not null and significance like '%USD 566700001%'
  then 'ok   a correction refreshes the dated secondary disclosure'
  else 'FAIL revised secondary amount missing' end
from public.published_private_company_updates where id = '56c8601b-50ef-4f86-977d-1db321c256a4';

rollback;
