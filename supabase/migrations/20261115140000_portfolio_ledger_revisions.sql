alter table public.portfolio_holdings add column ledger_revision uuid not null default gen_random_uuid();

create function portfolio_sync.touch_holding_ledger_revision() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.ledger_revision = old.ledger_revision then
    new.ledger_revision := gen_random_uuid();
  end if;
  return new;
end;
$$;
create trigger portfolio_holdings_ledger_revision before update on public.portfolio_holdings
for each row execute function portfolio_sync.touch_holding_ledger_revision();

create function portfolio_sync.touch_transaction_holding_revision() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op <> 'INSERT' then
    update public.portfolio_holdings set ledger_revision = gen_random_uuid()
      where id = old.holding_id and user_id = old.user_id;
  end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and (new.holding_id, new.user_id) is distinct from (old.holding_id, old.user_id)) then
    update public.portfolio_holdings set ledger_revision = gen_random_uuid()
      where id = new.holding_id and user_id = new.user_id;
  end if;
  return null;
end;
$$;
create trigger transactions_holding_ledger_revision after insert or update or delete on public.transactions
for each row execute function portfolio_sync.touch_transaction_holding_revision();

create table portfolio_sync.holding_change_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  mutation_id uuid not null,
  holding_id uuid not null,
  revision uuid not null,
  merged boolean not null,
  primary key (user_id, mutation_id)
);
alter table portfolio_sync.holding_change_receipts enable row level security;
create policy "owners read their holding receipts" on portfolio_sync.holding_change_receipts for select to authenticated
  using (user_id = (select auth.uid()));
create policy "owners create their holding receipts" on portfolio_sync.holding_change_receipts for insert to authenticated
  with check (user_id = (select auth.uid()));
grant select, insert on portfolio_sync.holding_change_receipts to authenticated;

-- Independent, appended buys commute. Compare the shared trade history and
-- starting balance before merging them. A sale, deletion, position correction
-- or backdated trade requires the owner to review the pending change.
create function portfolio_sync.merge_appended_buys(
  p_current public.portfolio_holdings, p_holding jsonb, p_trades jsonb, p_changed uuid[]
) returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare
  local_units numeric;
  local_cost numeric;
  cloud_units numeric;
  cloud_cost numeric;
  new_units numeric;
  last_shared timestamptz;
  matching boolean;
begin
  if p_current.broker_account is not null or p_holding->'broker_account' is not null
    or coalesce(cardinality(p_changed),0) = 0 then return null; end if;
  with incoming as (
    select * from jsonb_to_recordset(p_trades) as row(
      id uuid, type text, transaction_date timestamptz, shares double precision,
      price_per_share double precision, fees double precision, avg_cost_at_sale double precision
    )
  ), cloud as (
    select id, type, transaction_date, shares, price_per_share, fees, avg_cost_at_sale
      from public.transactions where user_id = p_current.user_id and holding_id = p_current.id and deleted_at is null
  )
  select max(i.transaction_date) filter (where i.id is not null and t.id is not null),
    coalesce(sum(i.shares::numeric) filter (where i.id = any(p_changed)),0),
    coalesce(sum(i.shares::numeric * i.price_per_share::numeric + i.fees::numeric) filter (where i.id = any(p_changed)),0),
    coalesce(sum(t.shares::numeric) filter (where i.id is null),0),
    coalesce(sum(t.shares::numeric * t.price_per_share::numeric + t.fees::numeric) filter (where i.id is null),0),
    coalesce(bool_and(case
      when i.id is null then t.type = 'Buy'
      when i.id = any(p_changed) then t.id is null and i.type = 'Buy'
      else t.id is not null and (i.type,i.transaction_date,i.shares,i.price_per_share,i.fees,i.avg_cost_at_sale)
        is not distinct from (t.type,t.transaction_date,t.shares,t.price_per_share,t.fees,t.avg_cost_at_sale)
    end),false)
    into last_shared, local_units, local_cost, cloud_units, cloud_cost, matching
  from incoming i full join cloud t on t.id = i.id;
  if not matching or local_units <= 0 or cloud_units <= 0 then return null; end if;
  if last_shared is not null and (
    exists (select from jsonb_to_recordset(p_trades) as r(id uuid, transaction_date timestamptz)
      where id = any(p_changed) and transaction_date < last_shared)
    or exists (select from public.transactions t where t.user_id = p_current.user_id and t.holding_id = p_current.id
      and t.deleted_at is null and t.transaction_date < last_shared
      and not exists (select from jsonb_to_recordset(p_trades) as r(id uuid) where r.id = t.id))
  ) then return null; end if;
  if abs((p_holding->>'shares')::numeric - local_units - (p_current.shares::numeric - cloud_units)) > 0.000000001
    or abs((p_holding->>'shares')::numeric * (p_holding->>'avg_cost')::numeric - local_cost
      - (p_current.shares::numeric * p_current.avg_cost::numeric - cloud_cost)) > 0.000001 then return null; end if;

  new_units := p_current.shares::numeric + local_units;
  return p_holding || jsonb_build_object('shares',new_units,
    'avg_cost',(p_current.shares::numeric * p_current.avg_cost::numeric + local_cost) / new_units);
end;
$$;
revoke all on function portfolio_sync.merge_appended_buys(public.portfolio_holdings,jsonb,jsonb,uuid[]) from public, anon;
grant execute on function portfolio_sync.merge_appended_buys(public.portfolio_holdings,jsonb,jsonb,uuid[]) to authenticated;

create function public.apply_portfolio_ledger_change(
  p_user_id uuid, p_holding jsonb, p_transactions jsonb, p_changed_ids uuid[], p_deleted_ids uuid[],
  p_archived_at timestamptz, p_closed_at timestamptz, p_mutation_id uuid, p_expected_revision uuid
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  target_id uuid := (p_holding->>'id')::uuid;
  target_group uuid := (p_holding->>'portfolio_group_id')::uuid;
  result_revision uuid;
  prior portfolio_sync.holding_change_receipts;
  current_holding public.portfolio_holdings;
  proposed_holding jsonb := p_holding;
  merged boolean := false;
begin
  if owner_id is null or owner_id is distinct from p_user_id then
    raise exception 'Portfolio account changed' using errcode = '42501';
  end if;
  if target_id is null or p_mutation_id is null then
    raise exception 'Invalid holding change' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('portfolio-groups:' || owner_id::text, 0));
  select * into prior from portfolio_sync.holding_change_receipts
    where user_id = owner_id and mutation_id = p_mutation_id;
  if found then
    if prior.holding_id <> target_id then
      raise exception 'Holding change identifier already used' using errcode = '22023';
    end if;
    return jsonb_build_object('status','applied','revision',prior.revision,'merged',prior.merged);
  end if;

  select * into current_holding from public.portfolio_holdings
    where id = target_id and user_id = owner_id for update;
  if (current_holding.id is not null and (current_holding.deleted_at is not null or
        current_holding.portfolio_group_id is distinct from target_group))
    or (target_group is not null and not exists (
      select from public.portfolio_groups where user_id = owner_id and id = target_group and deleted_at is null
    )) then
    return jsonb_build_object('status','conflict');
  end if;

  if current_holding.ledger_revision is distinct from p_expected_revision then
    if current_holding.id is null or p_archived_at is not null
      or coalesce(cardinality(p_deleted_ids),0) > 0 then
      return jsonb_build_object('status','conflict');
    end if;
    proposed_holding := portfolio_sync.merge_appended_buys(current_holding,p_holding,p_transactions,p_changed_ids);
    if proposed_holding is null then return jsonb_build_object('status','conflict'); end if;
    merged := true;
    -- The server already owns the shared transactions. Send only the new buys.
    select coalesce(jsonb_agg(trade),'[]'::jsonb) into p_transactions
      from jsonb_array_elements(p_transactions) trade where (trade->>'id')::uuid = any(p_changed_ids);
  end if;

  perform public.sync_portfolio_ledger(p_user_id, proposed_holding, p_transactions, p_changed_ids,
    p_deleted_ids, p_archived_at, p_closed_at);
  select ledger_revision into result_revision from public.portfolio_holdings
    where id = target_id and user_id = owner_id;
  if result_revision is null or result_revision is not distinct from p_expected_revision then
    return jsonb_build_object('status','conflict');
  end if;
  insert into portfolio_sync.holding_change_receipts(user_id,mutation_id,holding_id,revision,merged)
    values(owner_id,p_mutation_id,target_id,result_revision,merged);
  return jsonb_build_object('status','applied','revision',result_revision,'merged',merged);
end;
$$;

revoke all on function portfolio_sync.touch_holding_ledger_revision() from public, anon, authenticated;
revoke all on function portfolio_sync.touch_transaction_holding_revision() from public, anon, authenticated;
revoke all on function public.apply_portfolio_ledger_change(uuid,jsonb,jsonb,uuid[],uuid[],timestamptz,timestamptz,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.apply_portfolio_ledger_change(uuid,jsonb,jsonb,uuid[],uuid[],timestamptz,timestamptz,uuid,uuid)
  to authenticated;

-- Each holding and its transaction rows come from one statement snapshot. A
-- client never edits a revision paired with transactions from an older read.
create function public.read_portfolio_ledger_page(p_user_id uuid, p_after uuid)
returns table(holding jsonb, transactions jsonb)
language sql stable security invoker set search_path = '' as $$
  select to_jsonb(h), coalesce((
    select jsonb_agg(to_jsonb(t) order by t.transaction_date, t.id)
    from public.transactions t
    where t.user_id = h.user_id and t.holding_id = h.id and t.deleted_at is null
  ), '[]'::jsonb)
  from public.portfolio_holdings h
  where h.user_id = (select auth.uid()) and h.user_id = p_user_id
    and (p_after is null or h.id > p_after)
  order by h.id
  limit 100;
$$;
revoke all on function public.read_portfolio_ledger_page(uuid,uuid) from public, anon, authenticated;
grant execute on function public.read_portfolio_ledger_page(uuid,uuid) to authenticated;
