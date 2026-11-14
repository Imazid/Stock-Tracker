\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id,email) values
  ('cc900000-0000-4000-8000-000000000001','account-holdings-owner@example.test'),
  ('cc900000-0000-4000-8000-000000000002','account-holdings-other@example.test');

select case when not has_table_privilege('authenticated','public.private_account_holdings','SELECT')
  and not has_table_privilege('anon','public.private_account_holdings','SELECT')
  and not has_function_privilege('authenticated','public.write_private_account_holdings(uuid,uuid,uuid,jsonb)','EXECUTE')
  and not has_function_privilege('anon','public.write_private_account_holdings(uuid,uuid,uuid,jsonb)','EXECUTE')
  then 'ok   only the service can access the encrypted account ledger' else 'FAIL private holdings grants' end;

set local role service_role;
select case when count(*)=1 then 'ok   account holdings can be created' else 'FAIL initial create' end
from public.write_private_account_holdings('cc900000-0000-4000-8000-000000000001',null,
  'cc900000-0000-4000-8000-000000000003','{"ciphertext":"encrypted fixture"}');
select case when count(*)=0 then 'ok   an outdated create leaves the account ledger intact' else 'FAIL stale create' end
from public.write_private_account_holdings('cc900000-0000-4000-8000-000000000001',null,
  'cc900000-0000-4000-8000-000000000004','{"ciphertext":"wrong fixture"}');
select case when count(*)=0 then 'ok   the same revision cannot update a second account' else 'FAIL wrong account' end
from public.write_private_account_holdings('cc900000-0000-4000-8000-000000000002','cc900000-0000-4000-8000-000000000003',
  'cc900000-0000-4000-8000-000000000004','{"ciphertext":"wrong fixture"}');
select case when count(*)=1 then 'ok   removing the last holding keeps a revision' else 'FAIL remove all' end
from public.write_private_account_holdings('cc900000-0000-4000-8000-000000000001','cc900000-0000-4000-8000-000000000003',
  'cc900000-0000-4000-8000-000000000004',null);
select case when count(*)=0 then 'ok   a delayed browser write cannot restore a removed holding' else 'FAIL stale write' end
from public.write_private_account_holdings('cc900000-0000-4000-8000-000000000001','cc900000-0000-4000-8000-000000000003',
  'cc900000-0000-4000-8000-000000000005','{"ciphertext":"wrong fixture"}');
reset role;

delete from auth.users where id='cc900000-0000-4000-8000-000000000001';
select case when count(*)=0 then 'ok   account deletion clears its holdings and revision' else 'FAIL retained account data' end
from public.private_account_holdings where user_id='cc900000-0000-4000-8000-000000000001';
rollback;
