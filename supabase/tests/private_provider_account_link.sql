\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;
create function pg_temp.refused(statement text, expected text, label text) returns text language plpgsql as $$
begin
  execute statement;
  return 'FAIL ' || label || ' (allowed)';
exception when others then
  return case when sqlstate = expected then 'ok ' || label else 'FAIL ' || label || ' (' || sqlstate || ')' end;
end $$;
select format('grant usage on schema %I to service_role', nspname)
  from pg_namespace where oid = pg_my_temp_schema() \gexec

insert into auth.users (id) values ('c5000000-0000-4000-8000-000000000001'), ('c5000000-0000-4000-8000-000000000002');
insert into auth.sessions (id,user_id) values
  ('c5000000-0000-4000-8000-000000000011','c5000000-0000-4000-8000-000000000001'),
  ('c5000000-0000-4000-8000-000000000012','c5000000-0000-4000-8000-000000000002');
insert into public.investor_profiles values
  ('c5000000-0000-4000-8000-000000000001','AU','retail'),
  ('c5000000-0000-4000-8000-000000000002','AU','retail');
select case when not has_function_privilege('authenticated','public.issue_private_account_link(uuid,uuid,text,text)','execute')
  and not has_function_privilege('anon','public.redeem_private_account_link(text,text,text,text,timestamptz,jsonb)','execute')
  then 'ok account-link RPCs are service only' else 'FAIL account-link privileges' end;

set local role service_role;
select pg_temp.refused($q$select public.issue_private_account_link(
  'c5000000-0000-4000-8000-000000000001','c5000000-0000-4000-8000-000000000011','birchal',repeat('a',64))$q$,
  '42501','an account cannot get a code without route approval');
reset role;
update public.private_market_rules set handoff_enabled=true, reviewed_at=now()-interval '1 day', effective_at=now()-interval '1 day'
  where jurisdiction='AU';
insert into public.private_provider_approvals
  (provider,jurisdiction,rule_version,agreement_reference,expires_at,enabled,account_link_enabled)
  select 'birchal','AU',version,'Disposable link agreement',now()+interval '1 day',true,true
  from public.private_market_rules where jurisdiction='AU';

set local role service_role;
select pg_temp.refused($q$select public.issue_private_account_link(
  'c5000000-0000-4000-8000-000000000001','c5000000-0000-4000-8000-000000000012','birchal',repeat('a',64))$q$,
  '42501','code issuance checks the account and session together');
select case when public.issue_private_account_link(
  'c5000000-0000-4000-8000-000000000001','c5000000-0000-4000-8000-000000000011','birchal',repeat('a',64))=now()+interval '10 min'
  then 'ok an approved route issues a short-lived code' else 'FAIL code expiry' end;
select pg_temp.refused($q$select public.redeem_private_account_link('onmarket','wrong',repeat('b',64),'verified-1',now(),
  jsonb_build_object('code_digest',repeat('a',64),'jurisdiction','AU','verified_class','retail','evidence_reference','receipt','expires_at',now()+interval '1 hour'))$q$,
  '42501','a second provider cannot redeem the digest');
select pg_temp.refused($q$select public.redeem_private_account_link('birchal','wrong-region',repeat('b',64),'verified-1',now(),
  jsonb_build_object('code_digest',repeat('a',64),'jurisdiction','NZ','verified_class','retail','evidence_reference','receipt','expires_at',now()+interval '1 hour'))$q$,
  '42501','the signed verification must match the approved jurisdiction');
select case when public.redeem_private_account_link('birchal','link-1',repeat('b',64),'verified-1',now(),
  jsonb_build_object('code_digest',repeat('a',64),'jurisdiction','AU','verified_class','retail','evidence_reference','receipt','expires_at',now()+interval '1 hour'))='accepted'
  then 'ok signed-account operation binds the subject and records eligibility' else 'FAIL redeemed code' end;
select case when public.redeem_private_account_link('birchal','link-1',repeat('b',64),'verified-1',now(),
  jsonb_build_object('code_digest',repeat('a',64),'jurisdiction','AU','verified_class','retail'))='duplicate'
  then 'ok exact retries survive code consumption' else 'FAIL duplicate link delivery' end;
select pg_temp.refused($q$select public.redeem_private_account_link('birchal','other-id',repeat('c',64),'verified-1',now(),
  jsonb_build_object('code_digest',repeat('a',64),'jurisdiction','AU','verified_class','retail'))$q$,
  '42501','different delivery cannot reuse a redeemed code');
select public.issue_private_account_link(
  'c5000000-0000-4000-8000-000000000002','c5000000-0000-4000-8000-000000000012','birchal',repeat('d',64));
select pg_temp.refused($q$select public.issue_private_account_link(
  'c5000000-0000-4000-8000-000000000002','c5000000-0000-4000-8000-000000000012','birchal',repeat('e',64))$q$,
  'P0001','issuing multiple codes in quick succession is throttled');
update provider_operations.private_link_codes set issued_at=now()-interval '6 seconds' where digest=repeat('d',64);
select public.issue_private_account_link(
  'c5000000-0000-4000-8000-000000000002','c5000000-0000-4000-8000-000000000012','birchal',repeat('e',64));
select pg_temp.refused($q$select public.redeem_private_account_link('birchal','replaced',repeat('c',64),'verified-2',now(),
  jsonb_build_object('code_digest',repeat('d',64),'jurisdiction','AU','verified_class','retail','evidence_reference','receipt','expires_at',now()+interval '1 hour'))$q$,
  '42501','replacing a code invalidates the old digest');
select pg_temp.refused($q$select public.redeem_private_account_link('birchal','collision',repeat('d',64),'verified-1',now(),
  jsonb_build_object('code_digest',repeat('e',64),'jurisdiction','AU','verified_class','retail','evidence_reference','receipt','expires_at',now()+interval '1 hour'))$q$,
  '42501','an existing provider subject cannot be transferred to another owner');
update provider_operations.private_link_codes set expires_at=now()-interval '1 second' where digest=repeat('e',64);
select pg_temp.refused($q$select public.redeem_private_account_link('birchal','expired',repeat('d',64),'verified-2',now(),
  jsonb_build_object('code_digest',repeat('e',64),'jurisdiction','AU','verified_class','retail','evidence_reference','receipt','expires_at',now()+interval '1 hour'))$q$,
  '42501','an expired code cannot link an account');
update provider_operations.private_link_codes set expires_at=now()+interval '1 minute' where digest=repeat('e',64);
reset role;
delete from auth.sessions where id='c5000000-0000-4000-8000-000000000012';
set local role service_role;
select pg_temp.refused($q$select public.redeem_private_account_link('birchal','revoked',repeat('d',64),'verified-2',now(),
  jsonb_build_object('code_digest',repeat('e',64),'jurisdiction','AU','verified_class','retail','evidence_reference','receipt','expires_at',now()+interval '1 hour'))$q$,
  '42501','closing the issuing session invalidates its unused code');
rollback;
