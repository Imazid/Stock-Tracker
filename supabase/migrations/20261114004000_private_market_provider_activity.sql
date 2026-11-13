-- A contract may cover ongoing position records without granting further
-- transaction authority. Record the explicit capability per provider approval.
alter table public.private_provider_approvals
  add column holding_activity_enabled boolean not null default false;
alter table public.private_holdings add column settled_on date;
alter table public.private_holdings add column settlement_source text;

do $$
declare
  relation text;
begin
  foreach relation in array array['valuation_history','capital_calls','distributions']
  loop
    execute format('alter table public.%I add column provider_reference text, add column provider_event_at timestamptz', relation);
    execute format('create unique index on public.%I (holding_id, provider_reference)', relation);
    execute format('create index on public.%I (holding_id)', relation);
  end loop;
end $$;

-- Trusted connector contract. A provider adapter must authenticate its own
-- source before calling this function. There is no client write permission.
create function public.record_private_holding_activity(
  p_provider text,
  p_subject text,
  p_holding uuid,
  p_kind text,
  p_reference text,
  p_event_at timestamptz,
  p_amount numeric,
  p_currency text,
  p_record_date date,
  p_source text,
  p_method text default null,
  p_settled_on date default null
) returns boolean language plpgsql set search_path = '' as $$
declare
  holding public.private_holdings%rowtype;
  affected integer;
begin
  if p_kind is null or p_kind not in ('valuation','capital_call','distribution','opening_settlement') or
     nullif(trim(p_reference), '') is null or length(p_reference) > 200 or
     nullif(trim(p_source), '') is null or length(p_source) > 400 or
     p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or
     p_amount < 0 or (p_kind <> 'valuation' and p_amount = 0) or
     p_amount >= 10000000000000000 or p_amount <> round(p_amount, 4) or
     p_event_at is null or not isfinite(p_event_at) or p_event_at > now() or
     p_record_date is null or not isfinite(p_record_date) or
     (p_kind <> 'capital_call' and p_record_date > (p_event_at at time zone 'UTC')::date + 1) or
     (p_settled_on is not null and
       (p_kind <> 'capital_call' or not isfinite(p_settled_on) or p_settled_on > (p_event_at at time zone 'UTC')::date + 1)) or
     (p_kind = 'valuation' and (nullif(trim(p_method), '') is null or length(p_method) > 400)) then
    raise exception 'Invalid position record' using errcode = '22023';
  end if;

  select h.* into holding from public.private_holdings h
    join public.investment_commitments c on (c.id,c.user_id) = (h.commitment_id,h.user_id)
    join public.provider_connections pc on pc.user_id = h.user_id and pc.provider = c.provider and pc.revoked_at is null
    join public.private_provider_approvals a on a.provider = c.provider and a.jurisdiction = c.jurisdiction
    where h.id = p_holding and h.confirmed_at is not null and c.status = 'confirmed'
      and c.provider = p_provider and pc.external_subject = p_subject
      and a.holding_activity_enabled and a.expires_at > now()
    for update of h;
  if not found then
    raise exception 'Position record unavailable for this provider account' using errcode = '42501';
  end if;
  if p_currency is distinct from holding.currency then
    raise exception 'Record currency must match the position currency' using errcode = '22023';
  end if;

  case p_kind
  when 'valuation' then
    insert into public.valuation_history as current
      (user_id, holding_id, value, valued_on, source, methodology, provider_reference, provider_event_at)
    values (holding.user_id, holding.id, p_amount, p_record_date, trim(p_source), trim(p_method), p_reference, p_event_at)
    on conflict (holding_id, provider_reference) do update
      set value = excluded.value, valued_on = excluded.valued_on, source = excluded.source,
          methodology = excluded.methodology, provider_event_at = excluded.provider_event_at
      where current.provider_event_at < excluded.provider_event_at;
  when 'capital_call' then
    insert into public.capital_calls as current
      (user_id, holding_id, amount, due_on, settled_on, source, provider_reference, provider_event_at)
    values (holding.user_id, holding.id, p_amount, p_record_date, p_settled_on, trim(p_source), p_reference, p_event_at)
    on conflict (holding_id, provider_reference) do update
      set amount = excluded.amount, due_on = excluded.due_on, settled_on = excluded.settled_on,
          source = excluded.source, provider_event_at = excluded.provider_event_at
      where current.provider_event_at < excluded.provider_event_at;
  when 'distribution' then
    insert into public.distributions as current
      (user_id, holding_id, amount, received_on, source, provider_reference, provider_event_at)
    values (holding.user_id, holding.id, p_amount, p_record_date, trim(p_source), p_reference, p_event_at)
    on conflict (holding_id, provider_reference) do update
      set amount = excluded.amount, received_on = excluded.received_on, source = excluded.source,
          provider_event_at = excluded.provider_event_at
      where current.provider_event_at < excluded.provider_event_at;
  when 'opening_settlement' then
    if p_amount is distinct from holding.settled_amount or p_record_date > (holding.confirmed_at at time zone 'UTC')::date + 1 then
      raise exception 'Opening settlement must match confirmed capital' using errcode = '22023';
    end if;
    if holding.settled_on is not null and
      (holding.settled_on is distinct from p_record_date or holding.settlement_source is distinct from trim(p_source)) then
      raise exception 'Opening settlement conflicts with a recorded source or date' using errcode = '23505';
    end if;
    update public.private_holdings set settled_on = p_record_date, settlement_source = trim(p_source)
      where id = holding.id and settled_on is null;
  end case;
  get diagnostics affected = row_count;
  if affected > 0 then
    insert into public.investment_audit_logs (user_id, action, subject_id)
    values (holding.user_id, 'provider_' || p_kind, holding.id);
  end if;
  return affected > 0;
end $$;

revoke all on function public.record_private_holding_activity(text,text,uuid,text,text,timestamptz,numeric,text,date,text,text,date)
  from public, anon, authenticated;
grant execute on function public.record_private_holding_activity(text,text,uuid,text,text,timestamptz,numeric,text,date,text,text,date)
  to service_role;
