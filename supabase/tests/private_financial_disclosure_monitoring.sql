\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id,email) values
  ('f2000000-0000-4000-8000-000000000001', 'financial-watcher@example.test'),
  ('f2000000-0000-4000-8000-000000000002', 'financial-unrelated@example.test'),
  ('f2000000-0000-4000-8000-000000000003', 'financial-new-follower@example.test');

insert into public.private_companies (id, name, sector, country, source_url, verified_at, published) values
  ('f2000000-0000-4000-8000-000000000010', 'Financial fixture', 'Technology', 'AU', 'https://example.test/company', now(), true),
  ('f2000000-0000-4000-8000-000000000011', 'Hidden company', 'Technology', 'AU', 'https://example.test/hidden', now(), false);

insert into public.private_company_financials
  (id,company_id,period_end_on,period_kind,assurance,currency,revenue,annual_recurring_revenue,published_on,source_url,verified_at,published)
select f.id, f.company_id, f.period_end_on, f.period_kind, f.assurance, f.currency, f.revenue, f.arr,
       (now() at time zone 'Australia/Sydney')::date + f.day_offset,
       'https://example.test/' || f.slug, now() + f.verification_offset, f.published
from (values
  ('f2000000-0000-4000-8000-000000000020'::uuid,'f2000000-0000-4000-8000-000000000010'::uuid,'2025-06-30'::date,
    'financial_year','audited','AUD',120, null::integer, -1,'filing',interval '0 minutes',true),
  ('f2000000-0000-4000-8000-000000000021','f2000000-0000-4000-8000-000000000010','2024-06-30',
    'financial_year','audited','AUD',100,null,-1,'filing',interval '0 minutes',true),
  ('f2000000-0000-4000-8000-000000000022','f2000000-0000-4000-8000-000000000010','2025-04-01',
    'month_snapshot','issuer_reported','USD',null,50,-20,'historical',interval '0 minutes',true),
  ('f2000000-0000-4000-8000-000000000023','f2000000-0000-4000-8000-000000000010','2025-01-01',
    'month_snapshot','issuer_reported','USD',null,60,1,'future',interval '3 days',true),
  ('f2000000-0000-4000-8000-000000000024','f2000000-0000-4000-8000-000000000010','2025-03-01',
    'month_snapshot','issuer_reported','USD',null,10,-1,'draft',interval '0 minutes',false),
  ('f2000000-0000-4000-8000-000000000025','f2000000-0000-4000-8000-000000000011','2025-06-30',
    'financial_year','audited','AUD',20,null,-1,'hidden',interval '0 minutes',true),
  ('f2000000-0000-4000-8000-000000000026','f2000000-0000-4000-8000-000000000010','2025-02-01',
    'month_snapshot','issuer_reported','USD',null,2,-1,'unchecked',interval '3 days',true)
) as f(id,company_id,period_end_on,period_kind,assurance,currency,revenue,arr,day_offset,slug,verification_offset,published);

set role service_role;
select case when array_agg(id order by id) = array[
    'f2000000-0000-4000-8000-000000000020','f2000000-0000-4000-8000-000000000022']::uuid[]
  then 'ok   one update per filing, with future, unverified, draft and hidden company rows omitted'
  else 'FAIL publication or filing deduplication' end
from public.published_private_company_updates
where company_id in ('f2000000-0000-4000-8000-000000000010','f2000000-0000-4000-8000-000000000011');
select case when count(*) = 1 and min(financial_published_on) = (now() at time zone 'Australia/Sydney')::date - 1
    and min(significance) like '%year ended 2025-06-30%AUD 120.%AUD 100%changed by 20%.'
    and min(source_url) = 'https://example.test/filing'
  then 'ok   the disclosed periods, comparable audited change, currency and original citation are preserved'
  else 'FAIL financial evidence' end
from public.published_private_company_updates where id = 'f2000000-0000-4000-8000-000000000020';
select case when count(*) = 1 and min(significance) like '%month of 2025-04,%annual recurring revenue of USD 50.%'
    and min(title) = 'Issuer-reported financial update'
  then 'ok   a monthly ARR disclosure keeps its reporting period and assurance'
  else 'FAIL ARR evidence' end
from public.published_private_company_updates where id = 'f2000000-0000-4000-8000-000000000022';

select public.configure_private_monitor('f2000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000030',
  array['f2000000-0000-4000-8000-000000000010']::uuid[], false, true, true);
select public.configure_private_monitor('f2000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000031',
  '{}'::uuid[], false, true, true);
select public.run_private_market_monitor();
select public.run_private_market_monitor();
select case when count(*) = 1 and min(source_label) = 'Issuer financial disclosure'
    and min(source_url) = 'https://example.test/filing' and min(revised_at) is null
  then 'ok   an opted-in account gets the recent financial update once'
  else 'FAIL first financial alert or replay' end
from public.private_market_alert_inbox_with_revisions('f2000000-0000-4000-8000-000000000001');
select case when count(*) = 0 then 'ok   the update stays out of the unrelated inbox'
  else 'FAIL financial alert isolation' end
from public.private_market_alert_inbox_with_revisions('f2000000-0000-4000-8000-000000000002');
reset role;
select case when count(*) = 1 and min(source->>'url') = 'https://example.test/filing'
  then 'ok   the existing digest can cite the published financial evidence'
  else 'FAIL digest financial evidence' end
from jsonb_array_elements(public.private_market_digest_sources('f2000000-0000-4000-8000-000000000001',
  (now() at time zone 'Australia/Sydney')::date)) source;

create temporary table original_financial_alert as
  select id, push_sequence, occurred_at from public.private_market_alerts
  where user_id = 'f2000000-0000-4000-8000-000000000001';
update public.private_company_financials set verified_at = now() - interval '1 minute'
where id = 'f2000000-0000-4000-8000-000000000020';
select public.run_private_market_monitor();
select case when count(*) = 1 then 'ok   re-verification alone leaves the alert and push cursor unchanged'
  else 'FAIL re-verification raised an alert' end
from public.private_market_alerts a join original_financial_alert b using (id)
where a.push_sequence = b.push_sequence and a.revised_at is null;

update public.private_company_financials set revenue = 80
where id = 'f2000000-0000-4000-8000-000000000021';
update public.private_company_financials set annual_recurring_revenue = 55
where id = 'f2000000-0000-4000-8000-000000000022';
select public.configure_private_monitor('f2000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000032',
  array['f2000000-0000-4000-8000-000000000010']::uuid[], false, true, true);
select case when count(*) = 2 and bool_and((source->>'is_revision')::boolean)
  then 'ok   a new follower can read both corrected sources before inbox collection'
  else 'FAIL missed financial revisions in digest' end
from jsonb_array_elements(public.private_market_digest_sources('f2000000-0000-4000-8000-000000000003',
  (now() at time zone 'Australia/Sydney')::date)) source;
select public.run_private_market_monitor();
select case when count(*) = 1 then 'ok   a comparative correction updates the original alert and advances its push cursor'
  else 'FAIL comparative correction lost provenance' end
from public.private_market_alerts a join original_financial_alert b using (id)
where a.push_sequence > b.push_sequence and a.occurred_at = b.occurred_at and a.revised_at is not null
  and a.significance like '%AUD 80%changed by 50%.';
select case when count(*) = 1 and min(occurred_at) < now() - interval '7 days' and min(revised_at) is not null
  then 'ok   a corrected historical disclosure enters the inbox with its original date'
  else 'FAIL historical correction missing from inbox' end
from public.private_market_alert_inbox_with_revisions('f2000000-0000-4000-8000-000000000003')
where subject_id = 'f2000000-0000-4000-8000-000000000022';

update public.private_company_financials set currency = 'USD' where id = 'f2000000-0000-4000-8000-000000000021';
select case when min(significance) not like '%changed by%' and min(source_revised_at) is not null
  then 'ok   mismatched currencies suppress the revenue comparison and keep the correction date'
  else 'FAIL incompatible comparator' end
from public.published_private_company_updates where id = 'f2000000-0000-4000-8000-000000000020';
update public.private_company_financials set published = false where id in
  ('f2000000-0000-4000-8000-000000000020','f2000000-0000-4000-8000-000000000021','f2000000-0000-4000-8000-000000000022');
select case when not exists (select 1 from public.private_market_alert_inbox_with_revisions('f2000000-0000-4000-8000-000000000001'))
  and public.private_market_push_through('f2000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000030',0) is null
  and public.private_market_digest_sources('f2000000-0000-4000-8000-000000000001',
       (now() at time zone 'Australia/Sydney')::date) = '[]'::jsonb
  then 'ok   withdrawing financial publications suppresses the inbox, pending push and digest'
  else 'FAIL withdrawn financial evidence remains reachable' end;

set role authenticated;
select case when not has_table_privilege(current_user,'public.published_private_company_updates','select')
  then 'ok   the monitoring view remains backend-only' else 'FAIL private monitoring view grant' end;
reset role;
rollback;
