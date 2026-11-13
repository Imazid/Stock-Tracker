-- Behaviour checks for migrations/20261113190000_server_side_secret_custody.sql.
--
-- DESTRUCTIVE: inserts and deletes rows (including auth.users). Run ONLY against a
-- throwaway database — scripts/verify-migrations.sh starts and removes one, and CI uses
-- a disposable service container. Never run this against a real project.
--
-- Every line of output starts with "ok" or "FAIL"; the runner fails on any FAIL.
\set QUIET 1
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned

begin;
create temporary table custody_test_scope (id integer);

create or replace function pg_temp.expect_error(sql text, label text) returns text language plpgsql as $$
begin
  begin
    execute sql;
    return 'FAIL ' || label || ' (no error raised)';
  exception when others then
    return 'ok   ' || label;
  end;
end $$;

create or replace function pg_temp.expect_ok(sql text, label text) returns text language plpgsql as $$
begin
  begin
    execute sql;
    return 'ok   ' || label;
  exception when others then
    return 'FAIL ' || label || ' [' || sqlerrm || ']';
  end;
end $$;

create or replace function pg_temp.expect_eq(actual text, expected text, label text) returns text language plpgsql as $$
begin
  if actual is not distinct from expected then return 'ok   ' || label; end if;
  return 'FAIL ' || label || ' (expected ' || coalesce(expected, 'null') || ', got ' || coalesce(actual, 'null') || ')';
end $$;

select format('grant usage on schema %I to service_role, authenticated', nspname)
from pg_namespace where oid = pg_my_temp_schema() \gexec

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.test'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.test');

-- As the Edge Functions (service role) ------------------------------------------
set role service_role;

select pg_temp.expect_ok($q$insert into public.secure_credentials (user_id,purpose,provider,external_ref,sealed,kek_id) values ('11111111-1111-1111-1111-111111111111','snaptrade_user','snaptrade','st-1','{"v":1,"alg":"A256GCM+A256GCMKW","kid":"k1","wrappedDek":"x","dekIv":"x","iv":"x","ciphertext":"x"}','k1')$q$,
  'service role stores a sealed credential');
select pg_temp.expect_error($q$insert into public.secure_credentials (user_id,purpose,provider,external_ref,sealed,kek_id) values ('11111111-1111-1111-1111-111111111111','snaptrade_user','snaptrade','st-1b','{"v":1,"alg":"A256GCM+A256GCMKW","kid":"k1","wrappedDek":"x","dekIv":"x","iv":"x","ciphertext":"x"}','k1')$q$,
  'a second live SnapTrade identity for the same person is refused');
select pg_temp.expect_error($q$insert into public.secure_credentials (user_id,purpose,provider,external_ref,sealed,kek_id) values ('22222222-2222-2222-2222-222222222222','snaptrade_user','snaptrade','st-1','{"v":1,"alg":"A256GCM+A256GCMKW","kid":"k1","wrappedDek":"x","dekIv":"x","iv":"x","ciphertext":"x"}','k1')$q$,
  'the same SnapTrade identity for another person is refused');
select pg_temp.expect_error($q$insert into public.secure_credentials (user_id,purpose,provider,sealed,kek_id) values ('22222222-2222-2222-2222-222222222222','broker_api_key','alpaca','{"userSecret":"plain"}','k1')$q$,
  'an unsealed / plaintext value is refused');
select pg_temp.expect_error($q$insert into public.secure_credentials (user_id,purpose,provider,sealed,kek_id) values ('22222222-2222-2222-2222-222222222222','broker_api_key','alpaca','{"v":1,"alg":"A256GCM+A256GCMKW","kid":"k1","wrappedDek":"x","dekIv":"x","iv":"x","ciphertext":"x","secret":"plain"}','k1')$q$,
  'a sealed value carrying a plaintext field is refused');
select pg_temp.expect_error($q$insert into public.secure_credentials (user_id,purpose,provider,sealed,kek_id) values ('22222222-2222-2222-2222-222222222222','broker_api_key','alpaca','{"v":1,"alg":"A256GCM+A256GCMKW","kid":"k1","wrappedDek":"x","dekIv":"x","iv":"x","ciphertext":"x"}','k2')$q$,
  'kek_id must match the sealed key id');
select pg_temp.expect_ok($q$update public.secure_credentials set revoked_at = now() where external_ref = 'st-1'$q$,
  'a credential can be revoked');
select pg_temp.expect_ok($q$insert into public.secure_credentials (user_id,purpose,provider,external_ref,sealed,kek_id) values ('22222222-2222-2222-2222-222222222222','snaptrade_user','snaptrade','st-1','{"v":1,"alg":"A256GCM+A256GCMKW","kid":"k1","wrappedDek":"x","dekIv":"x","iv":"x","ciphertext":"x"}','k1')$q$,
  'a revoked identity can be claimed again');
select pg_temp.expect_ok($q$insert into public.credential_events (user_id, credential_id, action, provider) values ('11111111-1111-1111-1111-111111111111', null, 'created', 'snaptrade'), ('22222222-2222-2222-2222-222222222222', null, 'created', 'snaptrade')$q$,
  'service role logs credential events');
select pg_temp.expect_error($q$update public.credential_events set action = 'deleted'$q$,
  'credential_events rows cannot be updated');
select pg_temp.expect_error($q$delete from public.credential_events$q$,
  'credential_events rows cannot be deleted directly');

select pg_temp.expect_eq(
  (select string_agg(format('%s/%s', allowed::text, used), ', ') from (
     select * from public.consume_ai_quota('11111111-1111-1111-1111-111111111111', 2)
     union all select * from public.consume_ai_quota('11111111-1111-1111-1111-111111111111', 2)
     union all select * from public.consume_ai_quota('11111111-1111-1111-1111-111111111111', 2)) q),
  'true/1, true/2, false/2',
  'the AI quota allows exactly the limit and never counts past it');
select pg_temp.expect_eq(
  (select format('%s/%s', allowed::text, used) from public.consume_ai_quota('22222222-2222-2222-2222-222222222222', 0)),
  'false/0',
  'a zero limit refuses without recording usage');
reset role;

-- As a signed-in app user ---------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', false) is not null;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false) is not null;

select pg_temp.expect_error($q$select count(*) from public.secure_credentials$q$,
  'an app user cannot read secure_credentials');
select pg_temp.expect_error($q$insert into public.secure_credentials (user_id,purpose,provider,sealed,kek_id) values ('11111111-1111-1111-1111-111111111111','broker_api_key','alpaca','{"v":1,"alg":"A256GCM+A256GCMKW","kid":"k1","wrappedDek":"x","dekIv":"x","iv":"x","ciphertext":"x"}','k1')$q$,
  'an app user cannot write secure_credentials');
select pg_temp.expect_error($q$select * from public.consume_ai_quota('11111111-1111-1111-1111-111111111111', 1000000)$q$,
  'an app user cannot call consume_ai_quota');
select pg_temp.expect_error($q$insert into public.ai_usage_daily values ('11111111-1111-1111-1111-111111111111', current_date, 0)$q$,
  'an app user cannot reset their AI usage');
select pg_temp.expect_error($q$insert into public.credential_events (user_id, action, provider) values ('11111111-1111-1111-1111-111111111111', 'created', 'snaptrade')$q$,
  'an app user cannot forge credential events');
select pg_temp.expect_eq((select count(*)::text from public.credential_events), '1',
  'an app user sees only their own credential events');
select pg_temp.expect_eq((select count(*)::text from public.ai_usage_daily), '1',
  'an app user sees only their own AI usage');
reset role;

-- Account deletion ----------------------------------------------------------------
select pg_temp.expect_ok($q$delete from auth.users where id = '11111111-1111-1111-1111-111111111111'$q$,
  'deleting an account cascades through the append-only log');
select pg_temp.expect_eq((select count(*)::text from public.credential_events), '1',
  'only the other person''s credential events remain');
select pg_temp.expect_eq((select count(*)::text from public.secure_credentials), '1',
  'only the other person''s credentials remain');

rollback;
