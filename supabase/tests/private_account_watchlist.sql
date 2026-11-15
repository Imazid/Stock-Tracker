\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;
select gen_random_uuid() as owner, gen_random_uuid() as stranger, gen_random_uuid() as device,
  gen_random_uuid() as issuer, gen_random_uuid() as other_issuer, gen_random_uuid() as notice \gset
insert into auth.users (id) values (:'owner'), (:'stranger');
insert into public.private_companies (id, name, sector, country, source_url, verified_at, published)
values (:'issuer', 'Account watchlist issuer', 'Finance', 'AU', 'https://issuer.example.test', now(), true),
       (:'other_issuer', 'Second watchlist issuer', 'Energy', 'AU', 'https://other.example.test', now(), true);
insert into public.corporate_actions (id, company_id, title, significance, source_url, published_at, published)
values (:'notice', :'issuer', 'Dated disclosure', 'A sourced corporate update', 'https://issuer.example.test/notice', now(), true);

set role service_role;
select case when public.update_private_company_watchlist(:'owner', array[:'issuer']::uuid[], '{}', false)
    @> jsonb_build_array(jsonb_build_object('id', :'issuer', 'name', 'Account watchlist issuer'))
  and public.private_company_watchlist(:'stranger') = '[]'
  then 'ok   a signed-in follow returns its published source only to its owner' else 'FAIL account watchlist isolation' end;
reset role;

select case when not exists (select 1 from public.private_monitor_devices where user_id = :'owner')
    and public.collect_private_market_alerts(:'owner') = 0
  then 'ok   following requires separate monitoring consent' else 'FAIL following enabled monitoring' end;

set role service_role;
select public.configure_private_monitor(:'owner', :'device', '{}', false, true, false);
select public.configure_private_monitor(:'stranger', gen_random_uuid(), '{}', false, true, false);
select public.collect_private_market_alerts(null);
select case when (select count(*) from public.private_market_alert_inbox(:'owner') where subject_id = :'notice') = 1
    and not exists (select 1 from public.private_market_alert_inbox(:'stranger') where subject_id = :'notice')
  then 'ok   an opted-in device receives only the owner account follow' else 'FAIL watchlist monitoring isolation' end;

select public.update_private_company_watchlist(:'owner', array[:'other_issuer']::uuid[], '{}', true);
select public.update_private_company_watchlist(:'owner', '{}', array[:'issuer']::uuid[], false);
select case when public.update_private_company_watchlist(:'owner', array[:'issuer']::uuid[], '{}', true)
    = jsonb_build_array(jsonb_build_object('id', :'other_issuer', 'name', 'Second watchlist issuer', 'source', 'https://other.example.test'))
    and not exists (select 1 from public.private_market_alert_inbox(:'owner') where subject_id = :'notice')
  then 'ok   a legacy import respects an account unfollow and the inbox updates' else 'FAIL an unfollow was restored' end;
select public.configure_private_monitor(:'owner', :'device', '{}', false, false, false);
select case when jsonb_array_length(public.private_company_watchlist(:'owner')) = 1
  then 'ok   turning off monitoring keeps the account watchlist' else 'FAIL subscription erased the watchlist' end;
reset role;

update public.private_companies set published = false where id = :'other_issuer';
set role service_role;
select case when public.private_company_watchlist(:'owner') =
    jsonb_build_array(jsonb_build_object('id', :'other_issuer', 'name', 'Unavailable company', 'source', null))
  then 'ok   an unpublished record stays removable without exposing company details' else 'FAIL watchlist exposed unpublished details' end;
select public.update_private_company_watchlist(:'owner', '{}', array[:'other_issuer']::uuid[], false);
select case when public.private_company_watchlist(:'owner') = '[]' and
    not has_table_privilege('anon', 'public.private_company_follows', 'select') and
    not has_function_privilege('authenticated', 'public.update_private_company_watchlist(uuid,uuid[],uuid[],boolean)', 'execute')
  then 'ok   unpublished follows can be removed and direct access stays restricted' else 'FAIL watchlist privileges or removal' end;
reset role;
delete from auth.users where id = :'owner';
select case when not exists (select 1 from public.private_company_follows where user_id = :'owner')
  then 'ok   account deletion removes its watchlist' else 'FAIL watchlist survives account deletion' end;
rollback;
