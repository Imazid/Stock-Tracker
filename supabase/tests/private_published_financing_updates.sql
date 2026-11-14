\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id, email) values
  ('f1000000-0000-4000-8000-000000000001', 'funding-watch@example.test'),
  ('f1000000-0000-4000-8000-000000000002', 'funding-unrelated@example.test'),
  ('f1000000-0000-4000-8000-000000000003', 'funding-new-follower@example.test');
insert into public.private_companies (id, name, sector, country, source_url, verified_at, published) values
  ('f1000000-0000-4000-8000-000000000010', 'Funding fixture', 'Technology', 'AU', 'https://example.test/company', now(), true);
insert into public.funding_rounds
  (id, company_id, stage, raised, valuation, currency, announced_on, source_url, verified_at, published)
select id, 'f1000000-0000-4000-8000-000000000010', stage, raised, valuation, 'AUD',
       (now() at time zone 'UTC')::date + day_offset, 'https://example.test/' || slug, now(), published
from (values
  ('f1000000-0000-4000-8000-000000000020'::uuid, 'Series A', 3000000, 18000000, -1, 'series-a', true),
  ('f1000000-0000-4000-8000-000000000021', 'Series B', null, null, 2, 'future', true),
  ('f1000000-0000-4000-8000-000000000022', 'Series B', 234, null, -1, 'draft', false),
  ('f1000000-0000-4000-8000-000000000023', 'Series B', 234, null, -1, 'only-open', true),
  ('f1000000-0000-4000-8000-000000000024', 'Seed', 123, null, -1, 'issuer-release', true),
  ('f1000000-0000-4000-8000-000000000025', 'Seed', 222, null, -20, 'historical', true),
  ('f1000000-0000-4000-8000-000000000026', 'Series C', 456, null, -1, 'conflicting-claims', true)
) as fixtures(id, stage, raised, valuation, day_offset, slug, published);
insert into public.investment_opportunities
  (round_id, provider, category, status, eligibility, jurisdictions, source_url, verified_at, published)
select id, case when source_url like '%only-open' then 'birchal' else 'issuer' end,
       'Series A', case when source_url like '%only-open' then 'open' else 'closed' end,
       'provider review', '{}', source_url, now(), true
from public.funding_rounds where company_id = 'f1000000-0000-4000-8000-000000000010';
insert into public.investment_opportunities
  (round_id, provider, category, status, eligibility, jurisdictions, source_url, verified_at, published)
values
  ('f1000000-0000-4000-8000-000000000020', 'birchal', 'Series A', 'closed', 'provider review', '{}', 'https://example.test/another-listing', now(), true),
  ('f1000000-0000-4000-8000-000000000026', 'birchal', 'Series B or later', 'interest', 'provider review', '{}', 'https://example.test/interest', now(), true);
insert into public.corporate_actions (id, company_id, title, significance, source_url, published_at, published)
values
  ('f1000000-0000-4000-8000-000000000030', 'f1000000-0000-4000-8000-000000000010',
   'The issuer reported a seed round', 'The issuer announced the funding close.', 'https://example.test/issuer-release', now() - interval '1 day', true),
  ('f1000000-0000-4000-8000-000000000031', 'f1000000-0000-4000-8000-000000000010',
   'Historical investor update', 'The issuer published its investor update.', 'https://example.test/old-update', now() - interval '20 days', true);

set role service_role;
select case when array_agg(id order by id) = array[
    'f1000000-0000-4000-8000-000000000020', 'f1000000-0000-4000-8000-000000000025',
    'f1000000-0000-4000-8000-000000000030', 'f1000000-0000-4000-8000-000000000031']::uuid[]
  then 'ok   closed rounds use one canonical source and omit drafts, future and conflicting listings'
  else 'FAIL publication and deduplication' end
  from public.published_private_company_updates where company_id = 'f1000000-0000-4000-8000-000000000010';
select case when count(*) = 1 and min(round_announced_on) = (now() at time zone 'UTC')::date - 1
    and min(source_url) = 'https://example.test/series-a'
    and min(significance) like '%AUD 3000000.%AUD 18000000.%'
  then 'ok   the financing update uses the published date, amount, valuation and source'
  else 'FAIL financing provenance' end
  from public.published_private_company_updates where id = 'f1000000-0000-4000-8000-000000000020';

select public.configure_private_monitor('f1000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000011',
  array['f1000000-0000-4000-8000-000000000010']::uuid[], false, true, true);
select public.configure_private_monitor('f1000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000012',
  '{}'::uuid[], false, true, true);
select public.run_private_market_monitor();
select public.run_private_market_monitor();
select case when count(*) filter (where kind = 'announcement') = 2
    and count(*) filter (where subject_id = 'f1000000-0000-4000-8000-000000000020'
     and source_label = 'Funding round source') = 1
  then 'ok   the watcher gets one sourced alert for each recent event'
  else 'FAIL alert window or replay' end
  from public.private_market_alert_inbox('f1000000-0000-4000-8000-000000000001');
select case when count(*) = 0 then 'ok   a second account gets no financing alert' else 'FAIL inbox isolation' end
  from public.private_market_alert_inbox('f1000000-0000-4000-8000-000000000002');
select case when count(*) = 1 then 'ok   the opted-in summary includes the round as a cited source'
  else 'FAIL summary lacks financing evidence' end
  from public.claim_private_market_digests() d, jsonb_array_elements(d.sources) as source
  where d.owner_id = 'f1000000-0000-4000-8000-000000000001' and source->>'id' = 'f1000000-0000-4000-8000-000000000020';

reset role;
select case when public.private_market_push_through('f1000000-0000-4000-8000-000000000001',
    'f1000000-0000-4000-8000-000000000011', 0) is not null
  then 'ok   scoped financing updates can advance the push cursor' else 'FAIL financing push unavailable' end;

create temporary table saved_disclosure_alert as
select id, subject_id, push_sequence, occurred_at from public.private_market_alerts
where user_id = 'f1000000-0000-4000-8000-000000000001';
update public.funding_rounds set verified_at = now() + interval '1 minute'
where id = 'f1000000-0000-4000-8000-000000000020';
select public.run_private_market_monitor();
select case when count(*) = 0 then 'ok   re-verification alone does not advance the notification cursor'
  else 'FAIL verification-only correction' end
from public.private_market_alerts a join saved_disclosure_alert before using (id)
where a.push_sequence <> before.push_sequence or a.revised_at is not null;

update public.funding_rounds set valuation = 18500000 where id = 'f1000000-0000-4000-8000-000000000020';
update public.corporate_actions set significance = 'The issuer corrected its statement.'
where id = 'f1000000-0000-4000-8000-000000000030';
select public.run_private_market_monitor();
select case when count(*) = 2 then 'ok   corrected financing and announcements keep stable IDs and gain new cursors'
  else 'FAIL correction cursor' end
from public.private_market_alerts a join saved_disclosure_alert before using (id)
where a.push_sequence > (select max(push_sequence) from saved_disclosure_alert)
  and a.revised_at is not null and a.occurred_at = before.occurred_at;
select case when count(*) = 2 then 'ok   the inbox returns corrected terms and their revision times'
  else 'FAIL corrected inbox provenance' end
from public.private_market_alert_inbox_with_revisions('f1000000-0000-4000-8000-000000000001')
where revised_at is not null and (significance like '%AUD 18500000.%' or significance like '%corrected%');
select case when not exists (select 1 from public.private_market_alert_inbox_with_revisions('f1000000-0000-4000-8000-000000000002'))
  then 'ok   corrected disclosures stay within monitored companies' else 'FAIL correction leaked' end;
select case when public.private_market_push_through('f1000000-0000-4000-8000-000000000001',
    'f1000000-0000-4000-8000-000000000011', (select max(push_sequence) from saved_disclosure_alert)) is not null
  then 'ok   a correction can advance the opted-in device push cursor' else 'FAIL correction push unavailable' end;
select case when public.run_private_market_monitor() = 0 then 'ok   corrected content can replay without another alert'
  else 'FAIL repeated correction alert' end;

update public.funding_rounds set published = false where id = 'f1000000-0000-4000-8000-000000000020';
select case when not exists (select 1 from public.private_market_alert_inbox('f1000000-0000-4000-8000-000000000001')
    where subject_id = 'f1000000-0000-4000-8000-000000000020')
  then 'ok   withdrawing the round removes it from the monitoring inbox' else 'FAIL stale round alert' end;
update public.corporate_actions set published = false where id = 'f1000000-0000-4000-8000-000000000030';
update public.funding_rounds set published = false where id = 'f1000000-0000-4000-8000-000000000024';
update public.investment_opportunities set published = false
  where round_id = 'f1000000-0000-4000-8000-000000000026';
select case when public.private_market_push_through('f1000000-0000-4000-8000-000000000001',
    'f1000000-0000-4000-8000-000000000011', 0) is null
  then 'ok   withdrawn financing evidence cannot send a pending push' else 'FAIL stale push' end;

update public.funding_rounds set verified_at = now() + interval '2 minutes', traction = ' '
where id = 'f1000000-0000-4000-8000-000000000025';
select case when (select source_revised_at is null from public.funding_rounds
    where id = 'f1000000-0000-4000-8000-000000000025')
  then 'ok   harmless metadata leaves a historical source undated for correction'
  else 'FAIL historical round gained a false revision' end;
update public.funding_rounds set raised = 333 where id = 'f1000000-0000-4000-8000-000000000025';
update public.corporate_actions set significance = 'The issuer corrected its historical investor update.'
where id = 'f1000000-0000-4000-8000-000000000031';
select public.configure_private_monitor('f1000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000013',
  array['f1000000-0000-4000-8000-000000000010']::uuid[], false, true, true);
create temporary table historic_digest as select * from public.claim_private_market_digests()
where owner_id = 'f1000000-0000-4000-8000-000000000003';
select case when count(*) = 2 and bool_and((source->>'is_revision')::boolean)
    and bool_and((source->>'published_at')::timestamptz < now() - interval '7 days')
  then 'ok   a new follower gets dated corrections before their inbox is collected'
  else 'FAIL digest missed an older corrected source for a new follower' end
from historic_digest d, jsonb_array_elements(d.sources) as source;
select public.run_private_market_monitor();
select case when count(*) = 2 and bool_and(occurred_at < now() - interval '7 days')
    and bool_and(revised_at >= now() - interval '1 day')
  then 'ok   a new follower sees both historic corrections with original publication dates'
  else 'FAIL historic correction provenance in inbox' end
from public.private_market_alert_inbox_with_revisions('f1000000-0000-4000-8000-000000000003');
select case when public.finish_private_market_digest(job_id,lease,sources,'{}')
  then 'ok   inbox collection does not invalidate a pending correction digest'
  else 'FAIL valid historical digest was blocked' end from historic_digest;
update public.funding_rounds set raised = 333, verified_at = now() + interval '3 minutes'
where id = 'f1000000-0000-4000-8000-000000000025';
select case when public.run_private_market_monitor() = 0
    and public.private_market_digest_sources('f1000000-0000-4000-8000-000000000003',
      (now() at time zone 'Australia/Sydney')::date + 1) = '[]'::jsonb
  then 'ok   unchanged historical corrections do not repeat in alerts or later summaries'
  else 'FAIL historical correction replay' end;
select case when count(*) = 0 then 'ok   no historical corrections for an unrelated account'
  else 'FAIL historical correction leaked' end
from public.private_market_alert_inbox_with_revisions('f1000000-0000-4000-8000-000000000002');

set role authenticated;
select case when not has_table_privilege(current_user, 'public.published_private_company_updates', 'select')
  then 'ok   the internal view is restricted to the backend' else 'FAIL direct view access' end;
select case when not has_function_privilege(current_user, 'public.private_market_alert_inbox_with_revisions(uuid)', 'execute')
  then 'ok   the revised inbox RPC is restricted to the backend' else 'FAIL revised inbox RPC access' end;
select case when not has_function_privilege(current_user, 'public.stamp_private_source_revision()', 'execute')
  then 'ok   clients cannot call the source revision trigger' else 'FAIL direct trigger access' end;
reset role;
rollback;
