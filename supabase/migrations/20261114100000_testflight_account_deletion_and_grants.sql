-- These records remain append-only while their owner exists. Deleting an auth
-- account removes its simulated orders, connections and audit trail together.
alter table public.order_intents
  drop constraint order_intents_connection_id_fkey,
  add constraint order_intents_connection_id_fkey
    foreign key (connection_id) references public.broker_connections(id)
    deferrable initially deferred;

alter table public.oms_events
  drop constraint oms_events_intent_id_fkey,
  add constraint oms_events_intent_id_fkey
    foreign key (intent_id) references public.order_intents(id)
    deferrable initially deferred;

create or replace function public.oms_refuse_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;
  raise exception '% is append-only', tg_table_name using errcode = 'check_violation';
end $$;

revoke all on function public.oms_refuse_change() from public, anon, authenticated;

-- Trigger entry points are invoked by PostgreSQL. API roles only need the two
-- referral RPCs, which already grant EXECUTE explicitly to authenticated.
revoke execute on function public.oms_drop_credentials_on_revoke() from public, anon, authenticated;

revoke execute on function public.oms_guard_approval() from public, anon, authenticated;

revoke execute on function public.oms_guard_intent() from public, anon, authenticated;

revoke execute on function public.oms_log_intent_transition() from public, anon, authenticated;

revoke execute on function public.generate_referral_code(uuid) from anon;

revoke execute on function public.referral_code_owner(text) from anon;

alter function public.touch_updated_at() set search_path = '';

alter function public.oms_bump_policy_version() set search_path = '';

alter function public.oms_intent_can_transition(text, text) set search_path = '';
