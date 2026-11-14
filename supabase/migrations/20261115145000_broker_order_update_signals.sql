-- Publish refresh signals without putting receipts, orders or audit data in the replication stream.
create table public.broker_order_updates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  revision bigint not null default 1 check (revision > 0)
);

alter table public.broker_order_updates enable row level security;
revoke all on public.broker_order_updates from public, anon, authenticated;
grant select on public.broker_order_updates to authenticated;
grant select, insert, update on public.broker_order_updates to service_role;

create policy "Owners receive broker order update signals" on public.broker_order_updates
  for select to authenticated using (user_id = (select auth.uid()));

alter publication supabase_realtime add table public.broker_order_updates;

create function provider_operations.signal_order_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  insert into public.broker_order_updates (user_id) values (new.user_id)
  on conflict (user_id) do update set revision = public.broker_order_updates.revision + 1;
  return null;
end
$$;

revoke all on function provider_operations.signal_order_update() from public, anon, authenticated;
grant execute on function provider_operations.signal_order_update() to service_role;

-- Defer until the order/receipt transaction is ready to commit.
create constraint trigger signal_new_order
  after insert on public.order_intents deferrable initially deferred
  for each row execute function provider_operations.signal_order_update();

create constraint trigger signal_order_status
  after update on public.order_intents deferrable initially deferred
  for each row when (old.status is distinct from new.status)
  execute function provider_operations.signal_order_update();

create constraint trigger signal_new_broker_receipt
  after insert on public.broker_orders deferrable initially deferred
  for each row when (new.intent_id is not null)
  execute function provider_operations.signal_order_update();

create constraint trigger signal_broker_receipt
  after update on public.broker_orders deferrable initially deferred
  for each row when (new.intent_id is not null and
    (old.intent_id, old.status, old.filled_quantity, old.average_fill_price)
      is distinct from (new.intent_id, new.status, new.filled_quantity, new.average_fill_price))
  execute function provider_operations.signal_order_update();

create constraint trigger signal_order_audit
  after insert on public.oms_events deferrable initially deferred
  for each row execute function provider_operations.signal_order_update();
