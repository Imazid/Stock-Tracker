-- Run only against the throwaway database created by scripts/verify-migrations.sh.
\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

create function pg_temp.expect_error(statement text, expected text, label text) returns text language plpgsql as $$
begin
  execute statement;
  return 'FAIL ' || label || ' (allowed)';
exception when others then
  if sqlstate = expected then return 'ok   ' || label; end if;
  return 'FAIL ' || label || ' (' || sqlstate || ': ' || sqlerrm || ')';
end $$;

select format('grant usage on schema %I to anon, authenticated, service_role', nspname)
  from pg_namespace where oid = pg_my_temp_schema() \gexec

insert into auth.users (id,email) values
  ('a0000000-0000-0000-0000-000000000001','pm-a@example.test'),
  ('a0000000-0000-0000-0000-000000000002','pm-b@example.test');
insert into public.private_companies (id,name,sector,country,source_url,verified_at,published) values
  ('a0000000-0000-0000-0000-000000000010','SQL fixture','Technology','AU','https://example.test/company',now(),true),
  ('a0000000-0000-0000-0000-000000000011','Unpublished SQL fixture','Technology','AU','https://example.test/draft',now(),false);
insert into public.funding_rounds (id,company_id,stage,currency,closes_at,source_url,verified_at,published) values
  ('a0000000-0000-0000-0000-000000000020','a0000000-0000-0000-0000-000000000010','Seed','AUD',now()+interval '1 day','https://example.test/round',now(),true),
  ('a0000000-0000-0000-0000-000000000021','a0000000-0000-0000-0000-000000000011','Seed','AUD',now()+interval '1 day','https://example.test/draft-round',now(),true);
insert into public.investment_opportunities
  (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,handoff_url,offer_document_url,verified_at,published) values
  ('a0000000-0000-0000-0000-000000000030','a0000000-0000-0000-0000-000000000020','birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/example-one','https://www.birchal.com/example-one','https://example.test/offer',now(),true),
  ('a0000000-0000-0000-0000-000000000031','a0000000-0000-0000-0000-000000000020','birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/example-two','https://www.birchal.com/example-two','https://example.test/offer',now(),true),
  ('a0000000-0000-0000-0000-000000000032','a0000000-0000-0000-0000-000000000021','birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/example-draft','https://www.birchal.com/example-draft','https://example.test/offer',now(),true);
insert into public.investor_profiles values ('a0000000-0000-0000-0000-000000000001','AU','wholesale');
insert into public.private_holdings (id,user_id,name,asset_class,currency) values
  ('a0000000-0000-0000-0000-000000000040','a0000000-0000-0000-0000-000000000002','Other user','Venture fund','AUD');

set role anon;
select case when count(*) = 0 then 'ok   unpublished ancestor hides opportunity' else 'FAIL unpublished opportunity was visible' end
  from public.investment_opportunities where id = 'a0000000-0000-0000-0000-000000000032';
select pg_temp.expect_error('select handoff_url from public.investment_opportunities','42501','public catalog excludes application URLs');
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true) is not null;
select case when count(*) = 0 then 'ok   another tenant holding is invisible' else 'FAIL cross-tenant holding visible' end
  from public.private_holdings where id = 'a0000000-0000-0000-0000-000000000040';
select pg_temp.expect_error('select sealed from public.deal_documents','42501','mobile clients cannot read encrypted document rows directly');
select pg_temp.expect_error('update public.investor_eligibility set expires_at = now()','42501','investors cannot verify themselves');
select pg_temp.expect_error('update public.investment_commitments set status = ''confirmed''','42501','investors cannot confirm applications');
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',500,'https://example.test/offer')$q$,
  '42501','investors cannot bypass the edge authentication path');
reset role;

set role service_role;
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',500,'https://example.test/offer')$q$,
  '42501','approval gate is closed by default');
insert into public.private_market_rules values ('AU','TEST-VERSION',now() - interval '1 minute',now(),
  'https://www.asic.gov.au/crowd-sourced-funding',10000,5,true);
-- Remove any ordering dependency on the date the tests run.
update public.private_market_rules set effective_at = '-infinity' where version = 'AU-CSF-2026-11';
insert into public.private_provider_approvals (provider,jurisdiction,rule_version,agreement_reference,expires_at,enabled)
  values ('birchal','AU','TEST-VERSION','fixture agreement',now()+interval '1 day',true);
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',500,'https://example.test/offer')$q$,
  '42501','self-declared wholesale is insufficient');
insert into public.provider_connections (id,user_id,provider,external_subject) values
  ('a0000000-0000-0000-0000-000000000050','a0000000-0000-0000-0000-000000000001','birchal','fixture-account');
insert into public.investor_eligibility (user_id,provider,connection_id,jurisdiction,verified_class,verified_at,expires_at,evidence_reference)
  values ('a0000000-0000-0000-0000-000000000001','birchal','a0000000-0000-0000-0000-000000000050','AU','retail',now()-interval '1 hour',now()+interval '1 day','fixture-evidence');
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',99,'https://example.test/offer')$q$,
  '22023','minimum investment is enforced');
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',500,'https://example.test/old-offer')$q$,
  '22023','offer document version is enforced');
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',10001,'https://example.test/offer')$q$,
  '22023','retail crowd-funding cap is enforced');
select case when count(*) = 1 then 'ok   eligible handoff created' else 'FAIL handoff missing' end
  from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',9500,'https://example.test/offer');
select case when h.commitment_id = c.id and c.status = 'handoff' and c.confirmed_at is null
  then 'ok   retries are idempotent and do not confirm ownership' else 'FAIL retry changed state' end
  from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',9500,'https://example.test/offer') h
  join public.investment_commitments c on c.id = h.commitment_id;
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000030',9600,'https://example.test/offer')$q$,
  '23505','conflicting duplicate handoff is refused');
select public.record_private_provider_event('birchal','fixture-account',
  (select id from public.investment_commitments where opportunity_id='a0000000-0000-0000-0000-000000000030'),
  'test-receipt','application_received',now()-interval '1 minute',now()+interval '5 days');
select pg_temp.expect_error($q$select public.record_private_provider_event('birchal','different-account',
  (select id from public.investment_commitments where opportunity_id='a0000000-0000-0000-0000-000000000030'),
  'test-receipt','confirmed',now(),null,25,9500)$q$,'42501','provider events require matching connected account');
select pg_temp.expect_error($q$select public.record_private_provider_event('birchal','fixture-account',
  (select id from public.investment_commitments where opportunity_id='a0000000-0000-0000-0000-000000000030'),
  'test-receipt','confirmed',now())$q$,'22023','confirmation requires units and settled capital');
select public.record_private_provider_event('birchal','fixture-account',
  (select id from public.investment_commitments where opportunity_id='a0000000-0000-0000-0000-000000000030'),
  'test-receipt','confirmed',now(),null,25,9500);
select public.record_private_provider_event('birchal','fixture-account',
  (select id from public.investment_commitments where opportunity_id='a0000000-0000-0000-0000-000000000030'),
  'test-receipt','confirmed',now(),null,25,9500);
select case when count(*) = 1 and min(units) = 25 and min(settled_amount) = 9500
  then 'ok   provider confirmation atomically creates one holding' else 'FAIL provider holding' end
  from public.private_holdings where commitment_id is not null;
select pg_temp.expect_error($q$select public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'valuation','mark-1',now(),11000,'AUD',current_date,
  'Provider statement','Reported NAV')$q$, '42501','holding data sharing requires an explicit capability');
update public.private_provider_approvals set holding_activity_enabled = true where provider = 'birchal';
select pg_temp.expect_error($q$select public.record_private_holding_activity('birchal','different-account',
  (select id from public.private_holdings where commitment_id is not null),'valuation','mark-1',now(),11000,'AUD',current_date,
  'Provider statement','Reported NAV')$q$, '42501','holding activity requires the confirmed provider subject');
select pg_temp.expect_error($q$select public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'valuation','mark-1',now(),11000,'USD',current_date,
  'Provider statement','Reported NAV')$q$, '22023','provider ledger rejects a different currency');
select case when public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'valuation','mark-1',now(),11000,'AUD',current_date,
  'Provider statement','Reported NAV') then 'ok   stores provider mark' else 'FAIL mark not stored' end;
select case when not public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'valuation','mark-1',now()-interval '1 hour',5,'AUD',current_date,
  'Older statement','Reported NAV') and (select value = 11000 from public.valuation_history where provider_reference = 'mark-1')
  then 'ok   older provider update cannot replace a mark' else 'FAIL out-of-order mark was applied' end;
select public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'capital_call','call-1',now()-interval '1 minute',
  400,'AUD',current_date+5,'Capital notice');
select public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'capital_call','call-1',now(),
  400,'AUD',current_date+5,'Payment record',null,current_date);
select case when count(*) = 1 and min(settled_on) = current_date and min(due_on) = current_date+5
  then 'ok   provider settles a capital call without losing the due date' else 'FAIL capital call settlement' end
  from public.capital_calls where provider_reference='call-1';
select public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'distribution','dist-1',now(),
  500,'AUD',current_date,'Distribution notice');
select public.record_private_holding_activity('birchal','fixture-account',
  (select id from public.private_holdings where commitment_id is not null),'opening_settlement','initial',now(),
  9500,'AUD',current_date,'Settlement notice');
select case when settled_on = current_date and settlement_source = 'Settlement notice'
  then 'ok   opening settlement stores an evidenced cash-flow date' else 'FAIL opening settlement' end
  from public.private_holdings where commitment_id is not null;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000002',true) is not null;
select case when count(*)=0 then 'ok   another investor cannot see provider marks' else 'FAIL provider marks exposed' end
  from public.valuation_history;
select pg_temp.expect_error($q$select public.record_private_holding_activity('birchal','fixture-account',
  null,'valuation','mark-2',now(),1,'AUD',current_date,'Source','Method')$q$, '42501','client cannot ingest provider activity');
reset role;
set role service_role;
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000031',501,'https://example.test/offer')$q$,
  '22023','recorded applications count toward the company and intermediary cap');
update public.investment_opportunities set verified_at = now() - interval '25 hours' where id = 'a0000000-0000-0000-0000-000000000031';
select pg_temp.expect_error($q$select * from public.prepare_private_handoff('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000031',100,'https://example.test/offer')$q$,
  '22023','stale listing cannot start a handoff');
select pg_temp.expect_error($q$update public.investment_opportunities set status = 'open'
  where id = 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e21'$q$,
  '23514','issuer reference cannot be marked open');
select pg_temp.expect_error($q$update public.investment_opportunities set handoff_url = 'https://example.test/offer'
  where id = 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e21'$q$,
  '23514','issuer reference cannot have a handoff route');
insert into public.agent_analysis_runs (id,user_id,status) values
  ('a0000000-0000-0000-0000-000000000060','a0000000-0000-0000-0000-000000000001','running');
select pg_temp.expect_error($q$select public.finish_private_research('a0000000-0000-0000-0000-000000000002',
  'a0000000-0000-0000-0000-000000000060','Cross-account write','{}')$q$,
  '22023','another tenant cannot finish a research run');
select public.finish_private_research('a0000000-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-000000000060','Research title','{}');
select case when a.status = 'complete' and r.title = 'Research title'
  then 'ok   research finalization saves the display title and updates the run'
  else 'FAIL research finalization' end
  from public.agent_analysis_runs a join public.research_reports r on r.id = a.report_id
  where a.id = 'a0000000-0000-0000-0000-000000000060';
select pg_temp.expect_error('update public.investment_audit_logs set action = ''altered''','42501','service cannot rewrite the audit log');
-- Use the already confirmed provider holding and a synthetic announcement in the disposable DB.
insert into public.corporate_actions (company_id,title,significance,published_at,source_url,published)
values ('a0000000-0000-0000-0000-000000000010','Issuer news','A sourced issuer update.',now()-interval '1 minute',
        'https://example.test/issuer-update',true),
       ('a0000000-0000-0000-0000-000000000011','Private draft','Never publish.',now()-interval '1 minute',
        'https://example.test/issuer-draft',true);
update public.investment_opportunities set verified_at = now() where id = 'a0000000-0000-0000-0000-000000000030';
update public.capital_calls set settled_on = null where provider_reference = 'call-1';
select case when public.collect_private_market_alerts() = 0 then 'ok   monitor skips accounts without opt-in'
  else 'FAIL unsolicited monitoring' end;
select public.configure_private_monitor('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000080',
  array['a0000000-0000-0000-0000-000000000010','a0000000-0000-0000-0000-000000000011']::uuid[],false,true);
select public.configure_private_monitor('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000081',
  array['a0000000-0000-0000-0000-000000000010']::uuid[],false,true);
select case when public.collect_private_market_alerts() = 3 then 'ok   scheduled collection captures one alert per source across devices'
  else 'FAIL missing or duplicate alerts' end;
select case when public.collect_private_market_alerts() = 0 then 'ok   scheduled collection is idempotent'
  else 'FAIL monitor replay duplicated alerts' end;
select case when count(*) = 3 and count(*) filter (where kind='announcement' and source_url like 'https://%') = 1
  and count(*) filter (where kind='capital_call' and source_label is not null) = 1
  then 'ok   inbox retains publication and provider evidence' else 'FAIL invalid inbox entries' end
  from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000001');
select case when count(*) = 0 then 'ok   no cross-account inbox records' else 'FAIL cross-account inbox' end
  from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000002');
select public.configure_private_monitor('a0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000082',
  '{}'::uuid[],true,true);
select case when public.collect_private_market_alerts('a0000000-0000-0000-0000-000000000002') = 0
  then 'ok   declared or missing classification does not produce eligibility alerts' else 'FAIL unverified eligibility alert' end;
insert into public.investor_profiles values ('a0000000-0000-0000-0000-000000000002','AU','retail');
insert into public.provider_connections (id,user_id,provider,external_subject) values
  ('a0000000-0000-0000-0000-000000000083','a0000000-0000-0000-0000-000000000002','birchal','second-fixture-account');
insert into public.investor_eligibility (user_id,provider,connection_id,jurisdiction,verified_class,verified_at,expires_at,evidence_reference)
  values ('a0000000-0000-0000-0000-000000000002','birchal','a0000000-0000-0000-0000-000000000083',
    'AU','retail',now()-interval '1 hour',now()+interval '1 day','second-fixture-evidence');
select case when public.collect_private_market_alerts('a0000000-0000-0000-0000-000000000002') = 1
  then 'ok   current provider classification can match an open round' else 'FAIL verified round was missed' end;
select case when count(*) = 1 and min(kind) = 'eligible_round'
  then 'ok   eligibility inbox includes only approved matching round' else 'FAIL unexpected eligibility inbox' end
  from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000002');
update public.capital_calls set settled_on = current_date where provider_reference = 'call-1';
select case when count(*) = 0 then 'ok   inbox drops settled obligations' else 'FAIL settled call still in inbox' end
  from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000001') where kind = 'capital_call';
update public.corporate_actions set published = false where source_url = 'https://example.test/issuer-update';
select case when count(*) = 0 then 'ok   inbox hides an unpublished announcement' else 'FAIL unpublished alert visible' end
  from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000001') where kind = 'announcement';
update public.corporate_actions set published = true where source_url = 'https://example.test/issuer-update';
update public.investment_opportunities set verified_at = now() - interval '25 hours' where id = 'a0000000-0000-0000-0000-000000000030';
select case when count(*) = 1 and min(significance) like '%Current availability is unverified.%'
  then 'ok   inbox labels old offer availability as unverified' else 'FAIL stale offer presented as open' end
  from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000001') where kind = 'open_round';
select public.configure_private_monitor('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000080',
  '{}'::uuid[],false,false);
select case when count(*) = 2 then 'ok   one device may opt out without erasing another device inbox'
  else 'FAIL other device inbox erased' end
  from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000001');
select public.configure_private_monitor('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000081',
  '{}'::uuid[],false,false);
select case when count(*) = 0 then 'ok   last opt-out removes the stored inbox' else 'FAIL inbox retained after opt-out' end
  from public.private_market_alerts where user_id = 'a0000000-0000-0000-0000-000000000001';
reset role;
set role authenticated;
select pg_temp.expect_error($q$select * from public.private_market_alert_inbox('a0000000-0000-0000-0000-000000000001')$q$,
  '42501','app clients cannot read another account inbox directly');
select pg_temp.expect_error($q$select public.run_private_market_monitor()$q$, '42501', 'app clients cannot invoke scheduled collection');
reset role;
rollback;
