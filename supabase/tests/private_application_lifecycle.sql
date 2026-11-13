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
    'https://www.birchal.com/example-two','https://www.birchal.com/example-two','https://example.test/offer',now(),true);
update public.private_market_rules set handoff_enabled=true, reviewed_at=now()-interval '1 day', effective_at=now()-interval '1 day'
  where jurisdiction='AU';
insert into public.private_provider_approvals (provider,jurisdiction,rule_version,agreement_reference,expires_at,enabled)
  select 'birchal','AU',version,'Disposable contract fixture',now()+interval '1 day',true
  from public.private_market_rules where jurisdiction='AU';
insert into public.investor_profiles values ('ea000000-0000-4000-8000-000000000001','AU','retail');
insert into public.provider_connections (id,user_id,provider,external_subject) values
  ('ea000000-0000-4000-8000-000000000040','ea000000-0000-4000-8000-000000000001','birchal','application-owner');
insert into public.investor_eligibility (user_id,provider,connection_id,jurisdiction,verified_class,verified_at,expires_at,evidence_reference)
  values ('ea000000-0000-4000-8000-000000000001','birchal','ea000000-0000-4000-8000-000000000040','AU','retail',
    now()-interval '1 day',now()+interval '1 day','disposable-eligibility');

set role service_role;
create temporary table application as
  select commitment_id from public.prepare_private_handoff('ea000000-0000-4000-8000-000000000001',
  'ea000000-0000-4000-8000-000000000030',9500,'https://example.test/offer');
select case when count(*)=1 and bool_and(provider_connection_id='ea000000-0000-4000-8000-000000000040')
  then 'ok   handoff binds the verified provider account' else 'FAIL unbound application' end
  from public.investment_commitments where id=(select commitment_id from application);
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from application),'receipt','application_received',now()-interval '1 hour')$q$,
  '22023','provider event cannot predate the handoff');
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  (select commitment_id from application),'receipt','application_received',now()-interval '4 minutes', 'infinity')$q$,
  '22023','an unbounded deadline is refused');
select public.record_private_provider_event('birchal','application-owner',(select commitment_id from application),
  'receipt','application_received',now()-interval '4 minutes',now()+interval '5 days');
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
select case when count(*)=1 then 'ok   confirmed withdrawal releases the recorded cap' else 'FAIL retained cap' end
  from public.prepare_private_handoff('ea000000-0000-4000-8000-000000000001',
    'ea000000-0000-4000-8000-000000000031',501,'https://example.test/offer');

reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','ea000000-0000-4000-8000-000000000002',true) is not null;
select case when count(*)=0 then 'ok   another account cannot read the application timeline' else 'FAIL cross-tenant timeline' end
  from public.investment_commitments;
select pg_temp.expect_application_error($q$select public.record_private_provider_event('birchal','application-owner',
  null,'receipt','withdrawn',now())$q$,'42501','mobile users cannot mark a withdrawal');
reset role;
rollback;
