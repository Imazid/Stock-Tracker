\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users(id) values ('ed000000-0000-4000-8000-000000000001'), ('ed000000-0000-4000-8000-000000000002');
select case when not has_table_privilege('authenticated','public.private_manual_portfolio_snapshots','select')
  and not has_function_privilege('authenticated','public.write_private_manual_portfolio_snapshot(uuid,uuid,uuid,jsonb)','execute')
  and not has_function_privilege('anon','public.write_private_manual_portfolio_snapshot(uuid,uuid,uuid,jsonb)','execute')
  then 'ok snapshot is service-only' else 'FAIL snapshot permissions' end;

set local role service_role;
select case when count(*)=1 then 'ok first publish creates a revision' else 'FAIL first publish' end
from public.write_private_manual_portfolio_snapshot('ed000000-0000-4000-8000-000000000001',null,
  'ed000000-0000-4000-8000-000000000010','{"ciphertext":"first"}');
select case when count(*)=0 then 'ok another initial publish cannot overwrite it' else 'FAIL overwritten' end
from public.write_private_manual_portfolio_snapshot('ed000000-0000-4000-8000-000000000001',null,
  'ed000000-0000-4000-8000-000000000011','{"ciphertext":"stale"}');
select case when count(*)=0 then 'ok a revision cannot update a different owner' else 'FAIL owner override' end
from public.write_private_manual_portfolio_snapshot('ed000000-0000-4000-8000-000000000002',
  'ed000000-0000-4000-8000-000000000010','ed000000-0000-4000-8000-000000000011','{"ciphertext":"other"}');
select case when count(*)=1 then 'ok removal replaces the sealed data with an empty revision' else 'FAIL removal' end
from public.write_private_manual_portfolio_snapshot('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000010','ed000000-0000-4000-8000-000000000012',null);
select case when count(*)=0 then 'ok a late save cannot recreate a removed snapshot' else 'FAIL late save' end
from public.write_private_manual_portfolio_snapshot('ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000010','ed000000-0000-4000-8000-000000000011','{"ciphertext":"late"}');
select case when exists (select from public.private_manual_portfolio_snapshots where sealed is null and
  revision='ed000000-0000-4000-8000-000000000012') then 'ok removed snapshot contains no ciphertext' else 'FAIL retained snapshot' end;
reset role;
delete from auth.users where id='ed000000-0000-4000-8000-000000000001';
select case when count(*)=0 then 'ok account deletion removes the snapshot row' else 'FAIL snapshot survived deletion' end
from public.private_manual_portfolio_snapshots;
rollback;
