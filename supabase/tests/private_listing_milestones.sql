\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;
set local role anon;

select case when count(*) = 4
  and count(*) filter (where quotation_status = 'proposed' and symbol = 'ATW' and quotation_on = '2026-11-26'
    and expected_offer_close_on = '2026-11-16') = 1
  and count(*) filter (where quotation_status = 'anticipated' and symbol = 'ABC' and quotation_on = '2026-11-30') = 1
  and count(*) filter (where quotation_status = 'listed' and symbol = 'CX8' and quotation_on = '2026-11-12') = 1
  and count(*) filter (where quotation_status = 'withdrawn' and symbol = 'MTX' and quotation_on is null) = 1
  then 'ok   published dates distinguish proposed, anticipated, listed and withdrawn milestones'
  else 'FAIL incorrect public listing milestones' end
from public.private_listing_milestones where exchange = 'ASX' and symbol in ('ATW', 'ABC', 'CX8', 'MTX');

reset role;
set local role service_role;
select case when count(*) = 4 and count(o.handoff_url) = 0 and count(r.closes_at) = 0
  and bool_and(o.status in ('closed', 'unverified'))
  and count(*) filter (where m.symbol = 'CX8' and r.raised = 12000000 and o.status = 'closed') = 1
  then 'ok   listing dates and closed IPOs provide no deadline or application route'
  else 'FAIL milestone inferred an application or missing IPO proceeds' end
from public.private_listing_milestones m
join public.funding_rounds r on r.id = m.round_id
join public.investment_opportunities o on o.round_id = m.round_id
where m.symbol in ('ATW', 'ABC', 'CX8', 'MTX');

update public.private_listing_milestones set published = false where symbol = 'ATW';
update public.private_listing_milestones set verified_at = now() + interval '1 hour' where symbol = 'ABC';
update public.private_companies set published = false where id = 'a581f4af-a8d0-41fd-a9be-0e4e1607f102';
update public.funding_rounds set published = false where id = 'a581f4af-a8d0-41fd-a9be-0e4e1607f203';
reset role;
set local role anon;
select case when count(*) = 0 and not has_table_privilege('public.private_listing_milestones', 'UPDATE')
  then 'ok   unpublished, future and unpublished parent milestones are hidden and read-only'
  else 'FAIL listing publication or access' end
from public.private_listing_milestones where symbol in ('ATW', 'ABC', 'CX8', 'MTX');
reset role;
rollback;
