\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users(id) values
  ('aa400000-0000-4000-8000-000000000001'), ('aa400000-0000-4000-8000-000000000002');
select case when not has_table_privilege('authenticated','public.private_web_monitor_revisions','select')
  and not has_function_privilege('authenticated','public.private_web_monitor_preferences(uuid)','execute')
  and not has_function_privilege('anon','public.save_private_web_monitor(uuid,uuid,boolean,boolean,uuid[],boolean,boolean)','execute')
  then 'ok web monitoring revisions are service-only' else 'FAIL revision privileges' end;

select public.configure_private_monitor('aa400000-0000-4000-8000-000000000001',
  'aa400000-0000-4000-8000-000000000010', array['d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01']::uuid[], true, true, true);
select public.configure_private_monitor('aa400000-0000-4000-8000-000000000001',
  '4c736341-5e56-4e0d-9466-7438190e4e60', array['d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01']::uuid[], false, true, true);
set local role service_role;
select (public.save_private_web_monitor('aa400000-0000-4000-8000-000000000001', null, true, true,
  array['d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01','a581f4af-a8d0-41fd-a9be-0e4e1607f102']::uuid[], false, true)
  ->> 'revision') as revision \gset
select case when jsonb_array_length(settings->'preferences'->'company_ids')=2
  and settings->'preferences'->>'digest_enabled'='true'
  then 'ok a saved legacy watchlist can be revised' else 'FAIL legacy watchlist' end
from (select public.private_web_monitor_preferences('aa400000-0000-4000-8000-000000000001') settings) q;
select case when public.save_private_web_monitor('aa400000-0000-4000-8000-000000000001',
  null, true, false, '{}'::uuid[], false, false) is null
  then 'ok a stale tab cannot disable monitoring' else 'FAIL stale disable' end;
select case when public.save_private_web_monitor('aa400000-0000-4000-8000-000000000002',
  :'revision', true, true, '{}'::uuid[], false, false) is null
  then 'ok a revision cannot authorize another owner' else 'FAIL cross-account revision' end;
select (public.save_private_web_monitor('aa400000-0000-4000-8000-000000000001', :'revision', true, false,
  '{}'::uuid[], false, false)->>'revision') as removed_revision \gset
select case when :'removed_revision' <> :'revision'
  and public.private_web_monitor_preferences('aa400000-0000-4000-8000-000000000001')->'preferences' = 'null'
  and exists (select from public.private_monitor_devices where device_id='aa400000-0000-4000-8000-000000000010'
    and eligible_opportunities and digest_enabled)
  then 'ok disabling web leaves native monitoring enabled' else 'FAIL disable scope' end;
select case when public.save_private_web_monitor('aa400000-0000-4000-8000-000000000001',
  :'revision', true, true, array['d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01']::uuid[], true, true) is null
  then 'ok a late save cannot restore web monitoring' else 'FAIL late enable' end;
select (public.save_private_web_monitor('aa400000-0000-4000-8000-000000000001', :'removed_revision', false, true,
  '{}'::uuid[], false, false)->>'revision') as expiring_revision \gset
reset role;
update public.private_monitor_devices set refreshed_at=now()-interval '91 days'
where user_id='aa400000-0000-4000-8000-000000000001' and device_id='4c736341-5e56-4e0d-9466-7438190e4e60';
set local role service_role;
select case when public.save_private_web_monitor('aa400000-0000-4000-8000-000000000001',
  :'expiring_revision', true, true, '{}'::uuid[], true, true) is null
  then 'ok expiry requires reopening the settings before reenabling' else 'FAIL stale expiry' end;
reset role;
delete from auth.users where id='aa400000-0000-4000-8000-000000000001';
select case when count(*)=0 then 'ok account deletion removes the revision' else 'FAIL orphaned revision' end
from public.private_web_monitor_revisions where user_id='aa400000-0000-4000-8000-000000000001';
rollback;
