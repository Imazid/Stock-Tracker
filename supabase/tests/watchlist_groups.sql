\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users(id) values ('67140200-110b-4f11-9086-01a000000001'), ('67140200-110b-4f11-9086-01a000000002');

set local role authenticated;
do $$
declare
  owner_id uuid := '67140200-110b-4f11-9086-01a000000001';
  other_id uuid := '67140200-110b-4f11-9086-01a000000002';
  default_id uuid := '00000000-0000-0000-0000-000000000001';
  group_id uuid := gen_random_uuid();
  second_id uuid := gen_random_uuid();
  add_id uuid := gen_random_uuid();
  rename_id uuid := gen_random_uuid();
  apple jsonb := '[{"listing_id":"us:AAPL","symbol":"AAPL","name":"Apple","kind":"Stock","exchange":"US"}]';
  bhp jsonb := '[{"listing_id":"asx:BHP","symbol":"BHP","name":"BHP","kind":"Stock","exchange":"ASX"},
    {"listing_id":"us:BHP","symbol":"BHP","name":"BHP ADR","kind":"Stock","exchange":"US"}]';
  lists jsonb;
begin
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  assert public.get_watchlists(owner_id)->0->>'id' = default_id::text, 'A new account needs a default list';
  insert into public.watchlist_assets(user_id, symbol, name, kind, exchange)
    values (owner_id, 'AAPL', 'Apple', 'Stock', 'US');
  update public.watchlist_assets set deleted_at = now() where user_id = owner_id and symbol = 'AAPL';

  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), default_id, 'import', 'My Watchlist', apple);
  assert jsonb_array_length(public.get_watchlists(owner_id)->0->'assets') = 0, 'Import resurrected a legacy tombstone';
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), default_id, 'add', p_assets => apple);
  assert public.get_watchlists(owner_id)->0->'assets'->0->>'symbol' = 'AAPL', 'Explicit re-add should restore a symbol';

  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), group_id, 'import', 'Research', bhp);
  perform public.apply_watchlist_change(owner_id, add_id, group_id, 'add', p_assets => apple);
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), second_id, 'create', 'Income');
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), second_id, 'add', p_assets => apple);
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), group_id, 'remove', p_keys => array['us:AAPL']);
  perform public.apply_watchlist_change(owner_id, add_id, group_id, 'add', p_assets => apple);
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), group_id, 'reorder', p_keys => array['us:BHP']);
  perform public.apply_watchlist_change(owner_id, rename_id, group_id, 'rename', 'Ideas');
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), group_id, 'rename', 'Research');
  perform public.apply_watchlist_change(owner_id, rename_id, group_id, 'rename', 'Ideas');
  lists := public.get_watchlists(owner_id);
  assert jsonb_array_length(lists) = 3, 'A named list was lost';
  assert jsonb_array_length(lists->0->'assets') = 1, 'Default membership was changed by editing a named list';
  assert jsonb_array_length(jsonb_path_query_first(lists, '$[*] ? (@.name == "Income")')->'assets') = 1, 'Other list membership was changed';
  assert jsonb_path_query_first(lists, '$[*] ? (@.name == "Research")')->'assets'->0->>'listing_id' = 'us:BHP',
    'Rename retry or manual order was incorrect';
  assert jsonb_path_query_first(lists, '$[*] ? (@.name == "Research")')->'assets'->1->>'listing_id' = 'asx:BHP',
    'Same-symbol listing or concurrently added item was lost';
  assert jsonb_array_length(jsonb_path_query_first(lists, '$[*] ? (@.name == "Research")')->'assets') = 2,
    'Retry resurrected the removed item';

  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), group_id, 'delete');
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), group_id, 'import', 'Stale device', bhp);
  perform public.apply_watchlist_change(owner_id, gen_random_uuid(), group_id, 'add', p_assets => apple);
  assert jsonb_array_length(public.get_watchlists(owner_id)) = 2, 'Deleted group was resurrected';

  perform set_config('request.jwt.claim.sub', other_id::text, true);
  assert public.get_watchlists(owner_id) = '[]'::jsonb, 'Other account read watchlists by supplying an owner ID';
  assert jsonb_array_length(public.get_watchlists(other_id)) = 1, 'Other account saw private lists';
  begin
    perform public.apply_watchlist_change(owner_id, gen_random_uuid(), second_id, 'delete');
    raise exception 'Other account removed a list';
  exception when insufficient_privilege then null;
  end;
  assert not has_table_privilege('authenticated', 'public.watchlist_groups', 'select'), 'Direct reads should be private';
  assert not has_function_privilege('anon', 'public.get_watchlists(uuid)', 'execute'), 'Anonymous users can read lists';

  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  assert jsonb_array_length(public.get_watchlists(owner_id)) = 2, 'Other account removed a list';
  raise notice 'Watchlist ownership, import, membership, order and retries verified';
end $$;

select 'ok   watchlist ownership, legacy migration, membership, ordering and idempotent retries';
rollback;
