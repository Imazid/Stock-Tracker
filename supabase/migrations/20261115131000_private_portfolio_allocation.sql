-- Return only the current allocation inputs for the verified account.
create function public.private_portfolio_allocation(p_user uuid)
returns table (
  asset_class text, currency text, position_count integer, valued_count integer, stale_count integer,
  carrying_value text, oldest_valuation date
)
language sql stable security invoker set search_path = '' as $$
  with cutoff as (
    select (now() at time zone 'Australia/Sydney')::date as today
  )
  select h.asset_class, h.currency, count(*)::integer, count(mark.value)::integer,
    count(*) filter (where mark.valued_on < cutoff.today - 90)::integer,
    sum(mark.value)::text, min(mark.valued_on)
  from public.private_holdings h
  cross join cutoff
  join public.investment_commitments c on (c.id, c.user_id) = (h.commitment_id, h.user_id) and c.status = 'confirmed'
  left join lateral (
    select v.value, v.valued_on
    from public.valuation_history v
    where (v.holding_id, v.user_id) = (h.id, h.user_id)
      and v.valued_on <= cutoff.today
      and v.value < 'Infinity'::numeric
      and (v.provider_event_at is null or v.provider_event_at <= now())
      and (h.last_disposition_on is null or h.last_disposition_on > cutoff.today or v.valued_on > h.last_disposition_on)
      and (h.disposition_revision_at is null or h.disposition_revision_at > now() or v.provider_event_at > h.disposition_revision_at)
    order by v.valued_on desc, v.provider_event_at desc nulls last, v.id
    limit 1
  ) mark on true
  where h.user_id = p_user and h.confirmed_at <= now() and h.settled_amount is not null
    and not (h.remaining_units is not distinct from 0 and h.exit_source is not null
      and h.last_disposition_on is not null and h.last_disposition_on <= cutoff.today)
  group by h.asset_class, h.currency
  order by h.asset_class, h.currency;
$$;

revoke all on function public.private_portfolio_allocation(uuid) from public, anon, authenticated;
grant execute on function public.private_portfolio_allocation(uuid) to service_role;
notify pgrst, 'reload schema';
