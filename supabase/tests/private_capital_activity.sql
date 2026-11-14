\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id,email) values
  ('ca000000-0000-4000-8000-000000000001','private-capital-fixture@example.test'),
  ('ca000000-0000-4000-8000-000000000002','private-capital-other@example.test');

create temporary table capital_fixture (holding uuid, owner uuid, name text, currency text, status text, confirmed_at timestamptz);
insert into capital_fixture values
  ('ca000000-0000-4000-8000-000000000010','ca000000-0000-4000-8000-000000000001','First fund','AUD','confirmed',now()-interval '100 days'),
  ('ca000000-0000-4000-8000-000000000011','ca000000-0000-4000-8000-000000000001','Second fund','USD','confirmed',now()-interval '100 days'),
  ('ca000000-0000-4000-8000-000000000012','ca000000-0000-4000-8000-000000000001','Future confirmation','AUD','confirmed',now()+interval '2 days'),
  ('ca000000-0000-4000-8000-000000000013','ca000000-0000-4000-8000-000000000002','Other account fund','AUD','confirmed',now()-interval '100 days');

insert into public.investment_commitments
  (user_id,opportunity_id,provider,jurisdiction,rule_version,reviewed_document_url,requested_amount,currency,
   acknowledged_at,status,provider_reference,confirmed_at)
select f.owner,o.id,o.provider,'AU',r.version,o.source_url,100,f.currency,
  now()-interval '101 days',f.status,f.holding::text,f.confirmed_at
from capital_fixture f
cross join lateral (select id,provider,source_url from public.investment_opportunities
  where provider='birchal' and status='closed' order by id limit 1) o
cross join lateral (select version from public.private_market_rules where jurisdiction='AU' order by version desc limit 1) r;
insert into public.private_holdings (id,user_id,commitment_id,name,asset_class,currency,units,settled_amount,confirmed_at)
select f.holding,f.owner,k.id,f.name,'Venture fund',f.currency,10,100,f.confirmed_at
from capital_fixture f join public.investment_commitments k on k.provider_reference=f.holding::text;

insert into public.capital_calls (user_id,holding_id,amount,due_on,settled_on,source,provider_reference,provider_event_at,cancelled_at,cancellation_source)
select f.owner,f.holding,c.amount,cutoff.today+c.due,cutoff.today+c.paid,c.source,c.source,
  now()+c.reported*interval '1 day',now()+c.cancelled*interval '1 day',
  case when c.cancelled is not null then 'Provider cancellation notice' end
from capital_fixture f
join (values
  ('First fund',900719925474099.1234::numeric,-40,null::integer,'Overdue notice',-45,null::integer),
  ('Second fund',250.1234,0,null,'Due today',-2,null),
  ('Second fund',300,25,null,'Beyond the notification window',-2,null),
  ('Second fund',400,-5,-2,'Paid receipt',-7,null),
  ('First fund',200,10,null,'Withdrawn call',-9,-4),
  ('First fund',100,1,null,'Future report',1,null),
  ('Future confirmation',100,1,null,'Future holding notice',-2,null),
  ('Other account fund',100,-2,null,'Other account call',-4,null)
) c(name,amount,due,paid,source,reported,cancelled) on c.name=f.name
cross join lateral (select (now() at time zone 'Australia/Sydney')::date as today) cutoff;

insert into public.distributions (user_id,holding_id,amount,received_on,source,provider_reference,provider_event_at,reversed_at,reversal_source)
select f.owner,f.holding,150,cutoff.today+d.paid,d.source,d.source,
  now()+d.reported*interval '1 day',now()+d.reversed*interval '1 day',
  case when d.reversed is not null then 'Provider reversal' end
from capital_fixture f
cross join (values ('Distribution advice',-1,-1,null::integer),('Reversed distribution',-5,-6,-2),('Future payment',2,-1,null)) d(source,paid,reported,reversed)
cross join lateral (select (now() at time zone 'Australia/Sydney')::date as today) cutoff
where f.name='First fund';

insert into public.distributions (user_id,holding_id,amount,received_on,source,provider_event_at)
select f.owner,f.holding,90,(now() at time zone 'Australia/Sydney')::date-age,'Earlier distribution ' || age,now()-age*interval '1 day'
from capital_fixture f cross join generate_series(10,37) age where f.name='Second fund';

select case when not has_function_privilege('anon','public.private_capital_activity(uuid,text,integer)','execute')
  and not has_function_privilege('authenticated','public.private_capital_activity(uuid,text,integer)','execute')
  and has_function_privilege('service_role','public.private_capital_activity(uuid,text,integer)','execute')
  then 'ok capital activity requires the service role' else 'FAIL capital activity grants' end;

set role service_role;
select case when array_agg(source) = array['Overdue notice','Due today','Beyond the notification window']
  and array_agg(status) = array['overdue','upcoming','upcoming']
  and bool_or(source='Overdue notice' and amount='900719925474099.1234' and currency='AUD')
  and bool_or(source='Due today' and amount='250.1234' and currency='USD')
  then 'ok outstanding calls include overdue, same-day and later deadlines in their original currencies'
  else 'FAIL outstanding call order, filters or amount precision' end
from public.private_capital_activity('ca000000-0000-4000-8000-000000000001','calls');

select case when (array_agg(status))[1:3] = array['distribution','paid','cancelled']
  and (array_agg(source))[1:3] = array['Distribution advice','Paid receipt','Provider cancellation notice']
  and not bool_or(source in ('Future payment','Reversed distribution'))
  and count(*)=26
  then 'ok history shows posted activity with corrected evidence and a pagination sentinel'
  else 'FAIL history order, filtering or page size' end
from public.private_capital_activity('ca000000-0000-4000-8000-000000000001','history');

select case when count(*)=6 and min(occurred_on)=(now() at time zone 'Australia/Sydney')::date-37
  then 'ok older history stays available on the next page' else 'FAIL older history missing' end
from public.private_capital_activity('ca000000-0000-4000-8000-000000000001','history',25);

select case when count(*)=1 and bool_and(source='Other account call')
  then 'ok a second account sees only its own obligations' else 'FAIL capital activity crossed account boundaries' end
from public.private_capital_activity('ca000000-0000-4000-8000-000000000002','calls');
reset role;
rollback;
