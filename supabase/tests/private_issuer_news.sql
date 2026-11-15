\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id,email) values ('c0000000-0000-4000-c000-000000000001','issuer-fixture@example.test');

set role service_role;
create temporary table issuer_job as select * from public.claim_private_issuer_news();
select case when count(*)=1 then 'ok   the published newsroom is eligible to refresh' else 'FAIL no newsroom claim' end from issuer_job;
select case when count(*)=0 then 'ok   an overlapping run cannot claim the same newsroom' else 'FAIL duplicate newsroom lease' end
  from public.claim_private_issuer_news();
select case when public.finish_private_issuer_news(company,gen_random_uuid(),null,'[]',null,null)=0
  then 'ok   wrong lease cannot write' else 'FAIL stale lease' end from issuer_job;
create temporary table notice_payload as select jsonb_build_array(
  jsonb_build_object('source_url','https://www.advancell.com.au/news/sql-fixture-update/','title','Issuer published an update',
    'significance','Read the original source.','published_at',now()-interval '1 day'),
  jsonb_build_object('source_url','https://other.example/news/forged/','title','Forged','significance','Fake','published_at',now()),
  jsonb_build_object('source_url','https://www.advancell.com.au/news/future/','title','Future','significance','Future',
    'published_at',now()+interval '1 day')
) as notices;
select case when public.finish_private_issuer_news(company,token,'"one"',notices,null,null)=1
  then 'ok   only verified-shaped issuer notice is imported' else 'FAIL import boundary' end
  from issuer_job cross join notice_payload;
select case when count(*)=1 and min(source_label)='AdvanCell newsroom' and min(published_at)=now()-interval '1 day'
  then 'ok   import preserves publication date and source' else 'FAIL source provenance' end
  from public.corporate_actions where source_url='https://www.advancell.com.au/news/sql-fixture-update/';
select public.configure_private_monitor('c0000000-0000-4000-c000-000000000001','c0000000-0000-4000-c000-000000000002',
  array['d72c4060-1ae7-4a2f-8f2e-9f4bf1577e02']::uuid[],false,true);
select public.collect_private_market_alerts('c0000000-0000-4000-c000-000000000001');
select case when count(*)=1 and min(source_label)='AdvanCell newsroom'
  then 'ok   sourced notice reaches the account monitoring inbox' else 'FAIL missing sourced monitoring alert' end
  from public.private_market_alert_inbox('c0000000-0000-4000-c000-000000000001') where source_url like '%sql-fixture-update/%';

reset role;
update public.private_issuer_news_refresh set next_check_at = now() - interval '1 second';
set role service_role;
create temporary table issuer_retry as select * from public.claim_private_issuer_news();
select case when count(*)=1 and min(etag)='"one"' then 'ok   refresh reuses the previous ETag' else 'FAIL validator lost' end
  from issuer_retry;
select case when public.finish_private_issuer_news(company,token,'"two"',notices,null,null)=0
  then 'ok   unchanged source is deduplicated' else 'FAIL replay created a notice' end
  from issuer_retry cross join notice_payload;

reset role;
update public.private_issuer_news_refresh set next_check_at = now() - interval '1 second';
set role service_role;
create temporary table issuer_edit as select * from public.claim_private_issuer_news();
select case when public.finish_private_issuer_news(company,token,'"three"',
  jsonb_build_array(jsonb_set(notices->0,'{title}','"Updated issuer notice"')),null,null)=1
  then 'ok   edited metadata updates the original notice' else 'FAIL source correction' end
  from issuer_edit cross join notice_payload;
select case when count(*)=1 and min(title)='Updated issuer notice'
  then 'ok   inbox reads the current version without a duplicate alert' else 'FAIL stale inbox copy' end
  from public.private_market_alert_inbox('c0000000-0000-4000-c000-000000000001') where source_url like '%sql-fixture-update/%';
select case when count(*)=1 and min(status)='closed' and count(handoff_url)=0
  then 'ok   newsroom import does not affect historical offer status' else 'FAIL issuer release modified an offer' end
  from public.investment_opportunities where id='d72c4060-1ae7-4a2f-8f2e-9f4bf1577e22';

reset role;
set role authenticated;
select case when not has_function_privilege(current_user,'public.claim_private_issuer_news()','execute')
  and not has_table_privilege(current_user,'public.private_issuer_news_refresh','select')
  then 'ok   app accounts cannot drive newsroom publication' else 'FAIL newsroom writer exposed' end;
reset role;
rollback;
