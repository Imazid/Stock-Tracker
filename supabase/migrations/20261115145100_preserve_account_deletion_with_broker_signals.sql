create or replace function provider_operations.signal_order_update() returns trigger
language plpgsql set search_path = '' as $$
declare
  violation_schema text;
  violation_table text;
  violation_constraint text;
begin
  insert into public.broker_order_updates (user_id) values (new.user_id)
  on conflict (user_id) do update set revision = public.broker_order_updates.revision + 1;
  return null;
exception when foreign_key_violation then
  get stacked diagnostics
    violation_schema = schema_name,
    violation_table = table_name,
    violation_constraint = constraint_name;
  -- A queued notification can outlive the account deleted in the same transaction.
  if (violation_schema, violation_table, violation_constraint)
     = ('public', 'broker_order_updates', 'broker_order_updates_user_id_fkey') then
    return null;
  end if;
  raise;
end
$$;
