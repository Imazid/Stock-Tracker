\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users(id) values ('66104000-1111-4444-8888-aabbcc000001');
insert into auth.users(id,email_confirmed_at)
select ('66104000-1111-4444-8888-aabbcc0000' || lpad(number::text, 2, '0'))::uuid, now()
from generate_series(10, 19) number;
insert into public.watchlist_assets(user_id,symbol,name,kind,exchange)
select id, 'ABC', 'ABC', 'Stock', 'US' from auth.users where email_confirmed_at is not null
  and id::text like '66104000-1111-4444-8888-aabbcc00001%';
insert into public.watchlist_assets(user_id,symbol,name,kind,exchange)
select id, 'NINE', 'Nine', 'Stock', 'US' from auth.users where email_confirmed_at is not null
  and id::text like '66104000-1111-4444-8888-aabbcc00001%' and right(id::text, 2) <> '19';
set local role authenticated;
set local request.jwt.claim.sub = '66104000-1111-4444-8888-aabbcc000001';
do $$
declare
  owner_id uuid := auth.uid();
  item_id uuid;
  original timestamptz;
  list_id uuid := gen_random_uuid();
begin
  assert public.most_watched_listings(owner_id) = '["us:ABC"]'::jsonb,
    'Nine accounts must not disclose a ranking';
  assert public.most_watched_listings('66104000-1111-4444-8888-aabbcc000019') = '[]'::jsonb,
    'Mismatched caller must not see the ranking';
  assert not has_function_privilege('anon', 'public.most_watched_listings(uuid)', 'execute'),
    'Anonymous users cannot request a ranking';
  perform set_config('request.jwt.claim.sub', '66104000-1111-4444-8888-aabbcc000010', true);
  perform public.apply_watchlist_change(auth.uid(), gen_random_uuid(), list_id, 'import', 'Other list',
    '[{"listing_id":"us:NINE","symbol":"NINE","name":"Nine","kind":"Stock","exchange":"US"}]');
  assert public.most_watched_listings(auth.uid()) = '["us:ABC"]'::jsonb,
    'Saving a symbol on two lists does not count as two people';
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  insert into public.watchlist_assets(user_id,symbol,name,kind,saved_at)
    values (owner_id,'ABC','ABC','Stock','2001-01-01')
    returning id,saved_at into item_id,original;
  assert original = now(), 'Addition time must be set by the server';
  update public.watchlist_assets set sort_position = 1, saved_at = '2001-01-01' where id = item_id;
  assert (select saved_at from public.watchlist_assets where id = item_id) = original,
    'Reordering or a client update must preserve the addition timestamp';
  assert (public.get_watchlists(owner_id)->0->'assets'->0->>'saved_at')::timestamptz = original,
    'The timestamp must be present in the account response';
  update public.watchlist_assets set deleted_at = now() where id = item_id;
  assert jsonb_array_length(public.get_watchlists(owner_id)->0->'assets') = 0,
    'Removed rows must stay out of recently added';
end $$;
select 'ok   watchlist save times survive reorder and private popularity requires distinct confirmed accounts';
rollback;
