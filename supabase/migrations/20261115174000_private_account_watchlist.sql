-- Explicit account follows are independent of each installation's monitoring consent.
create table public.private_company_follows (
  user_id uuid not null references auth.users(id) on delete cascade,
  company_id uuid not null references public.private_companies(id) on delete cascade,
  following boolean not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, company_id)
);
alter table public.private_company_follows enable row level security;
revoke all on public.private_company_follows from public, anon, authenticated, service_role;
grant select on public.private_company_follows to service_role;

-- The old web device stored only explicit follows. iPhone devices can also
-- contain device-local holdings, so their explicit follows are imported by the app.
insert into public.private_company_follows (user_id, company_id, following, updated_at)
select distinct d.user_id, c.id, true, d.refreshed_at
from public.private_monitor_devices d
join public.private_companies c on c.id = any(d.company_ids)
where d.device_id = '4c736341-5e56-4e0d-9466-7438190e4e60';

with migrated as (
  update public.private_monitor_devices set company_ids = '{}'
  where device_id = '4c736341-5e56-4e0d-9466-7438190e4e60' and cardinality(company_ids) > 0
  returning user_id
)
insert into public.private_web_monitor_revisions (user_id, revision)
select user_id, pg_catalog.gen_random_uuid() from migrated
on conflict (user_id) do update set revision = excluded.revision;

create function public.private_company_watchlist(p_user uuid)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', case when c.published then c.name else 'Unavailable company' end,
    'source', case when c.published then c.source_url else null end
  ) order by case when c.published then c.name else 'Unavailable company' end, c.id), '[]'::jsonb)
  from public.private_company_follows f
  join public.private_companies c on c.id = f.company_id
  where f.user_id = p_user and f.following;
$$;

create function public.update_private_company_watchlist(p_user uuid, p_add uuid[], p_remove uuid[], p_import boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or p_add is null or p_remove is null or p_import is null
    or cardinality(p_add) + cardinality(p_remove) > 250 or p_add && p_remove
    or array_position(p_add, null) is not null or array_position(p_remove, null) is not null
    or (p_import and cardinality(p_remove) > 0) then
    raise exception 'Choose up to 250 companies to update.' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text, 41));

  if p_import then
    -- A later import on another device must respect a previous unfollow.
    insert into public.private_company_follows (user_id, company_id, following)
    select p_user, c.id, true from public.private_companies c where c.id = any(p_add) and c.published
    on conflict (user_id, company_id) do nothing;
  else
    if exists (select 1 from unnest(p_add) item(id)
      where not exists (select 1 from public.private_companies c where c.id = item.id and c.published)) then
      raise exception 'One or more companies are unavailable in the published catalogue.' using errcode = '22023';
    end if;
    insert into public.private_company_follows (user_id, company_id, following)
    select p_user, c.id, c.id = any(p_add)
    from public.private_companies c
    where c.id = any(p_add || p_remove) and (c.published or exists (
      select 1 from public.private_company_follows existing
      where (existing.user_id, existing.company_id) = (p_user, c.id)))
    on conflict (user_id, company_id) do update
      set following = excluded.following, updated_at = statement_timestamp()
      where private_company_follows.following is distinct from excluded.following;
  end if;

  return public.private_company_watchlist(p_user);
end $$;

revoke all on function public.private_company_watchlist(uuid),
  public.update_private_company_watchlist(uuid,uuid[],uuid[],boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.private_company_watchlist(uuid),
  public.update_private_company_watchlist(uuid,uuid[],uuid[],boolean) to service_role;

-- The shared collector, inbox, digest and push checks already use this view.
-- Rows are emitted only for installations with monitoring enabled.
create or replace view public.private_market_device_companies with (security_invoker = true) as
select d.user_id, d.device_id, unnest(d.company_ids) as company_id
from public.private_monitor_devices d
union all
select d.user_id, d.device_id, coalesce(h.company_id, linked.company_id)
from public.private_monitor_devices d
cross join lateral jsonb_to_recordset(d.provider_links) as linked(holding_id uuid, company_id uuid)
join public.private_market_owned_positions h on (h.id, h.user_id) = (linked.holding_id, d.user_id)
where (h.company_id is null or linked.company_id is null or h.company_id = linked.company_id)
  and coalesce(h.company_id, linked.company_id) is not null
union all
select d.user_id, d.device_id, f.company_id
from public.private_monitor_devices d
join public.private_company_follows f on f.user_id = d.user_id and f.following;
