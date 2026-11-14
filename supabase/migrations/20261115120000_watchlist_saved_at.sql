-- Existing rows have no reliable addition timestamp. Record additions from this point on.
alter table public.watchlist_assets add column saved_at timestamptz;

create function public.record_watchlist_save_time() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.saved_at := case when new.deleted_at is null then now() end;
  elsif old.deleted_at is not null and new.deleted_at is null then
    new.saved_at := now();
  else
    new.saved_at := old.saved_at;
  end if;
  return new;
end;
$$;

create trigger watchlist_assets_saved_at before insert or update on public.watchlist_assets
for each row execute function public.record_watchlist_save_time();

create or replace function public.get_watchlists(p_user_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with owner as (select auth.uid() as id where auth.uid() = p_user_id),
  lists as (
    select '00000000-0000-0000-0000-000000000001'::uuid as id,
      coalesce(g.name, 'My Watchlist') as name, '-infinity'::timestamptz as created_at,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', a.id, 'listing_id', a.symbol, 'symbol', a.symbol, 'name', a.name, 'kind', a.kind,
          'exchange', a.exchange, 'added_at', a.updated_at, 'saved_at', a.saved_at
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
          'kind', a.kind, 'exchange', a.exchange, 'added_at', a.added_at, 'saved_at', a.added_at
        ) order by a.sort_position nulls last, a.added_at, a.listing_id)
        from public.watchlist_group_assets a where a.user_id = g.user_id and a.group_id = g.id
      ), '[]'::jsonb)
    from public.watchlist_groups g join owner on owner.id = g.user_id
    where g.deleted_at is null and g.id <> '00000000-0000-0000-0000-000000000001'
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'assets', assets)
    order by created_at, id), '[]'::jsonb) from lists;
$$;

-- Return only listings with enough independent confirmed accounts to disclose.
-- Keep each listing's raw count and every person's membership private.
create function public.most_watched_listings(p_user_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with memberships as (
    select user_id, case
      when kind = 'Crypto' then 'crypto:' || upper(symbol)
      when upper(exchange) in ('ASX', 'XASX', 'AUSTRALIAN SECURITIES EXCHANGE') or upper(symbol) like '%.AX'
        then 'asx:' || regexp_replace(upper(symbol), '\.AX$', '')
      when upper(exchange) in ('US', 'NYSE', 'XNYS', 'NASDAQ', 'XNAS', 'AMEX', 'XASE', 'NYSE ARCA', 'ARCX', 'BATS', 'BZX', 'OTC')
        then 'us:' || upper(symbol)
      end as listing_id
    from public.watchlist_assets where deleted_at is null
    union
    select a.user_id, a.listing_id
    from public.watchlist_group_assets a
    join public.watchlist_groups g on (g.user_id, g.id) = (a.user_id, a.group_id)
    where g.deleted_at is null
  ), ranked as (
    select m.listing_id, count(*) as supporters
    from memberships m join auth.users u on u.id = m.user_id
    where auth.uid() = p_user_id and to_jsonb(u)->>'email_confirmed_at' is not null
      and m.listing_id ~ '^(us|asx|crypto):[A-Z0-9][A-Z0-9.&-]{0,19}$'
    group by m.listing_id
    having count(*) >= 10
    order by supporters desc, m.listing_id
    limit 15
  )
  select coalesce(jsonb_agg(listing_id order by supporters desc, listing_id), '[]'::jsonb) from ranked;
$$;

revoke all on function public.most_watched_listings(uuid) from public, anon;
grant execute on function public.most_watched_listings(uuid) to authenticated;
