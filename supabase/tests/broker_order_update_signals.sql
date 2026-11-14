\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned

begin;
insert into auth.users(id) values
  ('10000000-0000-4000-8000-000000000001'), ('20000000-0000-4000-8000-000000000002');
insert into public.broker_connections(id, user_id, adapter_id, name, environment, permissions, provider_account_id)
  values ('30000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
          'alpaca', 'Test paper account', 'paper', array['read'], 'signal-paper-fixture');
insert into public.order_intents(id, user_id, connection_id, provider, environment, symbol, asset_class, side,
                                  order_type, time_in_force, quantity, origin_kind, client_order_id, intent_hash, expires_at)
  values ('40000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003',
          'alpaca', 'paper', 'AAPL', 'us_equity', 'buy', 'market', 'day', 10, 'manual', 'st-signal-fixture', repeat('a', 64), now()+interval '15 min');

select case when not exists (select 1 from public.broker_order_updates)
  then 'ok   signal is deferred' else 'FAIL signal ran before the transaction finished' end;
set constraints all immediate;
select case when (select revision from public.broker_order_updates) = 1
  then 'ok   new intent signalled' else 'FAIL new intent signal missing' end;

update public.order_intents set status = 'risk_checked' where id = '40000000-0000-4000-8000-000000000004';
insert into public.broker_orders (user_id, connection_id, intent_id, provider_order_id, symbol, side, order_type, status, provider_status)
  values ('10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003',
          '40000000-0000-4000-8000-000000000004', 'qa-signal-order', 'AAPL', 'buy', 'market', 'accepted', 'new');
update public.broker_orders set status = 'partially_filled', filled_quantity = 2, average_fill_price = 180 where provider_order_id = 'qa-signal-order';
update public.broker_orders set filled_quantity = 3, average_fill_price = 181 where provider_order_id = 'qa-signal-order';
update public.broker_orders set updated_at = now() + interval '1 minute' where provider_order_id = 'qa-signal-order';
insert into public.oms_events (user_id, intent_id, kind)
  values ('10000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000004', 'oms.submitted');
insert into public.broker_order_updates (user_id) values ('20000000-0000-4000-8000-000000000002');

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000001';
select case when (select array_agg(revision) from public.broker_order_updates) = array[6::bigint]
  then 'ok   owner sees order, partial fills and audit updates; no-op receipt refresh stays quiet'
  else 'FAIL changes or owner isolation incorrect' end;
select case when not has_table_privilege(current_user, 'public.broker_order_updates', 'INSERT')
  and not has_table_privilege(current_user, 'public.broker_order_updates', 'UPDATE')
  and not has_table_privilege(current_user, 'public.broker_order_updates', 'DELETE')
  then 'ok   browser cannot forge signals' else 'FAIL client can write signals' end;
set local request.jwt.claim.sub = '20000000-0000-4000-8000-000000000002';
select case when (select array_agg(revision) from public.broker_order_updates) = array[1::bigint]
  then 'ok   other account sees only its own signal' else 'FAIL other account sees order updates' end;
reset role;
select case when not has_table_privilege('anon', 'public.broker_order_updates', 'SELECT') and
  exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'broker_order_updates')
  then 'ok   minimal signal is published and signed-out readers have no access'
  else 'FAIL publication or public grants incorrect' end;
rollback;
