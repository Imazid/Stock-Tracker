\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

create function pg_temp.expect_application_error(statement text, expected text, label text) returns text language plpgsql as $$
begin
  execute statement;
  return 'FAIL ' || label || ' (allowed)';
exception when others then
  return case when sqlstate = expected then 'ok   ' || label else 'FAIL ' || label || ' (' || sqlstate || ': ' || sqlerrm || ')' end;
end $$;
select format('grant usage on schema %I to authenticated, service_role', nspname)
  from pg_namespace where oid = pg_my_temp_schema() \gexec

insert into auth.users (id,email) values
  ('ea000000-0000-4000-8000-000000000001','application-fixture@example.test'),
  ('ea000000-0000-4000-8000-000000000002','second-application-fixture@example.test');
insert into public.private_companies (id,name,sector,country,source_url,verified_at,published) values
  ('ea000000-0000-4000-8000-000000000010','Application issuer','Technology','AU','https://example.test/company',now(),true);
insert into public.funding_rounds (id,company_id,stage,currency,closes_at,source_url,verified_at,published) values
  ('ea000000-0000-4000-8000-000000000020','ea000000-0000-4000-8000-000000000010','Seed','AUD',now()+interval '1 day','https://example.test/round',now(),true);
insert into public.investment_opportunities
  (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,handoff_url,offer_document_url,verified_at,published) values
  ('ea000000-0000-4000-8000-000000000030','ea000000-0000-4000-8000-000000000020','birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/example-one','https://www.birchal.com/example-one','https://example.test/offer',now(),true),
  ('ea000000-0000-4000-8000-000000000031','ea000000-0000-4000-8000-000000000020','birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/example-two','https://www.birchal.com/example-two','https://example.test/offer',now(),true),
  ('ea000000-0000-4000-8000-000000000032','ea000000-0000-4000-8000-000000000020','birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/example-three','https://www.birchal.com/example-three','https://example.test/offer',now(),true);
update public.private_market_rules set handoff_enabled=true, reviewed_at=now()-interval '1 day', effective_at=now()-interval '1 day'
  where jurisdiction='AU';
insert into public.private_provider_approvals (provider,jurisdiction,rule_version,agreement_reference,expires_at,enabled)
  select 'birchal','AU',version,'Disposable contract fixture',now()+interval '1 day',true
  from public.private_market_rules where jurisdiction='AU';
insert into public.investor_profiles values ('ea000000-0000-4000-8000-000000000001','AU','retail');
set role service_role;
select pg_temp.expect_application_error($q$select public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','onmarket','application-owner','AU','retail',
  now()-interval '1 day','provider-evidence',now()+interval '1 day')$q$,
  '42501','verification requires an active provider agreement');
select pg_temp.expect_application_error($q$select public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','birchal','application-owner','AU','retail',
  now()-interval '1 day','provider-evidence',now()+interval '1 day',now()-interval '2 days')$q$,
  '22023','retail verification cannot claim an accountant certificate');
select case when public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','birchal','application-owner','AU','retail',
  now()-interval '1 day','disposable-eligibility',now()+interval '1 day')
  then 'ok   a trusted provider record establishes the eligible account'
  else 'FAIL verification could not be saved' end;
select case when not public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','birchal','application-owner','AU','wholesale',
  now()-interval '1 day','conflicting replay',now()+interval '1 day')
  then 'ok   same-time replay cannot override the recorded class'
  else 'FAIL conflicting verification replay' end;
select pg_temp.expect_application_error($q$select public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000002','birchal','application-owner','AU','retail',
  now()-interval '1 hour','wrong owner',now()+interval '1 day')$q$,
  '42501','an external account cannot be rebound to another investor');

create temporary table application as
  select commitment_id from public.prepare_private_handoff('ea000000-0000-4000-8000-000000000001',
  'ea000000-0000-4000-8000-000000000030',9500,'https://example.test/offer');
select case when count(*)=1 and bool_and(provider_connection_id = (select id from public.provider_connections where external_subject = 'application-owner'))
    and bool_and(retail_csf_cooling_off_required)
  then 'ok   handoff binds the verified account and records the retail protection' else 'FAIL unbound application' end
  from public.investment_commitments where id=(select commitment_id from application);
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from application),'receipt','application_received',now()-interval '1 hour')$q$,
  '22023','provider event cannot predate the handoff');
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from application),'receipt','application_received',now()-interval '4 minutes', 'infinity')$q$,
  '22023','an unbounded deadline is refused');
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','application_received',now()-interval '4 minutes');
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from application),'receipt','confirmed',now(),null,25,9500)$q$,
  '22023','retail confirmation requires the provider deadline');
select case when status='application_received' and cooling_off_ends_at is null
    and not exists (select 1 from public.private_holdings where commitment_id=c.id)
  then 'ok   incomplete provider evidence leaves the application pending and records no ownership'
  else 'FAIL missing withdrawal evidence affected ownership' end
from public.investment_commitments c where id=(select commitment_id from application);
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','application_received',now()-interval '3 minutes 30 seconds',now()+interval '5 days');
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from application),'receipt','confirmed',now(),null,25,9500)$q$,
  '22023','settlement is refused while a reported withdrawal window is open');
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','withdrawal_requested',now()-interval '3 minutes');
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from application),'receipt','confirmed',now(),null,25,9500)$q$,
  '22023','pending withdrawal cannot settle');
select pg_temp.expect_application_error($q$select * from public.prepare_private_handoff('ea000000-0000-4000-8000-000000000001',
  'ea000000-0000-4000-8000-000000000031',501,'https://example.test/offer')$q$,
  '22023','a pending withdrawal still counts toward the retail cap');
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','withdrawal_declined',now()-interval '2 minutes');
select case when status='application_received' and withdrawal_declined_at is not null and provider_received_at is not null
  then 'ok   provider denial resumes the original application with its timeline' else 'FAIL lost provider denial' end
  from public.investment_commitments where id=(select commitment_id from application);
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','withdrawal_requested',now()-interval '1 minute');
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','withdrawn',now());
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','withdrawn',now());
select case when status='withdrawn' and withdrawn_at=now() and withdrawal_requested_at=now()-interval '1 minute'
  and not exists (select 1 from public.private_holdings where commitment_id=c.id)
  then 'ok   confirmed withdrawal persists and cannot create ownership' else 'FAIL invalid withdrawal result' end
  from public.investment_commitments c where id=(select commitment_id from application);
select case when count(*)=1 then 'ok   replay does not duplicate the withdrawal audit' else 'FAIL duplicated withdrawal' end
  from public.investment_audit_logs where subject_id=(select commitment_id from application) and action='provider_withdrawn';
create temporary table legacy_application as
  select commitment_id
  from public.prepare_private_handoff('ea000000-0000-4000-8000-000000000001',
    'ea000000-0000-4000-8000-000000000031',501,'https://example.test/offer');
select case when count(*)=1 then 'ok   confirmed withdrawal releases the recorded cap' else 'FAIL retained cap' end
from legacy_application;
update public.investment_commitments set retail_csf_cooling_off_required = null
where id=(select commitment_id from legacy_application);
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from legacy_application),
  'legacy-receipt','application_received',now()-interval '1 minute');
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from legacy_application),'legacy-receipt','confirmed',now(),null,5,501)$q$,
  '22023','legacy Australian crowd-sourced funding requires the deadline when classification was not recorded');

reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','ea000000-0000-4000-8000-000000000002',true) is not null;
select case when count(*)=0 then 'ok   another account cannot read the application timeline' else 'FAIL cross-tenant timeline' end
  from public.investment_commitments;
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  null,'receipt','withdrawn',now())$q$,'42501','mobile users cannot mark a withdrawal');
reset role;
set role service_role;
update public.private_provider_approvals set enabled = false where provider = 'birchal' and jurisdiction = 'AU';
select case when public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','birchal','application-owner','AU',null,
  now()-interval '4 minutes','provider-revocation')
  then 'ok   revocation succeeds after the provider approval ends' else 'FAIL revocation unavailable' end;
select case when revoked_at is not null and revocation_evidence_reference = 'provider-revocation'
  then 'ok   the provider revocation is dated and linked to evidence'
  else 'FAIL revocation evidence' end
from public.provider_connections where external_subject = 'application-owner';
update public.private_provider_approvals set enabled = true where provider = 'birchal' and jurisdiction = 'AU';
select pg_temp.expect_application_error($q$select * from public.prepare_private_handoff('ea000000-0000-4000-8000-000000000001',
  'ea000000-0000-4000-8000-000000000030',500,'https://example.test/offer')$q$,
  '42501','revoked verification blocks the ordinary handoff path');
select case when not public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','birchal','application-owner','AU','retail',
  now()-interval '5 minutes','late verification',now()+interval '1 day')
  then 'ok   an older verification cannot restore a revoked account' else 'FAIL stale reactivation' end;
select case when public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','birchal','application-owner','AU','wholesale',
  now()-interval '3 minutes','fresh review',now()+interval '1 day',now()-interval '4 minutes')
  then 'ok   newer provider review restores verification' else 'FAIL fresh review blocked' end;
select case when e.verified_class='wholesale' and e.accountant_certificate_reviewed_at is not null
    and c.revoked_at is null and c.revocation_evidence_reference='provider-revocation'
  then 'ok   re-verification retains the prior revocation reference and adds the certificate review date'
  else 'FAIL renewed verification evidence' end
from public.investor_eligibility e join public.provider_connections c on c.id = e.connection_id
where c.external_subject='application-owner';
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from legacy_application),'legacy-receipt','confirmed',now(),null,5,501)$q$,
  '22023','a later wholesale verification cannot waive the existing legacy deadline requirement');
create temporary table wholesale_application as
  select commitment_id from public.prepare_private_handoff('ea000000-0000-4000-8000-000000000001',
    'ea000000-0000-4000-8000-000000000032',501,'https://example.test/offer');
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from wholesale_application),
  'wholesale-receipt','application_received',now()-interval '1 minute');
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from wholesale_application),
  'wholesale-receipt','confirmed',now(),null,5,501);
select case when status='confirmed' and retail_csf_cooling_off_required is false and cooling_off_ends_at is null
  then 'ok   a verified wholesale application can settle when a retail deadline does not apply'
  else 'FAIL wholesale tender incorrectly required retail evidence' end
from public.investment_commitments where id=(select commitment_id from wholesale_application);
select case when count(*) = 3 then 'ok   each accepted verification change creates one audit event'
  else 'FAIL missing or duplicated verification audit' end
from public.investment_audit_logs
where user_id='ea000000-0000-4000-8000-000000000001'
  and action in ('provider_verification_recorded','provider_verification_revoked');
reset role;

set role authenticated;
select pg_temp.expect_application_error('select external_subject from public.provider_connections',
  '42501','authenticated clients cannot read external subjects directly');
select pg_temp.expect_application_error('select evidence_reference from public.investor_eligibility',
  '42501','authenticated clients cannot read underlying verification evidence');
select pg_temp.expect_application_error($q$select public.record_private_provider_verification(
  'ea000000-0000-4000-8000-000000000001','birchal','application-owner','AU','wholesale',
  now(),'client-claim',now()+interval '1 day')$q$,
  '42501','authenticated clients cannot record provider verification');
reset role;
rollback;
