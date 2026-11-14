create index broker_fills_receipt_idx
  on public.broker_fills (user_id, connection_id, provider_order_id, executed_at desc, id desc);

-- Signal the account after executions for a Stock Tracker order have committed.
create function provider_operations.signal_broker_fill() returns trigger
language plpgsql set search_path = '' as $$
declare
  violation_schema text;
  violation_table text;
  violation_constraint text;
begin
  -- A broker can report executions for orders placed outside Stock Tracker.
  if exists (select 1 from public.broker_orders b where b.user_id = new.user_id
    and b.connection_id = new.connection_id and b.provider_order_id = new.provider_order_id and b.intent_id is not null) then
    insert into public.broker_order_updates (user_id) values (new.user_id)
    on conflict (user_id) do update set revision = public.broker_order_updates.revision + 1;
  end if;
  return null;
exception when foreign_key_violation then
  get stacked diagnostics violation_schema = schema_name, violation_table = table_name, violation_constraint = constraint_name;
  if (violation_schema, violation_table, violation_constraint)
      = ('public', 'broker_order_updates', 'broker_order_updates_user_id_fkey') then return null; end if;
  raise;
end
$$;
revoke all on function provider_operations.signal_broker_fill() from public, anon, authenticated;
grant execute on function provider_operations.signal_broker_fill() to service_role;

create constraint trigger signal_broker_fill_insert
  after insert on public.broker_fills deferrable initially deferred
  for each row execute function provider_operations.signal_broker_fill();
