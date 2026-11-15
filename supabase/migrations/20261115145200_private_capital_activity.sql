-- Return posted provider activity for the authenticated account, independent of
-- the per-holding history limit and the seven-day monitor notification window.
create function public.private_capital_activity(p_user uuid, p_section text, p_offset integer default 0)
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
  )
  select a.* from activity a
  where (p_section = 'calls' and a.status in ('overdue', 'upcoming'))
     or (p_section = 'history' and a.status in ('paid', 'cancelled', 'distribution'))
  order by case when p_section = 'calls' then a.occurred_on end,
           case when p_section = 'history' then a.occurred_on end desc,
           a.status, a.id
  limit 26 offset greatest(p_offset, 0);
$$;

revoke all on function public.private_capital_activity(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.private_capital_activity(uuid, text, integer) to service_role;
notify pgrst, 'reload schema';
