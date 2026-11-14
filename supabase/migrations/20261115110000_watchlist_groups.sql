-- Keep the existing default list readable and writable by older apps.
alter table public.watchlist_assets add column sort_position bigint;

create table public.watchlist_groups (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 80),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id)
);

create table public.watchlist_group_assets (
  id uuid not null default gen_random_uuid(),
  user_id uuid not null,
  group_id uuid not null,
  listing_id text not null,
  symbol text not null,
  name text not null,
  kind text not null check (kind in ('Stock', 'Crypto')),
  exchange text,
  added_at timestamptz not null default now(),
  sort_position bigint,
  primary key (user_id, group_id, listing_id),
  foreign key (user_id, group_id) references public.watchlist_groups(user_id, id) on delete cascade
);

create table public.watchlist_change_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  primary key (user_id, id)
);

alter table public.watchlist_groups enable row level security;
alter table public.watchlist_group_assets enable row level security;
alter table public.watchlist_change_receipts enable row level security;
revoke all on public.watchlist_groups, public.watchlist_group_assets, public.watchlist_change_receipts
  from anon, authenticated;

create function public.get_watchlists(p_user_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with owner as (select auth.uid() as id where auth.uid() = p_user_id),
  lists as (
    select '00000000-0000-0000-0000-000000000001'::uuid as id,
      coalesce(g.name, 'My Watchlist') as name, '-infinity'::timestamptz as created_at,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', a.id, 'listing_id', a.symbol, 'symbol', a.symbol, 'name', a.name, 'kind', a.kind,
          'exchange', a.exchange, 'added_at', a.updated_at
        ) order by a.sort_position nulls last, a.updated_at, a.id)
        from public.watchlist_assets a where a.user_id = owner.id and a.deleted_at is null
      ), '[]'::jsonb) as assets
    from owner left join public.watchlist_groups g
      on g.user_id = owner.id and g.id = '00000000-0000-0000-0000-000000000001'
    where owner.id is not null
    union all
    select g.id, g.name, g.created_at,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', a.id, 'listing_id', a.listing_id, 'symbol', a.symbol, 'name', a.name,
          'kind', a.kind, 'exchange', a.exchange, 'added_at', a.added_at
        ) order by a.sort_position nulls last, a.added_at, a.listing_id)
        from public.watchlist_group_assets a where a.user_id = g.user_id and a.group_id = g.id
      ), '[]'::jsonb)
    from public.watchlist_groups g join owner on owner.id = g.user_id
    where g.deleted_at is null and g.id <> '00000000-0000-0000-0000-000000000001'
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'assets', assets)
    order by created_at, id), '[]'::jsonb) from lists;
$$;

-- Import a legacy local list once. An existing list (including a deleted list) or
-- an existing default symbol (including a removed symbol) wins over cached data.
create function public.apply_watchlist_change(p_user_id uuid, p_id uuid, p_group_id uuid, p_action text,
  p_name text default null, p_assets jsonb default '[]', p_keys text[] default '{}') returns void
language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  is_default boolean := p_group_id = '00000000-0000-0000-0000-000000000001';
  imported boolean := false;
  start_position bigint;
begin
  if owner_id is null or owner_id is distinct from p_user_id then
    raise exception 'Sign in to change your watchlists' using errcode = '42501';
  end if;
  if p_id is null or p_group_id is null or p_action is null
     or p_action not in ('import', 'create', 'rename', 'delete', 'add', 'remove', 'reorder') then
    raise exception 'Invalid watchlist change' using errcode = '22023';
  end if;

  -- Serialise changes within an account, and make a retry after a lost response safe.
  perform pg_advisory_xact_lock(hashtextextended('watchlists:' || owner_id::text, 0));
  insert into public.watchlist_change_receipts(user_id, id) values (owner_id, p_id)
    on conflict do nothing;
  if not found then return; end if;

  if p_action in ('create', 'import') then
    if not is_default or btrim(p_name) <> 'My Watchlist' then
      insert into public.watchlist_groups(user_id, id, name) values (owner_id, p_group_id, btrim(p_name))
        on conflict do nothing;
      imported := found;
    end if;
    if p_action = 'create' or (not is_default and not imported) then return; end if;
  elsif p_action = 'rename' then
    if is_default then
      insert into public.watchlist_groups(user_id, id, name) values (owner_id, p_group_id, btrim(p_name))
        on conflict (user_id, id) do update set name = excluded.name;
    else
      update public.watchlist_groups set name = btrim(p_name)
        where user_id = owner_id and id = p_group_id and deleted_at is null;
    end if;
    return;
  elsif p_action = 'delete' then
    if is_default then raise exception 'The default watchlist cannot be deleted' using errcode = '22023'; end if;
    update public.watchlist_groups set deleted_at = now()
      where user_id = owner_id and id = p_group_id and deleted_at is null;
    delete from public.watchlist_group_assets where user_id = owner_id and group_id = p_group_id;
    return;
  elsif not is_default and not exists (
    select 1 from public.watchlist_groups where user_id = owner_id and id = p_group_id and deleted_at is null
  ) then
    return;
  end if;

  if is_default then
    if p_action = 'import' then
      -- Legacy imports are appended in device order.
      insert into public.watchlist_assets(user_id, symbol, name, kind, exchange, updated_at)
        select owner_id, asset->>'symbol', asset->>'name', asset->>'kind', asset->>'exchange',
          clock_timestamp() + ord * interval '1 microsecond'
        from jsonb_array_elements(p_assets) with ordinality as assets(asset, ord)
        on conflict (user_id, symbol) do nothing;
    elsif p_action = 'add' then
      insert into public.watchlist_assets(user_id, symbol, name, kind, exchange)
        select owner_id, asset->>'symbol', asset->>'name', asset->>'kind', asset->>'exchange'
        from jsonb_array_elements(p_assets) as assets(asset)
        on conflict (user_id, symbol) do update set name = excluded.name, kind = excluded.kind,
          exchange = excluded.exchange, deleted_at = null, sort_position = null
        where watchlist_assets.deleted_at is not null;
    elsif p_action = 'remove' then
      update public.watchlist_assets set deleted_at = now(), sort_position = null
        where user_id = owner_id and symbol = any(p_keys) and deleted_at is null;
    elsif p_action = 'reorder' then
      update public.watchlist_assets a set sort_position = keys.ord
        from unnest(p_keys) with ordinality as keys(key, ord)
        where a.user_id = owner_id and a.symbol = keys.key and a.deleted_at is null;
    end if;
  elsif p_action in ('import', 'add') then
    select coalesce(max(sort_position), 0) into start_position from public.watchlist_group_assets
      where user_id = owner_id and group_id = p_group_id;
    insert into public.watchlist_group_assets(user_id, group_id, listing_id, symbol, name, kind, exchange, sort_position)
      select owner_id, p_group_id, asset->>'listing_id', asset->>'symbol', asset->>'name', asset->>'kind',
        asset->>'exchange', start_position + ord
      from jsonb_array_elements(p_assets) with ordinality as assets(asset, ord)
      on conflict (user_id, group_id, listing_id) do nothing;
  elsif p_action = 'remove' then
    delete from public.watchlist_group_assets
      where user_id = owner_id and group_id = p_group_id and listing_id = any(p_keys);
  elsif p_action = 'reorder' then
    -- Keep assets added by another client since this order was read, after the ordered rows.
    with requested as (select key, min(ord) as ord from unnest(p_keys) with ordinality as keys(key, ord) group by key),
    positions as (
      select a.listing_id, row_number() over (order by requested.ord nulls last, a.sort_position nulls last, a.listing_id) as position
      from public.watchlist_group_assets a left join requested on requested.key = a.listing_id
      where a.user_id = owner_id and a.group_id = p_group_id
    )
    update public.watchlist_group_assets a set sort_position = positions.position
      from positions where a.user_id = owner_id and a.group_id = p_group_id and a.listing_id = positions.listing_id;
  end if;
end;
$$;

revoke all on function public.get_watchlists(uuid) from public, anon;
revoke all on function public.apply_watchlist_change(uuid, uuid, uuid, text, text, jsonb, text[]) from public, anon;
grant execute on function public.get_watchlists(uuid) to authenticated;
grant execute on function public.apply_watchlist_change(uuid, uuid, uuid, text, text, jsonb, text[]) to authenticated;
