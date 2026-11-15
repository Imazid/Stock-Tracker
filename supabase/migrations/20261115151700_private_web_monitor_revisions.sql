-- Retain the revision when the web subscription is removed or expires.
create table public.private_web_monitor_revisions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision uuid not null
);
alter table public.private_web_monitor_revisions enable row level security;
revoke all on public.private_web_monitor_revisions from public, anon, authenticated, service_role;
grant select on public.private_web_monitor_revisions to service_role;

create function public.private_web_monitor_preferences(p_user uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'revision', (select revision from public.private_web_monitor_revisions where user_id = p_user),
    'preferences', (select jsonb_build_object(
      'company_ids', company_ids, 'eligible_opportunities', eligible_opportunities,
      'digest_enabled', digest_enabled, 'refreshed_at', refreshed_at)
      from public.private_monitor_devices
      where user_id = p_user and device_id = '4c736341-5e56-4e0d-9466-7438190e4e60'
        and refreshed_at >= now() - interval '90 days'))
$$;

create function public.save_private_web_monitor(
  p_user uuid, p_expected_revision uuid, p_expected_enabled boolean,
  p_enabled boolean, p_companies uuid[], p_eligible boolean, p_digest boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  current_revision uuid;
begin
  if p_user is null then
    raise exception 'Invalid web monitoring settings' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text, 41));
  select revision into current_revision from public.private_web_monitor_revisions where user_id = p_user;
  if p_expected_enabled is not null then
    if current_revision is distinct from p_expected_revision or p_expected_enabled is distinct from exists (
      select from public.private_monitor_devices
      where user_id = p_user and device_id = '4c736341-5e56-4e0d-9466-7438190e4e60'
        and refreshed_at >= now() - interval '90 days'
    ) then
      return null;
    end if;
  end if;
  perform public.configure_private_monitor(p_user, '4c736341-5e56-4e0d-9466-7438190e4e60',
    p_companies, p_eligible, p_enabled, p_digest);
  insert into public.private_web_monitor_revisions (user_id, revision)
  values (p_user, pg_catalog.gen_random_uuid())
  on conflict (user_id) do update set revision = excluded.revision;
  return public.private_web_monitor_preferences(p_user);
end $$;

revoke all on function public.private_web_monitor_preferences(uuid),
  public.save_private_web_monitor(uuid,uuid,boolean,boolean,uuid[],boolean,boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.private_web_monitor_preferences(uuid),
  public.save_private_web_monitor(uuid,uuid,boolean,boolean,uuid[],boolean,boolean) to service_role;
