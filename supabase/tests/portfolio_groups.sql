\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into auth.users(id) values
  ('92994000-1111-4444-8888-aabbcc000001'), ('92994000-1111-4444-8888-aabbcc000002');
set local role authenticated;
do $$
declare
  owner_id uuid := '92994000-1111-4444-8888-aabbcc000001';
  other_id uuid := '92994000-1111-4444-8888-aabbcc000002';
  main_id uuid := '00000000-0000-0000-0000-000000000002';
  research uuid := gen_random_uuid();
  income uuid := gen_random_uuid();
  change_id uuid := gen_random_uuid();
  main_holding uuid := gen_random_uuid();
  legacy_holding uuid := gen_random_uuid();
  named_holding uuid := gen_random_uuid();
  account_holding uuid := gen_random_uuid();
  sale uuid := gen_random_uuid();
  readd uuid := gen_random_uuid();
  day date := (now() at time zone 'UTC')::date;
  newest timestamptz := day::timestamp at time zone 'UTC' + interval '2 seconds';
  older timestamptz := newest - interval '1 second';
  base_row jsonb := '{"asset_symbol":"AAPL","asset_name":"Apple","asset_kind":"Stock","asset_exchange":"US","shares":4,"avg_cost":160,"date_added":"2026-10-01T00:00:00Z"}';
  ledger jsonb;
begin
  perform set_config('request.jwt.claim.sub', owner_id::text, true);

  perform public.sync_portfolio_ledger(owner_id, base_row || jsonb_build_object('id',main_holding),
    '[]','{}','{}',null,null);
  perform public.sync_portfolio_ledger(owner_id, base_row || jsonb_build_object('id',legacy_holding),
    '[]','{}','{}',null,null);

  perform public.apply_portfolio_group_change(owner_id, change_id, research, 'import', 'Research', '💼', array[legacy_holding]);
  perform public.apply_portfolio_group_change(owner_id, gen_random_uuid(), income, 'create', 'Income', '📈');
  perform public.apply_portfolio_group_change(owner_id, gen_random_uuid(), research, 'rename', 'Long term');
  perform public.apply_portfolio_group_change(owner_id, change_id, research, 'import', 'Research', '💼', array[main_holding]);
  assert (select name from public.portfolio_groups where id = research) = 'Long term', 'Retry reverted a rename';
  assert (select portfolio_group_id from public.portfolio_holdings where id = legacy_holding) = research,
    'Existing holding failed to retain its locally named portfolio';
  assert (select portfolio_group_id is null from public.portfolio_holdings where id = main_holding),
    'Default holding moved during retry';

  perform public.sync_portfolio_ledger(owner_id, base_row || jsonb_build_object('id',named_holding,'portfolio_group_id',research),
    '[]','{}','{}',null,null);
  perform public.sync_portfolio_ledger(owner_id, base_row || jsonb_build_object('id',named_holding,'shares',55),
    '[]','{}','{}',null,null);
  assert (select shares = 4 and portfolio_group_id = research from public.portfolio_holdings where id=named_holding),
    'An old default-list write changed an explicitly named holding';

  ledger := jsonb_build_array(jsonb_build_object('id',sale,'transaction_date',now(),'shares',4,
    'price_per_share',200,'type','Sell','fees',0));
  perform public.sync_portfolio_ledger(owner_id, base_row || jsonb_build_object('id',named_holding,
    'portfolio_group_id',research,'shares',0), ledger, array[sale], '{}', now(), now());
  assert exists(select from public.transactions where id=sale and holding_id=named_holding and deleted_at is null),
    'Closing a holding lost its transaction ledger';

  perform public.save_portfolio_group_value(owner_id, main_id, day, 400, newest);
  perform public.save_portfolio_group_value(owner_id, research, day, 200, newest);
  perform public.save_portfolio_group_value(owner_id, research, day, 100, older);
  perform public.save_portfolio_group_value(owner_id, income, day, 900, newest);
  perform public.save_portfolio_group_value(owner_id, main_id, day, 800, older);
  assert (select total_value from public.portfolio_snapshots where user_id=owner_id and snapshot_date=day)=400,
    'An older device overwrote the main valuation';
  assert (select total_value from public.portfolio_group_snapshots where portfolio_group_id=research and snapshot_date=day)=200,
    'Same-day valuation was overwritten by another portfolio or an older device';

  perform public.sync_portfolio_ledger(owner_id, base_row || jsonb_build_object('id',account_holding,
    'portfolio_group_id',income,'broker_account',jsonb_build_object('account_id',gen_random_uuid(),'label','Broker ••••1234',
    'institution','Broker','tracking',true,'observed_at',to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'))), '[]','{}','{}',null,null);
  begin
    perform public.apply_portfolio_group_change(owner_id,gen_random_uuid(),income,'delete');
    raise exception 'A tracked portfolio was deleted';
  exception when invalid_parameter_value then null;
  end;

  perform public.apply_portfolio_group_change(owner_id,gen_random_uuid(),research,'delete');
  perform public.apply_portfolio_group_change(owner_id,gen_random_uuid(),research,'import','Restored','💼');
  perform public.sync_portfolio_ledger(owner_id, base_row || jsonb_build_object('id',readd,'portfolio_group_id',research),
    '[]','{}','{}',null,null);
  assert (select deleted_at is not null from public.portfolio_groups where id=research), 'Archived group resurrected';
  assert not exists(select from public.portfolio_holdings where id=readd), 'Old device wrote into a deleted group';
  begin
    insert into public.portfolio_holdings(id,user_id,asset_symbol,asset_name,asset_kind,asset_exchange,shares,avg_cost,portfolio_group_id)
      values(readd,owner_id,'TSLA','Tesla','Stock','US',1,100,research);
    raise exception 'Direct writes could insert into an archived group';
  exception when invalid_parameter_value then null;
  end;
  begin
    update public.portfolio_holdings set portfolio_group_id = income where id=main_holding;
    raise exception 'Direct writes could reassign existing positions';
  exception when invalid_parameter_value then null;
  end;
  assert exists(select from public.transactions where id=sale), 'Group deletion erased the transaction report';
  assert exists(select from public.portfolio_holdings where id=main_holding and deleted_at is null),
    'Group deletion touched the main portfolio';

  perform set_config('request.jwt.claim.sub', other_id::text, true);
  assert not exists(select from public.portfolio_groups where id=research), 'Other owner can read group';
  assert not exists(select from public.portfolio_group_snapshots where portfolio_group_id=research), 'Other owner can read values';
  begin
    perform public.apply_portfolio_group_change(owner_id,gen_random_uuid(),income,'rename','Wrong owner');
    raise exception 'Other owner can write group';
  exception when insufficient_privilege then null;
  end;
end $$;
select 'ok   portfolio ownership, retry-safe migration, separate valuations, closed trades and deletion';
rollback;
