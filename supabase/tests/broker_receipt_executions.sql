\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned

begin;
select case when not has_function_privilege('authenticated', 'provider_operations.signal_broker_fill()', 'EXECUTE')
  and not has_table_privilege('authenticated', 'public.broker_fills', 'INSERT')
  and exists (select 1 from pg_trigger where tgname = 'signal_broker_fill_insert' and tgdeferrable and tginitdeferred)
  and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'broker_fills')
  then 'ok   imported fills signal owners after commit and raw fill rows stay out of Realtime'
  else 'FAIL execution signaling is exposed or missing' end;
rollback;
