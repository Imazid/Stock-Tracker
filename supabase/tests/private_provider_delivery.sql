\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

create function pg_temp.expect_delivery_error(statement text, expected text, label text) returns text language plpgsql as $$
begin
  execute statement;
  return 'FAIL ' || label || ' (allowed)';
exception when others then
  return case when sqlstate = expected then 'ok   ' || label else 'FAIL ' || label || ' (' || sqlstate || ': ' || sqlerrm || ')' end;
end $$;
select format('grant usage on schema %I to authenticated, service_role', nspname)
  from pg_namespace where oid = pg_my_temp_schema() \gexec

insert into auth.users (id,email) values
  ('f3000000-0000-4000-8000-000000000001','delivery-one@example.test'),
  ('f3000000-0000-4000-8000-000000000002','delivery-two@example.test');
insert into auth.sessions (id,user_id) values
  ('f3000000-0000-4000-8000-000000000008','f3000000-0000-4000-8000-000000000001');
insert into public.investor_profiles values ('f3000000-0000-4000-8000-000000000001','AU','retail');
insert into public.provider_connections (id,user_id,provider,external_subject) values
  ('f3000000-0000-4000-8000-000000000003','f3000000-0000-4000-8000-000000000001','birchal','delivery-owner'),
  ('f3000000-0000-4000-8000-000000000004','f3000000-0000-4000-8000-000000000002','birchal','delivery-other');
insert into public.private_companies (id,name,sector,country,source_url,verified_at,published) values
  ('f3000000-0000-4000-8000-000000000010','Delivery fixture','Technology','AU','https://example.test/company',now(),true);
insert into public.funding_rounds (id,company_id,stage,currency,closes_at,source_url,verified_at,published) values
  ('f3000000-0000-4000-8000-000000000020','f3000000-0000-4000-8000-000000000010','Seed','AUD',now()+interval '1 day','https://example.test/round',now(),true);
insert into public.investment_opportunities
  (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,handoff_url,offer_document_url,verified_at,published) values
  ('f3000000-0000-4000-8000-000000000030','f3000000-0000-4000-8000-000000000020','birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/delivery-fixture','https://www.birchal.com/delivery-fixture','https://example.test/delivery',now(),true);
update public.private_market_rules set handoff_enabled=true, reviewed_at=now()-interval '1 day', effective_at=now()-interval '1 day'
  where jurisdiction='AU';
insert into public.private_provider_approvals
  (provider,jurisdiction,rule_version,agreement_reference,expires_at,enabled,holding_activity_enabled,disposition_activity_enabled)
  select 'birchal','AU',version,'Disposable adapter test',now()+interval '1 day',true,true,true
  from public.private_market_rules where jurisdiction='AU';
insert into public.investment_commitments
  (id,user_id,provider,provider_connection_id,jurisdiction,rule_version,opportunity_id,reviewed_document_url,
   requested_amount,currency,acknowledged_at,retail_csf_cooling_off_required)
  select 'f3000000-0000-4000-8000-000000000040','f3000000-0000-4000-8000-000000000001','birchal',
    'f3000000-0000-4000-8000-000000000003','AU',version,'f3000000-0000-4000-8000-000000000030',
    'https://example.test/delivery',500,'AUD',now()-interval '12 days',true
  from public.private_market_rules where jurisdiction='AU';

set role authenticated;
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_delivery(
  'birchal','mobile',repeat('a',64),'verification','delivery-owner',now(),'{}')$q$,
  '42501','mobile users cannot directly submit provider deliveries');
reset role;
set role service_role;

select pg_temp.expect_delivery_error($q$select public.accept_private_provider_delivery(
  'birchal','missing',repeat('a',64),'verification','unbound',now(),'{}')$q$,
  '42501','delivery cannot establish a new provider account link');
select case when public.accept_private_provider_delivery(
  'birchal','verify',repeat('a',64),'verification','delivery-owner',now()-interval '13 days',
  jsonb_build_object('jurisdiction','AU','evidence_reference','review','verified_class','retail','expires_at',now()+interval '1 day')) = 'accepted'
  then 'ok   verified events update the established provider account' else 'FAIL verification delivery' end;
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_delivery(
  'birchal','receipt',repeat('b',64),'application','delivery-other',now()-interval '10 days',
  '{"commitment_id":"f3000000-0000-4000-8000-000000000040","reference":"receipt-1","status":"application_received"}')$q$,
  '42501','wrong provider subject cannot use a different investor commitment');
select case when not exists (select 1 from provider_operations.private_event_deliveries where event_id='receipt')
  then 'ok   a failed update rolls its replay receipt back' else 'FAIL receipt persisted after rejection' end;
select case when public.accept_private_provider_delivery(
  'birchal','receipt',repeat('b',64),'application','delivery-owner',now()-interval '10 days',
  jsonb_build_object('commitment_id','f3000000-0000-4000-8000-000000000040','reference','receipt-1','status','application_received',
    'application_currency','AUD','application_amount','500.4321','cooling_off_ends_at',now()-interval '5 days')) = 'accepted'
  then 'ok   a valid event can be retried after refusal' else 'FAIL legitimate receipt delivery' end;
select case when public.accept_private_provider_delivery(
  'birchal','receipt',repeat('b',64),'application','delivery-owner',now()-interval '10 days',
  jsonb_build_object('commitment_id','f3000000-0000-4000-8000-000000000040','reference','receipt-1','status','application_received',
    'application_currency','AUD','application_amount','500.4321','cooling_off_ends_at',now()-interval '5 days')) = 'duplicate'
  then 'ok   same event and body return a duplicate acknowledgement' else 'FAIL replay classification' end;
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_delivery(
  'birchal','receipt',repeat('c',64),'application','delivery-owner',now()-interval '10 days','{}')$q$,
  '23505','an event ID with changed content is refused');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_delivery(
  'birchal','too-early',repeat('c',64),'application','delivery-owner',now()-interval '8 days',
  '{"commitment_id":"f3000000-0000-4000-8000-000000000040","reference":"receipt-1","status":"confirmed",
    "units":"3.12345678","invested_amount":"500.4321"}')$q$,
  '22023','a signed receipt cannot settle during cooling-off');
select case when public.accept_private_provider_delivery(
  'birchal','settled',repeat('c',64),'application','delivery-owner',now()-interval '4 days',
  '{"commitment_id":"f3000000-0000-4000-8000-000000000040","reference":"receipt-1","status":"confirmed",
    "units":"3.12345678","invested_amount":"500.4321"}') = 'accepted'
  then 'ok   provider confirmation passes through the ordinary settlement rules' else 'FAIL settlement delivery' end;
select case when units=3.12345678 and settled_amount=500.4321 and user_id='f3000000-0000-4000-8000-000000000001'
  then 'ok   confirmation creates the owner’s position with exact amounts' else 'FAIL incorrect confirmed holding' end
  from public.private_holdings where commitment_id='f3000000-0000-4000-8000-000000000040';

select case when public.accept_private_provider_delivery(
  'birchal','mark',repeat('d',64),'holding_activity','delivery-owner',now()-interval '3 days',
  jsonb_build_object('holding_id',id,'reference','valuation-1','activity','valuation','currency','AUD','amount','530.4321',
    'record_date',(now()-interval '4 days')::date,'source','Statement','method','NAV')) = 'accepted'
  then 'ok   provider activity reaches the owner ledger' else 'FAIL activity delivery' end
  from public.private_holdings where commitment_id='f3000000-0000-4000-8000-000000000040';
select case when public.accept_private_provider_delivery(
  'birchal','sale',repeat('e',64),'holding_disposition','delivery-owner',now()-interval '2 days',
  jsonb_build_object('holding_id',id,'reference','sale-1','currency','AUD','source','Provider sale statement','reversed',false,
    'settled_on',(now()-interval '2 days')::date,'sold_units','1.01234567','net_proceeds','120.1234')) = 'accepted'
  then 'ok   provider sale reaches the disposition ledger' else 'FAIL sale delivery' end
  from public.private_holdings where commitment_id='f3000000-0000-4000-8000-000000000040';
select case when remaining_units=2.11111111
  then 'ok   accepted disposition recomputes exact remaining units' else 'FAIL remaining units' end
  from public.private_holdings where commitment_id='f3000000-0000-4000-8000-000000000040';
select case when count(*)=5 and count(*) filter (where body_sha256 in (repeat('a',64),repeat('b',64),repeat('c',64),repeat('d',64),repeat('e',64)))=5
  then 'ok   only accepted deliveries retain a replay receipt' else 'FAIL replay receipt count' end
  from provider_operations.private_event_deliveries where user_id='f3000000-0000-4000-8000-000000000001';
reset role;
update public.investment_opportunities set provider_offer_reference = 'offer-A'
where id = 'f3000000-0000-4000-8000-000000000030';

insert into public.investment_commitments
  (id,user_id,provider,provider_connection_id,jurisdiction,rule_version,opportunity_id,reviewed_document_url,
   requested_amount,currency,acknowledged_at,retail_csf_cooling_off_required)
  select 'f3000000-0000-4000-8000-000000000041','f3000000-0000-4000-8000-000000000002','birchal',
    'f3000000-0000-4000-8000-000000000004','AU',version,'f3000000-0000-4000-8000-000000000030',
    'https://example.test/delivery',500,'AUD',now()-interval '12 days',true
  from public.private_market_rules where jurisdiction='AU';

set role authenticated;
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','mobile-ref',repeat('a',64),'application','delivery-other',now(),'{}')$q$,
  '42501','reference delivery is service only');
select case when not has_column_privilege('authenticated','public.investment_opportunities','provider_offer_reference','SELECT')
  and not has_column_privilege('anon','public.investment_opportunities','provider_offer_reference','SELECT')
  then 'ok   provider offer references stay internal' else 'FAIL provider reference visible' end;
reset role;
set role service_role;

select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','used',repeat('a',64),'application','delivery-other',now()-interval '10 days',
  '{"offer_reference":"offer-A","reference":"receipt-1","status":"application_received"}')$q$,
  '42501','another investor cannot claim an existing provider receipt');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','wrong-offer',repeat('a',64),'application','delivery-other',now()-interval '10 days',
  '{"offer_reference":"offer-B","reference":"second-receipt","status":"application_received"}')$q$,
  '42501','an unmapped offer cannot capture a handoff');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','old',repeat('a',64),'application','delivery-other',now()-interval '13 days',
  '{"offer_reference":"offer-A","reference":"second-receipt","status":"application_received"}')$q$,
  '42501','the first receipt cannot predate the current handoff');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','early-confirmation',repeat('a',64),'application','delivery-other',now()-interval '10 days',
  '{"offer_reference":"offer-A","reference":"second-receipt","status":"confirmed","units":"2","invested_amount":"500"}')$q$,
  '42501','only an application receipt can establish the first match');

select case when public.accept_private_provider_reference_delivery(
  'birchal','by-offer',repeat('a',64),'application','delivery-other',now()-interval '10 days',
  jsonb_build_object('offer_reference','offer-A','reference','second-receipt','status','application_received',
    'application_currency','AUD','application_amount','500.4321','cooling_off_ends_at',now()-interval '5 days')) = 'accepted'
  then 'ok   signed provider receipt can bind using provider references only' else 'FAIL provider receipt reference match' end;
select case when provider_reference='second-receipt' and status='application_received' and provider_application_amount=500.4321
  then 'ok   provider receipt updated the correct owner and amount' else 'FAIL provider receipt state' end
  from public.investment_commitments where id='f3000000-0000-4000-8000-000000000041';
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','before-window',repeat('a',64),'application','delivery-other',now()-interval '6 days',
  '{"offer_reference":"offer-A","reference":"second-receipt","status":"confirmed","units":"2","invested_amount":"500"}')$q$,
  '22023','matching by provider references honors the cooling-off deadline');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','before-confirmation',repeat('a',64),'holding_activity','delivery-other',now()-interval '4 days',
  '{"offer_reference":"offer-A","application_reference":"second-receipt","activity":"valuation","reference":"mark-2","currency":"AUD","source":"Statement"}')$q$,
  '42501','holding updates require a confirmed holding');

select case when public.accept_private_provider_reference_delivery(
  'birchal','reference-settlement',repeat('b',64),'application','delivery-other',now()-interval '4 days',
  '{"offer_reference":"offer-A","reference":"second-receipt","status":"confirmed","units":"3.12345678","invested_amount":"500.4321"}') = 'accepted'
  then 'ok   provider references reconcile confirmed ownership' else 'FAIL provider reference settlement' end;
select case when public.accept_private_provider_reference_delivery(
  'birchal','by-offer',repeat('a',64),'application','delivery-other',now()-interval '10 days',
  jsonb_build_object('offer_reference','offer-A','reference','second-receipt','status','application_received',
    'application_currency','AUD','application_amount','500.4321','cooling_off_ends_at',now()-interval '5 days')) = 'duplicate'
  then 'ok   first receipt retries succeed after ownership is confirmed' else 'FAIL replay after settlement' end;
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','by-offer',repeat('d',64),'application','delivery-other',now()-interval '10 days',
  '{"offer_reference":"offer-A","reference":"second-receipt","status":"application_received"}')$q$,
  '23505','provider reference retries must match the original body');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','someone-else',repeat('e',64),'holding_activity','delivery-owner',now()-interval '3 days',
  '{"offer_reference":"offer-A","application_reference":"second-receipt","activity":"valuation","reference":"mark-2","currency":"AUD","source":"Statement"}')$q$,
  '42501','provider references do not expose another investor’s holding');
select case when public.accept_private_provider_reference_delivery(
  'birchal','reference-mark',repeat('c',64),'holding_activity','delivery-other',now()-interval '3 days',
  jsonb_build_object('offer_reference','offer-A','application_reference','second-receipt','activity','valuation',
    'reference','mark-2','currency','AUD','source','Statement','method','NAV','amount','720.125',
    'record_date',(now()-interval '3 days')::date)) = 'accepted'
  then 'ok   provider references resolve a holding valuation' else 'FAIL reference valuation delivery' end;
select case when public.accept_private_provider_reference_delivery(
  'birchal','reference-sale',repeat('d',64),'holding_disposition','delivery-other',now()-interval '2 days',
  jsonb_build_object('offer_reference','offer-A','application_reference','second-receipt','reference','sale-2',
    'currency','AUD','source','Statement','reversed',false,'settled_on',(now()-interval '2 days')::date,
    'sold_units','1.12345678','net_proceeds','100.1234')) = 'accepted'
  then 'ok   provider references resolve a settled sale' else 'FAIL reference sale delivery' end;
select case when h.remaining_units=2 and v.value=720.125
  then 'ok   provider references preserve exact position and mark values' else 'FAIL reference holding values' end
  from public.private_holdings h join public.valuation_history v on v.holding_id=h.id
  where h.commitment_id='f3000000-0000-4000-8000-000000000041' and v.provider_reference='mark-2';

select public.disconnect_private_provider(
  'f3000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000008','birchal');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','after-disconnect',repeat('1',64),'holding_activity','delivery-owner',now(),
  jsonb_build_object('offer_reference','offer-A','application_reference','receipt-1','activity','valuation',
    'reference','valuation-2','currency','AUD','source','Statement','method','NAV','amount','920',
    'record_date',now()::date))$q$,
  '42501','the adapter cannot update a detached provider holding');
select pg_temp.expect_delivery_error($q$select public.prepare_private_handoff(
  'f3000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000030',500,'https://example.test/delivery')$q$,
  '42501','a detached connection cannot authorize a handoff');
select case when h.remaining_units=2.11111111 and v.value=530.4321
  then 'ok   disconnect preserves the confirmed position and its last approved mark' else 'FAIL detached holding data' end
  from public.private_holdings h join public.valuation_history v on v.holding_id=h.id
  where h.commitment_id='f3000000-0000-4000-8000-000000000040' and v.provider_reference='valuation-1';
reset role;

-- The optional partner echo binds a receipt to the exact handoff.
insert into public.investor_profiles values ('f3000000-0000-4000-8000-000000000002','AU','retail');
insert into public.investment_opportunities
  (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,handoff_url,
   offer_document_url,verified_at,published,provider_offer_reference,provider_handoff_parameter)
values ('f3000000-0000-4000-8000-000000000031','f3000000-0000-4000-8000-000000000020',
    'birchal','Crowdfunding','open',100,'retail',array['AU'],
    'https://www.birchal.com/echo-fixture','https://www.birchal.com/echo-fixture','https://example.test/echo-offer',
    now(),true,'echo-offer','partner_ref');
select pg_temp.expect_delivery_error($q$
  update public.investment_opportunities set handoff_url='https://www.birchal.com/echo?partner_ref=wrong'
  where provider_offer_reference='echo-offer'$q$,'23514','hosted route cannot predefine the outgoing referral reference');
select case when not has_column_privilege('anon','public.investment_opportunities','provider_handoff_parameter','select')
  and not has_function_privilege('authenticated','provider_operations.record_private_provider_event(text,text,uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text,timestamptz,text,uuid)','execute')
  then 'ok   referral configuration and receipt handler are internal' else 'FAIL referral access' end;
set role service_role;
select public.record_private_provider_verification(
  'f3000000-0000-4000-8000-000000000002','birchal','delivery-other','AU','retail',
  now()-interval '13 days','Disposable eligibility',now()+interval '1 day');
select case when public.check_private_handoff('f3000000-0000-4000-8000-000000000002',
  'f3000000-0000-4000-8000-000000000031',500,'https://example.test/echo-offer','AUD')
  and not exists (select from public.investment_commitments where opportunity_id='f3000000-0000-4000-8000-000000000031')
  then 'ok   readiness does not create an application or referral' else 'FAIL referral created during readiness' end;

select commitment_id as tracked_id, handoff_url as tracked_url
from public.open_private_handoff('f3000000-0000-4000-8000-000000000002',
  'f3000000-0000-4000-8000-000000000031',500,'https://example.test/echo-offer','AUD') \gset
select provider_handoff_reference as tracked_reference
from public.investment_commitments where id=:'tracked_id' \gset
select case when :'tracked_url'='https://www.birchal.com/echo-fixture?partner_ref=' || :'tracked_reference'
  and :'tracked_reference'<>:'tracked_id'
  then 'ok   application link carries a separate opaque reference' else 'FAIL handoff reference URL' end;
select case when handoff_url=:'tracked_url' and commitment_id=:'tracked_id'::uuid
  then 'ok   reopening the handoff reuses its reference' else 'FAIL handoff reference rotated' end
from public.open_private_handoff('f3000000-0000-4000-8000-000000000002',
  'f3000000-0000-4000-8000-000000000031',500,'https://example.test/echo-offer','AUD');

select case when not has_function_privilege('authenticated','public.resume_private_handoff(uuid,uuid,text,text,boolean)','execute')
  then 'ok   handoff resumption is restricted to the authenticated service' else 'FAIL resume function privileges' end;
select pg_temp.expect_delivery_error(format($q$select public.resume_private_handoff(
  'f3000000-0000-4000-8000-000000000001',%L,'https://example.test/echo-offer','AUD',true)$q$,:'tracked_id'),
  '42501','a second investor cannot reopen this handoff');
select pg_temp.expect_delivery_error(format($q$select public.resume_private_handoff(
  'f3000000-0000-4000-8000-000000000002',%L,'https://example.test/echo-offer','USD',false)$q$,:'tracked_id'),
  '22023','reopening uses the recorded currency');
select pg_temp.expect_delivery_error(format($q$select public.resume_private_handoff(
  'f3000000-0000-4000-8000-000000000002',%L,'https://example.test/old-disclosure','AUD',false)$q$,:'tracked_id'),
  '22023','resumption requires the current disclosure');
select case when commitment_id is null and handoff_url is null
  then 'ok   resumption readiness discloses no provider URL' else 'FAIL readiness returned provider URL' end
from public.resume_private_handoff('f3000000-0000-4000-8000-000000000002',:'tracked_id',
  'https://example.test/echo-offer','AUD',false);
select case when commitment_id=:'tracked_id'::uuid and handoff_url=:'tracked_url'
  then 'ok   resumption reuses the exact commitment and referral URL' else 'FAIL wrong resumed handoff' end
from public.resume_private_handoff('f3000000-0000-4000-8000-000000000002',:'tracked_id',
  'https://example.test/echo-offer','AUD',true);
select case when count(*)=1 then 'ok   resuming does not create another application' else 'FAIL duplicate handoff' end
from public.investment_commitments where opportunity_id='f3000000-0000-4000-8000-000000000031';

select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','echo-receipt',repeat('a',64),'application','delivery-other',now(),
  '{"offer_reference":"echo-offer","reference":"echo-1","status":"application_received"}')$q$,
  '42501','offer and investor alone cannot bind an unrelated receipt');
select case when not exists (select from provider_operations.private_event_deliveries where event_id='echo-receipt')
  then 'ok   a failed correlation does not consume the event ID' else 'FAIL wrong receipt persisted' end;
select pg_temp.expect_delivery_error(format($q$select public.record_private_provider_event(
  'birchal','delivery-other',%L,'echo-1','application_received',now())$q$,:'tracked_id'),
  '42501','the legacy service RPC cannot bypass the referral check');
select pg_temp.expect_delivery_error(format($q$select public.accept_private_provider_delivery(
  'birchal','echo-receipt',repeat('a',64),'application','delivery-other',now(),
  jsonb_build_object('commitment_id',%L,'reference','echo-1','status','application_received'))$q$,:'tracked_id'),
  '42501','signed direct-ID delivery cannot bypass the referral check');
select pg_temp.expect_delivery_error($q$select public.accept_private_provider_reference_delivery(
  'birchal','echo-receipt',repeat('a',64),'application','delivery-other',now(),
  '{"offer_reference":"echo-offer","reference":"echo-1","status":"application_received","handoff_reference":"f3000000-0000-4000-8000-000000000042"}')$q$,
  '42501','a mismatched referral cannot bind an application');
select pg_temp.expect_delivery_error(format($q$select public.accept_private_provider_reference_delivery(
  'birchal','echo-receipt',repeat('a',64),'application','delivery-owner',now(),
  jsonb_build_object('offer_reference','echo-offer','reference','echo-1','status','application_received',
    'handoff_reference',%L))$q$,:'tracked_reference'),
  '42501','matching referral reference still requires the linked provider subject');
select case when public.accept_private_provider_reference_delivery(
  'birchal','echo-receipt',repeat('a',64),'application','delivery-other',now(),
  jsonb_build_object('offer_reference','echo-offer','reference','echo-1','status','application_received',
    'handoff_reference',:'tracked_reference','cooling_off_ends_at',now()+interval '5 days'))='accepted'
  then 'ok   correct provider and handoff reference attach the receipt' else 'FAIL correlated receipt' end;
select case when status='application_received' and provider_reference='echo-1'
  then 'ok   the correlated receipt becomes the recorded application' else 'FAIL receipt did not bind' end
  from public.investment_commitments where id=:'tracked_id';
select pg_temp.expect_delivery_error(format($q$select public.resume_private_handoff(
  'f3000000-0000-4000-8000-000000000002',%L,'https://example.test/echo-offer','AUD',true)$q$,:'tracked_id'),
  '23505','provider receipt between readiness and open blocks reopening');
-- Move the recorded revision back to simulate a later transaction in this fixture.
update public.investment_commitments set provider_event_at=now()-interval '1 second' where id=:'tracked_id';
select case when public.accept_private_provider_reference_delivery(
  'birchal','echo-withdrawal',repeat('b',64),'application','delivery-other',now(),
  '{"offer_reference":"echo-offer","reference":"echo-1","status":"withdrawn"}')='accepted'
  then 'ok   later events use the established provider receipt' else 'FAIL post-receipt provider delivery' end;
select case when status='withdrawn' and withdrawn_at=now() and
  not exists (select from public.private_holdings where commitment_id=:'tracked_id')
  then 'ok   the withdrawal remains in history without creating ownership' else 'FAIL application withdrawal' end
  from public.investment_commitments where id=:'tracked_id';
select pg_temp.expect_delivery_error(format($q$select public.resume_private_handoff(
  'f3000000-0000-4000-8000-000000000002',%L,'https://example.test/echo-offer','AUD',true)$q$,:'tracked_id'),
  '23505','a withdrawn handoff cannot be opened as a new application');
reset role;

delete from auth.users where id='f3000000-0000-4000-8000-000000000001';
select case when not exists (select 1 from provider_operations.private_event_deliveries where user_id='f3000000-0000-4000-8000-000000000001')
  then 'ok   deleting the account clears its delivery receipts' else 'FAIL retained delivery receipts' end;
rollback;
