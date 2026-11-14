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
select public.configure_private_monitor('ed000000-0000-4000-8000-000000000002',
  'ed000000-0000-4000-8000-000000000071',array['ed000000-0000-4000-8000-000000000010']::uuid[],false,true);
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
select public.configure_private_monitor('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',array[]::uuid[],false,true);
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=0
  then 'ok   a partial sale does not create an exit alert' else 'FAIL alert for partial sale' end;
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
select public.configure_private_monitor('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',array[]::uuid[],false,false);
select case when public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-two',now()-interval '2 days','AUD','Final sale receipt',false,current_date-3,75,700)
  then 'ok   sale can settle all remaining units' else 'FAIL full sale' end;
select case when remaining_units=0 and last_disposition_on=current_date-3 and exit_source='Final sale receipt'
  then 'ok   full exit retains its settlement date and source' else 'FAIL exit evidence' end
  from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=0
  then 'ok   full exits are not collected without monitoring consent' else 'FAIL unsolicited exit alert' end;
select public.configure_private_monitor('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',array[]::uuid[],false,true);
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=1
  then 'ok   the opted-in owner receives the full-exit alert' else 'FAIL missing exit alert' end;
select case when count(*)=1 and bool_and(source_label='Final sale receipt' and occurred_at=now()-interval '2 days'
    and significance like '%' || (current_date-3)::text || '%' and source_url is null)
  then 'ok   the alert includes the settlement source, report timestamp and date' else 'FAIL alert evidence' end
  from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') where kind='holding_exit';
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000002')=0
  and not exists (select 1 from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000002') where kind='holding_exit')
  then 'ok   a different user following the company cannot see the private exit' else 'FAIL exit alert isolation' end;
reset role;
select case when public.private_market_push_through('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',0) is not null
  then 'ok   active settlement evidence can trigger a generic push' else 'FAIL missing exit push' end;
set role service_role;
select public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-two',now()-interval '36 hours','AUD','Revised sale receipt',false,current_date-3,75,710);
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=0
  then 'ok   correcting an already alerted settlement creates no duplicate' else 'FAIL duplicate exit alert' end;
select case when count(*)=1 and bool_and(source_label='Revised sale receipt' and occurred_at=now()-interval '36 hours')
  then 'ok   an existing alert presents the newest provider evidence' else 'FAIL stale exit alert' end
  from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') where kind='holding_exit';
select case when public.record_private_holding_disposition('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'sale-two',now()-interval '1 day','AUD','Provider reversal',true)
  then 'ok   the provider can reverse a sale' else 'FAIL reversal' end;
select case when remaining_units=75 and last_disposition_on=current_date-5 and exit_source is null
    and disposition_revision_at=now()-interval '1 day'
  then 'ok   a reversal reopens the holding and invalidates older valuations' else 'FAIL reversed balance' end
  from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';
select case when count(*)=0 then 'ok   a reversal removes the full exit from the inbox' else 'FAIL reversed exit alert' end
  from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') where kind='holding_exit';

reset role;
select case when public.private_market_push_through('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',0) is null
  then 'ok   a reversal cancels any unsent push' else 'FAIL reversed exit push' end;
set role service_role;
select public.configure_private_monitor('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',array[]::uuid[],false,false);
select public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution','dist-older',now()-interval '8 days',50,'AUD',current_date-9,'Older payment statement');
select public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution','dist-new',now()-interval '1 day',125,'AUD',current_date-2,'Provider distribution statement');
insert into public.distributions (id,user_id,holding_id,amount,received_on,source) values
  ('ed000000-0000-4000-8000-000000000080','ed000000-0000-4000-8000-000000000001',
   'ed000000-0000-4000-8000-000000000060',75,current_date-2,'No provider reference');
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=0
  then 'ok   opted-out investors receive no distribution alert' else 'FAIL distribution without consent' end;
select public.configure_private_monitor('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',array[]::uuid[],false,true);
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=1
  then 'ok   opted-in owner receives only the recent provider-recorded distribution' else 'FAIL distribution alert count' end;
create temporary table distribution_alert as select id, subject_id
  from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') where kind='distribution';
select case when count(*)=1 and bool_and(title='Provider recorded a distribution' and source_label='Provider distribution statement'
    and occurred_at=now()-interval '1 day' and significance='Received on ' || (current_date-2)::text || '.' and source_url is null)
  then 'ok   distribution receipt carries the payment date, report time and source' else 'FAIL distribution evidence' end
  from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') where kind='distribution';
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000002')=0
  and not exists (select 1 from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000002') where kind='distribution')
  then 'ok   following the same company cannot expose an investor distribution' else 'FAIL distribution audience' end;
reset role;
select case when public.private_market_push_through('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',0) is not null
  then 'ok   a recorded distribution is eligible for generic push' else 'FAIL distribution push' end;
set role service_role;
select public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution','dist-new',now()-interval '10 minutes',130,'AUD',current_date-1,'Revised distribution statement');
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=0
  then 'ok   distribution correction does not notify twice' else 'FAIL duplicate distribution alert' end;
select case when count(*)=1 and bool_and(a.source_label='Revised distribution statement' and a.occurred_at=now()-interval '10 minutes'
    and a.significance='Received on ' || (current_date-1)::text || '.')
  then 'ok   corrected distribution evidence appears on the same alert' else 'FAIL stale distribution evidence' end
  from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') a
  join distribution_alert prior using (id, subject_id);
select pg_temp.expect_disposition_error($q$select public.record_private_holding_activity('birchal','other-provider-account',
  'ed000000-0000-4000-8000-000000000060','distribution_reversal','dist-new',now(),null,'AUD',null,'Wrong account')$q$,
  '42501','another provider account cannot reverse a distribution');
select pg_temp.expect_disposition_error($q$select public.record_private_holding_activity('birchal','disposition-owner',
  'ed000000-0000-4000-8000-000000000060','distribution_reversal','dist-unknown',now(),null,'AUD',null,'Unknown payment')$q$,
  '22023','a reversal must refer to an existing provider payment');
select pg_temp.expect_disposition_error($q$select public.record_private_holding_activity('birchal','disposition-owner',
  'ed000000-0000-4000-8000-000000000060','distribution_reversal','dist-new',now(),5,'AUD',null,'Conflicting amount')$q$,
  '22023','a reversal cannot introduce another cash amount');
select case when public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution_reversal','dist-new',now()-interval '5 minutes',null,'AUD',null,'Provider payment reversal')
  then 'ok   provider reverses an existing distribution' else 'FAIL distribution reversal not recorded' end;
select case when amount=130 and source='Revised distribution statement' and reversal_source='Provider payment reversal'
    and reversed_at=now()-interval '5 minutes' and provider_event_at=now()-interval '10 minutes'
  then 'ok   reversal preserves the original payment and its provider evidence' else 'FAIL distribution reversal evidence' end
  from public.distributions where id=(select subject_id from distribution_alert);
select case when not public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution_reversal','dist-new',now()-interval '5 minutes',null,'AUD',null,'Replayed reversal')
  then 'ok   replay of a reversal has no effect' else 'FAIL duplicate reversal' end;
select case when not public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution','dist-new',now()-interval '6 minutes',140,'AUD',current_date-1,'Late payment revision')
  then 'ok   an older record cannot restore a reversed payment' else 'FAIL stale revision restored payment' end;
select case when not exists (
  select 1 from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') where kind='distribution')
  then 'ok   reversing the payment hides the distribution alert' else 'FAIL reversed distribution alert' end;
reset role;
select case when public.private_market_push_through('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000070',0) is null
  then 'ok   reversal cancels any unsent distribution push' else 'FAIL reversed distribution push' end;
set role service_role;
select case when public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution','dist-new',now()-interval '1 minute',145,'AUD',current_date-1,'Reinstated provider payment')
  then 'ok   a newer payment record can reinstate the distribution' else 'FAIL reinstatement was lost' end;
select case when public.collect_private_market_alerts('ed000000-0000-4000-8000-000000000001')=0
  then 'ok   reinstatement reuses the original alert' else 'FAIL duplicate alert after reinstatement' end;
select case when count(*)=1 and bool_and(a.source_label='Reinstated provider payment')
  then 'ok   reinstated payment appears with current evidence' else 'FAIL stale reinstated evidence' end
  from public.private_market_alert_inbox('ed000000-0000-4000-8000-000000000001') a
  join distribution_alert prior using (id, subject_id);
select public.record_private_holding_activity('birchal','disposition-owner','ed000000-0000-4000-8000-000000000060',
  'distribution_reversal','dist-new',now(),null,'AUD',null,'Final provider reversal');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','ed000000-0000-4000-8000-000000000001',true) is not null;
select case when count(*)=2 and count(*) filter(where reversed)=1
  then 'ok   the owner can audit their own settlements and reversal' else 'FAIL owner settlement read' end
  from public.private_holding_dispositions;
select pg_temp.expect_disposition_error($q$select public.record_private_holding_disposition('birchal','disposition-owner',
  'ed000000-0000-4000-8000-000000000060','sale-one',now(),'AUD','Client attempt',true)$q$,
  '42501','even an owner cannot submit a sale or reversal');
select pg_temp.expect_disposition_error($q$select * from public.private_current_holding_exits$q$,
  '42501','clients cannot read the exit evidence view directly');
select pg_temp.expect_disposition_error($q$select * from public.private_reported_distributions$q$,
  '42501','clients cannot read the distribution evidence view directly');
select set_config('request.jwt.claim.sub','ed000000-0000-4000-8000-000000000002',true) is not null;
select case when count(*)=0 then 'ok   sale evidence is tenant isolated' else 'FAIL tenant isolation' end
  from public.private_holding_dispositions;
reset role;
delete from public.private_holdings where id='ed000000-0000-4000-8000-000000000060';
select case when count(*)=0 then 'ok   deleting ownership erases its sale evidence' else 'FAIL sale data retention' end
  from public.private_holding_dispositions where holding_id='ed000000-0000-4000-8000-000000000060';
rollback;
