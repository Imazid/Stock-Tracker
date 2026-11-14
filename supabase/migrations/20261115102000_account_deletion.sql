-- Keep order audit rows append-only while their owner exists. Both sides of these
-- relationships can be removed by the same Auth cascade.
alter table public.order_intents
  drop constraint order_intents_connection_id_fkey,
  add constraint order_intents_connection_id_fkey
    foreign key (connection_id) references public.broker_connections(id) deferrable initially deferred;

alter table public.oms_events
  drop constraint oms_events_intent_id_fkey,
  add constraint oms_events_intent_id_fkey
    foreign key (intent_id) references public.order_intents(id) deferrable initially deferred;

create or replace function public.oms_refuse_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;
  raise exception '% is append-only', tg_table_name using errcode = 'check_violation';
end $$;

revoke all on function public.oms_refuse_change() from public, anon, authenticated;

create function public.account_deletion_session_active(p_user uuid, p_session uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.private_market_push_session_active(p_user, p_session);
$$;
revoke all on function public.account_deletion_session_active(uuid, uuid) from public, anon, authenticated;
grant execute on function public.account_deletion_session_active(uuid, uuid) to service_role;
notify pgrst, 'reload schema';
