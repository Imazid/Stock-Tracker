-- Include settled provider sales in the same chronological capital history.
create or replace function public.private_capital_activity(p_user uuid, p_section text, p_offset integer default 0)
returns table (
  id uuid, holding_id uuid, holding_name text, provider text, currency text, amount text,
  status text, due_on date, occurred_on date, source text
)
language sql stable security invoker set search_path = '' as $$
  with cutoff as (
    select (now() at time zone 'Australia/Sydney')::date as today
  ),
  confirmed as (
    select h.id, h.name, h.currency, k.provider
    from public.private_holdings h
    join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
    where h.user_id = p_user and k.status = 'confirmed'
      and h.confirmed_at <= now() and h.settled_amount is not null
  ),
  activity as (
    select c.id, c.holding_id, h.name, h.provider, h.currency, c.amount::text,
      case
        when c.cancelled_at <= now() then 'cancelled'
        when c.settled_on <= cutoff.today then 'paid'
        when c.due_on < cutoff.today then 'overdue'
        else 'upcoming'
      end as status,
      c.due_on,
      case
        when c.cancelled_at <= now() then (c.cancelled_at at time zone 'Australia/Sydney')::date
        when c.settled_on <= cutoff.today then c.settled_on
        else c.due_on
      end as occurred_on,
      case when c.cancelled_at <= now() then c.cancellation_source else c.source end as source
    from public.capital_calls c
    join confirmed h on h.id = c.holding_id
    cross join cutoff
    where c.user_id = p_user and isfinite(c.due_on)
      and (c.provider_event_at is null or c.provider_event_at <= now())
    union all
    select d.id, d.holding_id, h.name, h.provider, h.currency, d.amount::text,
      'distribution', null::date, d.received_on, d.source
    from public.distributions d
    join confirmed h on h.id = d.holding_id
    cross join cutoff
    where d.user_id = p_user and isfinite(d.received_on) and d.received_on <= cutoff.today
      and (d.provider_event_at is null or d.provider_event_at <= now())
      and d.reversed_at is null
    union all
    select d.id, d.holding_id, h.name, h.provider, h.currency, d.net_proceeds::text,
      'sale', null::date, d.settled_on, d.source
    from public.private_holding_dispositions d
    join confirmed h on h.id = d.holding_id
    cross join cutoff
    where d.user_id = p_user and not d.reversed
      and isfinite(d.settled_on) and d.settled_on <= cutoff.today
      and d.provider_event_at <= now()
  )
  select a.* from activity a
  where (p_section = 'calls' and a.status in ('overdue', 'upcoming'))
     or (p_section = 'history' and a.status in ('paid', 'cancelled', 'distribution', 'sale'))
  order by case when p_section = 'calls' then a.occurred_on end,
           case when p_section = 'history' then a.occurred_on end desc,
           a.status, a.id
  limit 26 offset greatest(p_offset, 0);
$$;

revoke all on function public.private_capital_activity(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.private_capital_activity(uuid, text, integer) to service_role;

-- Use the currency of the confirmed holding and preserve exact signed-provider values.
create function public.private_valuation_history(p_user uuid, p_holding uuid, p_offset integer default 0)
returns table (
  id uuid, value text, valued_on date, source text, methodology text, provider_event_at timestamptz
)
language sql stable security invoker set search_path = '' as $$
  select v.id, v.value::text, v.valued_on, v.source, v.methodology, v.provider_event_at
  from public.private_holdings h
  join public.investment_commitments c on (c.id, c.user_id) = (h.commitment_id, h.user_id)
  join public.valuation_history v on (v.holding_id, v.user_id) = (h.id, h.user_id)
  where h.user_id = p_user and h.id = p_holding
    and h.confirmed_at <= now() and h.settled_amount is not null and c.status = 'confirmed'
    and isfinite(v.valued_on) and v.valued_on <= (now() at time zone 'Australia/Sydney')::date
    and v.value < 'Infinity'::numeric
    and (v.provider_event_at is null or (isfinite(v.provider_event_at) and v.provider_event_at <= now()))
  order by v.valued_on desc, v.provider_event_at desc nulls last, v.id
  limit 26 offset greatest(p_offset, 0);
$$;

revoke all on function public.private_valuation_history(uuid,uuid,integer) from public, anon, authenticated;
grant execute on function public.private_valuation_history(uuid,uuid,integer) to service_role;
notify pgrst, 'reload schema';
