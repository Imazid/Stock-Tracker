\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned

begin;
select case when exists (
  select 1 from provider_operations.workers where name = 'alpaca-paper-order-stream'
) and not has_schema_privilege('authenticated', 'provider_operations', 'USAGE')
  and not has_table_privilege('authenticated', 'provider_operations.alpaca_stream_leases', 'SELECT')
  and not has_function_privilege('authenticated', 'provider_operations.invoke_alpaca_paper_stream()', 'EXECUTE')
  and not has_function_privilege('anon', 'provider_operations.invoke_alpaca_paper_stream()', 'EXECUTE')
  then 'ok   stream is monitored and its scheduler and per-account leases are private'
  else 'FAIL stream monitoring or permissions are incorrect' end;
rollback;
