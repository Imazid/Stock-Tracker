-- Behaviour checks for 20261113180000_provider_order_management.sql.
-- Run against a THROWAWAY database after the migrations (never the shared local stack):
--   psql -At -f supabase/tests/provider_order_management.sql   → every line must start with 'ok' (one 'FAIL (allowed)'
--   line for an UPDATE on the still-empty oms_events table is a no-op and expected).
-- Needs an auth schema with auth.users and auth.uid() reading request.jwt.claim.sub.
\set ON_ERROR_STOP 0
\set QUIET 1
create or replace function pg_temp.expect_fail(sql text, label text) returns text language plpgsql as $$
begin execute sql; return 'FAIL (allowed): ' || label; exception when others then return 'ok  refused: ' || label || ' — ' || sqlerrm; end $$;
insert into auth.users(id) values ('11111111-1111-4111-8111-111111111111'), ('22222222-2222-4222-8222-222222222222');
insert into public.broker_connections(id, user_id, adapter_id, name, environment, permissions, provider_account_id, key_hint)
  values ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111','alpaca','Alpaca paper','paper',array['read','trade'],'acct-1','…ABCD'),
         ('55555555-5555-4555-8555-555555555555','22222222-2222-4222-8222-222222222222','alpaca','B paper','paper',array['read'],'acct-2','…WXYZ');
insert into public.broker_credentials(connection_id, user_id, sealed, kek_id) values ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111','{"v":1,"kekID":"k1","wrappedDEK":"x","ciphertext":"y"}','k1');
insert into public.order_intents(id,user_id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,quantity,limit_price,origin_kind,client_order_id,intent_hash,expires_at)
  values ('44444444-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333','alpaca','paper','AAPL','us_equity','buy','limit','day',10,190.5,'manual','st-0123456789abcdef0123456789abcdef',repeat('a',64), now()+interval '15 min');
insert into public.order_intents(id,user_id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,quantity,origin_kind,client_order_id,intent_hash,expires_at)
  values ('66666666-6666-4666-8666-666666666666','22222222-2222-4222-8222-222222222222','55555555-5555-4555-8555-555555555555','alpaca','paper','MSFT','us_equity','buy','market','day',1,'manual','st-ffff456789abcdef0123456789abcdef',repeat('b',64), now()+interval '15 min');
select pg_temp.expect_fail($q$update public.order_intents set status='approved' where id='44444444-4444-4444-8444-444444444444'$q$, 'draft → approved skips risk + approval');
update public.order_intents set status='risk_checked' where id='44444444-4444-4444-8444-444444444444';
update public.order_intents set status='awaiting_approval' where id='44444444-4444-4444-8444-444444444444';
select pg_temp.expect_fail($q$update public.order_intents set quantity=11 where id='44444444-4444-4444-8444-444444444444'$q$, 'editing the quantity of a drafted intent');
select pg_temp.expect_fail($q$insert into public.order_approvals(intent_id,approver_id,approved_intent_hash,aal,expires_at) values ('44444444-4444-4444-8444-444444444444','22222222-2222-4222-8222-222222222222',repeat('a',64),'aal2',now()+interval '2 min')$q$, 'approval by another user');
select pg_temp.expect_fail($q$insert into public.order_approvals(intent_id,approver_id,approved_intent_hash,aal,expires_at) values ('44444444-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111',repeat('c',64),'aal1',now()+interval '2 min')$q$, 'approval for a different hash');
insert into public.order_approvals(intent_id,approver_id,approved_intent_hash,aal,expires_at) values ('44444444-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111',repeat('a',64),'aal1',now()+interval '2 min');
update public.order_intents set status='approved' where id='44444444-4444-4444-8444-444444444444';
select 'consume #1 → ' || public.oms_consume_approval('44444444-4444-4444-8444-444444444444', now());
select 'consume #2 → ' || public.oms_consume_approval('44444444-4444-4444-8444-444444444444', now());
select pg_temp.expect_fail($q$update public.order_approvals set expires_at = now()+interval '1 day' where intent_id='44444444-4444-4444-8444-444444444444'$q$, 'extending an approval');
begin; set local oms.transition_note = 'test note'; update public.order_intents set status='submitting' where id='44444444-4444-4444-8444-444444444444'; commit;
update public.order_intents set status='reconciliation_required' where id='44444444-4444-4444-8444-444444444444';
select pg_temp.expect_fail($q$update public.order_intents set status='submitting' where id='44444444-4444-4444-8444-444444444444'$q$, 'resubmitting from reconciliation_required');
update public.order_intents set status='submitted' where id='44444444-4444-4444-8444-444444444444';
update public.order_intents set status='partially_filled' where id='44444444-4444-4444-8444-444444444444';
update public.order_intents set status='filled' where id='44444444-4444-4444-8444-444444444444';
select pg_temp.expect_fail($q$update public.order_intents set status='cancelled' where id='44444444-4444-4444-8444-444444444444'$q$, 'leaving a terminal state');
select 'transitions: ' || string_agg(coalesce(from_status,'∅') || '→' || to_status || coalesce(' ('||note||')',''), ', ' order by id) from public.order_intent_transitions where intent_id='44444444-4444-4444-8444-444444444444';
select pg_temp.expect_fail($q$delete from public.order_intent_transitions$q$, 'deleting the transition log');
select pg_temp.expect_fail($q$insert into public.order_intents(user_id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,quantity,origin_kind,client_order_id,intent_hash,expires_at) values ('11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333','alpaca','live','AAPL','us_equity','buy','market','day',1,'manual','st-live456789abcdef0123456789abcdef',repeat('d',64),now()+interval '1 min')$q$, 'a live intent');
select pg_temp.expect_fail($q$insert into public.order_intents(user_id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,quantity,notional,origin_kind,client_order_id,intent_hash,expires_at) values ('11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333','alpaca','paper','AAPL','us_equity','buy','market','day',1,5,'manual','st-both456789abcdef0123456789abcdef',repeat('d',64),now()+interval '1 min')$q$, 'quantity AND notional');
select pg_temp.expect_fail($q$insert into public.order_intents(user_id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,quantity,origin_kind,client_order_id,intent_hash,expires_at) values ('11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333','alpaca','paper','AAPL','us_equity','buy','market','day',-1,'manual','st-neg0456789abcdef0123456789abcdef',repeat('d',64),now()+interval '1 min')$q$, 'negative quantity');
select pg_temp.expect_fail($q$update public.platform_gates set enabled=true where id='live_execution'$q$, 'enabling live by UPDATE');
select pg_temp.expect_fail($q$update public.platform_gates set enabled=true where id='custodial_features'$q$, 'enabling custody');
update public.platform_gates set enabled=true where id='provider_paper_execution';
select 'paper gate can be enabled by an administrator: ' || enabled from public.platform_gates where id='provider_paper_execution';
update public.platform_gates set enabled=false where id='provider_paper_execution';
select pg_temp.expect_fail($q$insert into public.broker_connections(user_id,adapter_id,name,environment,permissions) values ('11111111-1111-4111-8111-111111111111','alpaca','live','live',array['read','trade'])$q$, 'live connection with trade permission');
select pg_temp.expect_fail($q$insert into public.broker_credentials(connection_id,user_id,sealed,kek_id) values ('55555555-5555-4555-8555-555555555555','22222222-2222-4222-8222-222222222222','{"kekID":"k1","wrappedDEK":"x","ciphertext":"y","secretKey":"oops"}','k1')$q$, 'a plaintext secretKey in the vault row');
select pg_temp.expect_fail($q$update public.oms_events set kind='x.y'$q$, 'oms_events is append-only (noop ok if empty)');
insert into public.oms_events(user_id, intent_id, kind) values ('11111111-1111-4111-8111-111111111111','44444444-4444-4444-8444-444444444444','oms.submitted');
select pg_temp.expect_fail($q$update public.oms_events set kind='oms.x'$q$, 'editing an OMS event');
-- RLS as user A
set role authenticated; set request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
select 'A sees intents: ' || count(*) from public.order_intents;
select 'A sees connections: ' || string_agg(name, ',') from public.broker_connections;
select pg_temp.expect_fail($q$select * from public.broker_credentials$q$, 'reading the vault as a signed-in user');
select pg_temp.expect_fail($q$insert into public.order_intents(user_id,connection_id,provider,environment,symbol,asset_class,side,order_type,time_in_force,quantity,origin_kind,client_order_id,intent_hash,expires_at) values ('11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333','alpaca','paper','AAPL','us_equity','buy','market','day',1,'manual','st-cli0456789abcdef0123456789abcdef',repeat('d',64),now()+interval '1 min')$q$, 'a client inserting an intent directly');
select pg_temp.expect_fail($q$select public.oms_consume_approval('44444444-4444-4444-8444-444444444444', now())$q$, 'a client consuming an approval');
select 'A sees gates: ' || count(*) from public.platform_gates;
reset role;
update public.broker_connections set status='revoked', revoked_at=now() where id='33333333-3333-4333-8333-333333333333';
select 'credentials left after revoke: ' || count(*) from public.broker_credentials where connection_id='33333333-3333-4333-8333-333333333333';
