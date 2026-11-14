\set QUIET 1
\pset tuples_only on
\pset format unaligned
\set owner '7f100000-0000-4000-8000-000000000001'
\set follower '7f100000-0000-4000-8000-000000000002'
\set session '7f100000-0000-4000-8000-000000000003'
\set owner_device '7f100000-0000-4000-8000-000000000004'
\set follower_device '7f100000-0000-4000-8000-000000000005'
\set company '7f100000-0000-4000-8000-000000000010'
\set round '7f100000-0000-4000-8000-000000000011'
\set opportunity '7f100000-0000-4000-8000-000000000012'
\set commitment '7f100000-0000-4000-8000-000000000013'
\set holding '7f100000-0000-4000-8000-000000000014'
\set first_release '7f100000-0000-4000-8000-000000000015'
\set later_release '7f100000-0000-4000-8000-000000000016'
\set sale '7f100000-0000-4000-8000-000000000017'
begin;

insert into auth.users(id, email) values
  (:'owner', 'active-monitor-owner@example.test'),
  (:'follower', 'active-monitor-follower@example.test');
insert into auth.sessions(id, user_id) values (:'session', :'owner');
insert into public.private_companies(id, name, sector, country, source_url, verified_at, published)
values (:'company', 'Ownership monitoring fixture', 'Technology', 'AU', 'https://example.test/company', now(), true);
insert into public.funding_rounds(id, company_id, stage, currency, source_url, verified_at, published)
values (:'round', :'company', 'Seed', 'AUD', 'https://example.test/round', now(), true);
insert into public.investment_opportunities
  (id,round_id,provider,category,status,minimum,eligibility,jurisdictions,source_url,verified_at,published)
values (:'opportunity', :'round', 'birchal', 'Crowdfunding', 'closed', 50, 'retail', array['AU'],
  'https://example.test/offering', now(), true);
insert into public.investment_commitments
  (id,user_id,opportunity_id,provider,jurisdiction,rule_version,reviewed_document_url,requested_amount,currency,
   acknowledged_at,status,provider_reference,confirmed_at)
select :'commitment', :'owner', :'opportunity', 'birchal', 'AU', version, 'https://example.test/offering', 500, 'AUD',
  now() - interval '40 days', 'confirmed', 'active-monitor-fixture', now() - interval '39 days'
from public.private_market_rules where jurisdiction = 'AU' order by effective_at desc, version desc limit 1;
insert into public.private_holdings
  (id,user_id,company_id,commitment_id,name,asset_class,currency,settled_amount,confirmed_at,units,remaining_units)
values (:'holding', :'owner', :'company', :'commitment', 'Provider fixture', 'Startup equity', 'AUD',
  500, now() - interval '39 days', 10, 10);

set role service_role;
select public.configure_private_monitor_ownership(:'owner', :'owner_device', '{}'::uuid[], false, true, true,
  jsonb_build_array(jsonb_build_object('holding_id', :'holding')));
select public.configure_private_monitor_ownership(:'follower', :'follower_device', array[:'company']::uuid[],
  false, true, false, jsonb_build_array(jsonb_build_object('holding_id', :'holding')));
select public.configure_private_market_push(:'owner', :'owner_device', :'session', 'production', repeat('c', 64), '{}');
reset role;
select case when provider_links = '[]'::jsonb then 'ok   a foreign holding contributes no provider link'
  else 'FAIL provider link crossed account boundary' end from public.private_monitor_devices where user_id = :'follower';

insert into public.corporate_actions(id,company_id,title,significance,published_at,source_url,published)
values (:'first_release', :'company', 'Before exit', 'An issuer disclosure', now() - interval '1 minute',
  'https://example.test/before-exit', true);

set role service_role;
select public.collect_private_market_alerts(:'owner');
create temporary table ownership_push_claim as
  select * from public.claim_private_market_push(array['production']) where owner_id = :'owner';
create temporary table ownership_digest_claim as
  select * from public.claim_private_market_digests() where owner_id = :'owner';
select case when count(*) = 1 and bool_and(public.private_market_push_is_current(owner_id,installation_id,lease))
  then 'ok   an owned company can queue a push' else 'FAIL missing owned push' end from ownership_push_claim;
select case when count(*) = 1 and bool_and(public.private_market_digest_is_current(job_id,lease,sources))
  and bool_and(sources @> jsonb_build_array(jsonb_build_object('id', :'first_release')))
  then 'ok   an active linked position enters the opted-in digest' else 'FAIL missing linked digest' end from ownership_digest_claim;
reset role;

insert into public.private_holding_dispositions
  (id,user_id,holding_id,provider_reference,provider_event_at,sold_units,net_proceeds,settled_on,source)
values (:'sale', :'owner', :'holding', 'active-monitor-exit', now(), 10, 600,
  (now() at time zone 'Australia/Sydney')::date, 'Provider sale receipt');
update public.private_holdings set remaining_units = 0, last_disposition_on = (now() at time zone 'Australia/Sydney')::date,
  disposition_revision_at = now(), exit_source = 'Provider sale receipt' where id = :'holding';

set role service_role;
select case when count(*) = 1 and bool_and(not public.private_market_push_is_current(owner_id,installation_id,lease))
  then 'ok   the exit invalidates a leased ownership announcement' else 'FAIL exited announcement can still send' end
  from ownership_push_claim;
select case when count(*) = 1 and bool_and(not public.private_market_digest_is_current(job_id,lease,sources))
  then 'ok   the exit stops a claimed digest before model delivery' else 'FAIL exited issuer can reach the model' end
  from ownership_digest_claim;
select case when count(*) = 1 and bool_and(not public.finish_private_market_digest(job_id,lease,sources,'{}'))
  then 'ok   an in-flight digest cannot be saved after the exit' else 'FAIL obsolete digest saved' end from ownership_digest_claim;
reset role;

insert into public.corporate_actions(id,company_id,title,significance,published_at,source_url,published)
values (:'later_release', :'company', 'After exit', 'An issuer disclosure after the exit', now(),
  'https://example.test/after-exit', true);
set role service_role;
select public.collect_private_market_alerts(:'owner');
select public.collect_private_market_alerts(:'follower');
select case when count(*) = 1 and min(subject_id::text) = :'sale' and min(source_label) = 'Provider sale receipt'
  then 'ok   the exit receipt stays in the inbox after issuer updates stop' else 'FAIL exit inbox scope' end
from public.private_market_alert_inbox_with_revisions(:'owner');
select case when count(*) = 1 then 'ok   an explicit follower still collects new issuer updates'
  else 'FAIL explicit follower lost an update' end
from public.private_market_alert_inbox_with_revisions(:'follower') where subject_id = :'later_release';
reset role;
select case when not exists (select 1 from public.private_market_alerts where user_id = :'owner' and subject_id = :'later_release')
  then 'ok   collection skips new announcements after an ownership exit' else 'FAIL exit still collects new announcements' end;

update public.private_holding_dispositions set reversed = true where id = :'sale';
update public.private_holdings set remaining_units = 4, last_disposition_on = null, exit_source = null,
  disposition_revision_at = now() where id = :'holding';
set role service_role;
select public.collect_private_market_alerts(:'owner');
select case when count(*) = 2 and count(*) filter (where kind = 'holding_exit') = 0
  then 'ok   a correction restores company monitoring and withdraws the exit notice'
  else 'FAIL corrected position scope' end
from public.private_market_alert_inbox_with_revisions(:'owner');
reset role;
select case when public.private_market_digest_sources(:'owner', (now() at time zone 'Australia/Sydney')::date)
  @> jsonb_build_array(jsonb_build_object('id', :'later_release'))
  then 'ok   linked digest sources resume after the correction without a device sync' else 'FAIL digest source did not resume' end;

set role authenticated;
select case when not has_table_privilege(current_user, 'public.private_market_owned_positions', 'select')
  and not has_table_privilege(current_user, 'public.private_market_device_companies', 'select')
  and not has_function_privilege(current_user, 'public.configure_private_monitor_ownership(uuid,uuid,uuid[],boolean,boolean,boolean,jsonb)', 'execute')
  and not has_function_privilege(current_user, 'public.private_market_digest_is_current(uuid,uuid,jsonb)', 'execute')
  then 'ok   monitoring internals remain outside mobile database access' else 'FAIL ownership metadata exposed' end;
reset role;
rollback;
