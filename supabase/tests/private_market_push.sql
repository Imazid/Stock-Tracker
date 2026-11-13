\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id,email) values
  ('b0000000-0000-4000-b000-000000000001','push-a@example.test'),
  ('b0000000-0000-4000-b000-000000000002','push-b@example.test');
insert into auth.sessions (id,user_id) values
  ('b0000000-0000-4000-b000-000000000011','b0000000-0000-4000-b000-000000000001'),
  ('b0000000-0000-4000-b000-000000000012','b0000000-0000-4000-b000-000000000002');
insert into public.private_companies (id,name,sector,country,source_url,verified_at,published) values
  ('b0000000-0000-4000-b000-000000000020','Push issuer','Technology','AU','https://example.test/company',now(),true),
  ('b0000000-0000-4000-b000-000000000021','Second issuer','Technology','AU','https://example.test/company-b',now(),true);

set role service_role;
select public.configure_private_monitor('b0000000-0000-4000-b000-000000000001','b0000000-0000-4000-b000-000000000031',
  array['b0000000-0000-4000-b000-000000000020']::uuid[],false,true);
select public.configure_private_monitor('b0000000-0000-4000-b000-000000000001','b0000000-0000-4000-b000-000000000032',
  array['b0000000-0000-4000-b000-000000000021']::uuid[],false,true);

select case when not public.configure_private_market_push('b0000000-0000-4000-b000-000000000001',
  'b0000000-0000-4000-b000-000000000031','b0000000-0000-4000-b000-000000000012','production',repeat('a',64),'{}')
  then 'ok   another account session cannot register' else 'FAIL cross-account registration' end;
select case when public.configure_private_market_push('b0000000-0000-4000-b000-000000000001',
  'b0000000-0000-4000-b000-000000000031','b0000000-0000-4000-b000-000000000011','production',repeat('a',64),'{}')
  then 'ok   approved active session registers push' else 'FAIL registration' end;
select public.configure_private_market_push('b0000000-0000-4000-b000-000000000001',
  'b0000000-0000-4000-b000-000000000032','b0000000-0000-4000-b000-000000000011','production',repeat('b',64),'{}');

insert into public.corporate_actions (company_id,title,significance,published_at,source_url,published)
values ('b0000000-0000-4000-b000-000000000020','Issuer news','A sourced issuer update.',now()-interval '1 minute',
        'https://example.test/issuer-update',true);
select public.collect_private_market_alerts('b0000000-0000-4000-b000-000000000001');
-- Refreshing the same token preserves the pending delivery cursor.
select public.configure_private_market_push('b0000000-0000-4000-b000-000000000001',
  'b0000000-0000-4000-b000-000000000031','b0000000-0000-4000-b000-000000000011','production',repeat('a',64),'{}');
select case when count(*) = 0 then 'ok   sandbox worker cannot see production devices' else 'FAIL cross-environment claim' end
  from public.claim_private_market_push(array['sandbox']);
create temporary table claimed_push as select * from public.claim_private_market_push(array['production']);
select case when count(*) = 1 and min(installation_id::text) = 'b0000000-0000-4000-b000-000000000031'
  then 'ok   a device only receives alerts in its monitoring scope' else 'FAIL incorrect device selected' end from claimed_push;
select case when count(*) = 0 then 'ok   live push lease prevents another worker from sending' else 'FAIL duplicate lease' end
  from public.claim_private_market_push(array['production']);
select case when public.private_market_push_is_current(owner_id,installation_id,lease)
  then 'ok   claimed evidence remains current' else 'FAIL lease unavailable' end from claimed_push;
update public.corporate_actions set published = false where source_url = 'https://example.test/issuer-update';
select case when not public.private_market_push_is_current(owner_id,installation_id,lease)
  then 'ok   withdrawing publication cancels leased push' else 'FAIL obsolete alert' end from claimed_push;
update public.corporate_actions set published = true where source_url = 'https://example.test/issuer-update';
select public.finish_private_market_push(owner_id,installation_id,lease,'retry') from claimed_push;
reset role;
update public.private_market_push_devices set next_attempt_at = now() - interval '1 second' where lease_token is not null;
set role service_role;
create temporary table retried_push as select * from public.claim_private_market_push(array['production']);
select case when count(*) = 1 and bool_and(r.lease <> c.lease)
  then 'ok   transient delivery is leased again' else 'FAIL transient push lost' end from retried_push r cross join claimed_push c;
select public.finish_private_market_push(owner_id,installation_id,lease,'invalid') from claimed_push;
select case when public.private_market_push_is_current(owner_id,installation_id,lease)
  then 'ok   old response cannot remove a current lease' else 'FAIL old lease invalidated current' end from retried_push;
select public.finish_private_market_push(owner_id,installation_id,lease,'accepted') from retried_push;

insert into public.corporate_actions (company_id,title,significance,published_at,source_url,published)
values ('b0000000-0000-4000-b000-000000000020','New release','A second issuer update.',now(),
        'https://example.test/second-issuer-update',true);
select public.collect_private_market_alerts('b0000000-0000-4000-b000-000000000001');
reset role;
update public.private_market_push_devices set next_attempt_at = now() - interval '1 second';
set role service_role;
create temporary table next_push as select * from public.claim_private_market_push(array['production']);
select case when count(*) = 1 then 'ok   new evidence queues after accepted delivery' else 'FAIL cannot send new alerts' end from next_push;
select public.configure_private_monitor('b0000000-0000-4000-b000-000000000002','b0000000-0000-4000-b000-000000000033',
  array['b0000000-0000-4000-b000-000000000020']::uuid[],false,true);
select public.configure_private_market_push('b0000000-0000-4000-b000-000000000002',
  'b0000000-0000-4000-b000-000000000033','b0000000-0000-4000-b000-000000000012','production',repeat('a',64),'{}');
select case when not public.private_market_push_is_current(owner_id,installation_id,lease)
  then 'ok   device token reassignment revokes the previous account lease' else 'FAIL old account retained token' end from next_push;
reset role;
delete from auth.sessions where id = 'b0000000-0000-4000-b000-000000000012';
select public.invoke_private_market_push();
select case when count(*) = 0 then 'ok   deleting a session revokes remote notifications' else 'FAIL expired session receives push' end
  from public.private_market_push_devices where user_id = 'b0000000-0000-4000-b000-000000000002';

set role authenticated;
select case when not has_table_privilege(current_user, 'public.private_market_push_devices', 'select')
  and not has_function_privilege(current_user, 'public.claim_private_market_push(text[])', 'execute')
  then 'ok   mobile roles cannot view token rows or claim push sends' else 'FAIL push boundary exposed' end;
reset role;
rollback;
