\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

create function pg_temp.expect_disposition_error(statement text, expected text, label text) returns text language plpgsql as $$
begin
  execute statement;
  return 'FAIL ' || label || ' (allowed)';
exception when others then
  return case when sqlstate = expected then 'ok   ' || label else 'FAIL ' || label || ' (' || sqlstate || ': ' || sqlerrm || ')' end;
end $$;
select format('grant usage on schema %I to authenticated, service_role', nspname)
  from pg_namespace where oid = pg_my_temp_schema() \gexec

insert into auth.users (id,email) values
  ('ed000000-0000-4000-8000-000000000001','disposition-fixture@example.test'),
  ('ed000000-0000-4000-8000-000000000002','second-disposition-fixture@example.test');
insert into public.private_companies (id,name,sector,country,source_url,verified_at,published) values
  ('ed000000-0000-4000-8000-000000000010','Disposal issuer','Technology','AU','https://example.test/company',now(),true);
insert into public.funding_rounds (id,company_id,stage,currency,source_url,verified_at,published) values
  ('ed000000-0000-4000-8000-000000000020','ed000000-0000-4000-8000-000000000010','Seed','AUD','https://example.test/round',now(),true);
insert into public.investment_opportunities
  (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,verified_at,published) values
  ('ed000000-0000-4000-8000-000000000030','ed000000-0000-4000-8000-000000000020','birchal','Crowdfunding','closed',100,'retail',array['AU'],
    'https://www.birchal.com/example',now(),true);
insert into public.provider_connections (id,user_id,provider,external_subject) values
  ('ed000000-0000-4000-8000-000000000040','ed000000-0000-4000-8000-000000000001','birchal','disposition-owner'),
  ('ed000000-0000-4000-8000-000000000041','ed000000-0000-4000-8000-000000000002','birchal','other-provider-account');
insert into public.private_provider_approvals
  (provider,jurisdiction,rule_version,agreement_reference,expires_at,holding_activity_enabled)
  select 'birchal','AU',version,'Disposable contract fixture',now()+interval '1 day',true
  from public.private_market_rules where jurisdiction='AU';
insert into public.investment_commitments
  (id,user_id,opportunity_id,provider,jurisdiction,rule_version,reviewed_document_url,requested_amount,currency,
   acknowledged_at,status,provider_reference,confirmed_at,provider_event_at,provider_connection_id)
  select 'ed000000-0000-4000-8000-000000000050','ed000000-0000-4000-8000-000000000001',
         'ed000000-0000-4000-8000-000000000030','birchal','AU',version,'https://example.test/offer',1000,'AUD',
         now()-interval '1 month','confirmed','fixture-opening',now()-interval '3 weeks',now()-interval '3 weeks',
         'ed000000-0000-4000-8000-000000000040'
    from public.private_market_rules where jurisdiction='AU';
insert into public.private_holdings
  (id,user_id,company_id,commitment_id,name,asset_class,currency,committed_amount,units,settled_amount,
   confirmed_at,settled_on,settlement_source)
  values ('ed000000-0000-4000-8000-000000000060','ed000000-0000-4000-8000-000000000001',
          'ed000000-0000-4000-8000-000000000010','ed000000-0000-4000-8000-000000000050','Disposal issuer',
          'Startup equity','AUD',1000,100,1000,now()-interval '3 weeks',current_date-21,'Opening statement');

set role service_role;
select pg_temp.expect_disposition_error($q$select public.record_private_holding_disposition('birchal','disposition-owner',
  'ed000000-0000-4000-8000-000000000060','sale-one',now()-interval '4 days','AUD','Sale receipt',false,current_date-5,30,500,300)$q$,
  '42501','position activity approval alone does not permit sale ingestion');
reset role;
update public.private_provider_approvals set disposition_activity_enabled=true where provider='birchal' and jurisdiction='AU';

set role service_role;
select pg_temp.expect_disposition_error($q$select public.record_private_holding_disposition('birchal','other-provider-account',
  'ed000000-0000-4000-8000-000000000060','sale-one',now()-interval '4 days','AUD','Sale receipt',false,current_date-5,30,500,300)$q$,
  '42501','another provider account cannot add a sale');
select pg_temp.expect_disposition_error($q$select public.record_private_holding_disposition('birchal','disposition-owner',
  'ed000000-0000-4000-8000-000000000060','sale-one',now()-interval '4 days','USD','Sale receipt',false,current_date-5,30,500,300)$q$,
  '22023','settlement currency must match the holding');
select case when public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-one',now()-interval '4 days','AUD','Sale receipt',false,current_date-5,30,500,300)
  then 'ok   the provider can report a partial sale' else 'FAIL partial sale' end;
select case when units=100 and remaining_units=70 and last_disposition_on=current_date-5 and exit_source is null
  then 'ok   a partial sale preserves original units and records the remaining position' else 'FAIL partial balance' end
  from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';
select case when not public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-one',now()-interval '4 days','AUD','Sale receipt',false,current_date-5,30,500,300)
  then 'ok   replay does not add a second sale' else 'FAIL replay' end;
select case when not public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-one',now()-interval '5 days','AUD','Older receipt',false,current_date-5,20,400,200)
  then 'ok   a late event cannot replace a newer sale revision' else 'FAIL old event' end;
select pg_temp.expect_disposition_error($q$select public.record_private_holding_disposition('birchal','disposition-owner',
  'ed000000-0000-4000-8000-000000000060','sale-two',now()-interval '3 days','AUD','Excess sale',false,current_date-4,71,700)$q$,
  '22023','aggregate sales cannot exceed confirmed units');
select case when count(*)=1 and sum(sold_units)=30 then 'ok   an oversell leaves the ledger unchanged' else 'FAIL oversell rollback' end
  from public.private_holding_dispositions where holding_id='ed000000-0000-4000-8000-000000000060';
select case when public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-one',now()-interval '3 days','AUD','Corrected receipt',false,current_date-5,25,450,250)
  then 'ok   a correction replaces a settlement' else 'FAIL correction' end;
select case when remaining_units=75 then 'ok   a correction recomputes remaining units' else 'FAIL corrected balance' end
  from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';
select case when public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-two',now()-interval '2 days','AUD','Final sale receipt',false,current_date-3,75,700)
  then 'ok   sale can settle all remaining units' else 'FAIL full sale' end;
select case when remaining_units=0 and last_disposition_on=current_date-3 and exit_source='Final sale receipt'
  then 'ok   full exit retains its settlement date and source' else 'FAIL exit evidence' end
  from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';
select case when public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-two',now()-interval '1 day','AUD','Provider reversal',true)
  then 'ok   the provider can reverse a sale' else 'FAIL reversal' end;
select case when remaining_units=75 and last_disposition_on=current_date-5 and exit_source is null
    and disposition_revision_at=now()-interval '1 day'
  then 'ok   a reversal reopens the holding and invalidates older valuations' else 'FAIL reversed balance' end
  from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';

reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','ed000000-0000-4000-8000-000000000001',true) is not null;
select case when count(*)=2 and count(*) filter(where reversed)=1
  then 'ok   the owner can audit their own settlements and reversal' else 'FAIL owner settlement read' end
  from public.private_holding_dispositions;
select pg_temp.expect_disposition_error($q$select public.record_private_holding_disposition('birchal','disposition-owner',
  'ed000000-0000-4000-8000-000000000060','sale-one',now(),'AUD','Client attempt',true)$q$,
  '42501','even an owner cannot submit a sale or reversal');
select set_config('request.jwt.claim.sub','ed000000-0000-4000-8000-000000000002',true) is not null;
select case when count(*)=0 then 'ok   sale evidence is tenant isolated' else 'FAIL tenant isolation' end
  from public.private_holding_dispositions;
reset role;
delete from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';
select case when count(*)=0 then 'ok   deleting ownership erases its sale evidence' else 'FAIL sale data retention' end
  from public.private_holding_dispositions where holding_id='ed000000-0000-4000-8000-000000000060';
rollback;
