-- Persist the reference rate alongside the original amount used to reconcile a USD cash flow.
create function portfolio_metrics.valid_flow_fx(flows jsonb)
returns boolean language plpgsql immutable strict security invoker set search_path = '' as $$
declare
  flow jsonb;
  fx jsonb;
  rate_day date;
  original numeric;
  rate numeric;
begin
  if jsonb_typeof(flows) <> 'array' then return false; end if;
  for flow in select value from jsonb_array_elements(flows) loop
    if not (flow ? 'fx') then continue; end if;
    fx := flow->'fx';
    if not (flow ? 'snaptrade_id') or jsonb_typeof(fx) <> 'object'
      or not (fx ?& array['source','currency','amount','usd_per_unit','rate_date'])
      or exists (select 1 from jsonb_each(fx) entry where jsonb_typeof(entry.value) <> 'string')
      or fx->>'source' <> 'ECB' or fx->>'currency' !~ '^[A-Z]{3}$' or fx->>'currency' = 'USD'
      or fx->>'amount' !~ '^(0|[1-9][0-9]{0,12})(\.[0-9]{1,8})?$'
      or fx->>'usd_per_unit' !~ '^(0|[1-9][0-9]{0,11})(\.[0-9]{1,12})?$'
      or fx->>'rate_date' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return false; end if;
    rate_day := (fx->>'rate_date')::date;
    original := (fx->>'amount')::numeric;
    rate := (fx->>'usd_per_unit')::numeric;
    if rate_day < date '1999-01-04' or (flow->>'date')::date - rate_day not between 0 and 7
      or original <= 0 or original > 9999999999999.99 or rate <= 0
      or round(original * rate, 2) <> (flow->>'amount')::numeric then return false; end if;
  end loop;
  return true;
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then return false;
end;
$$;
revoke all on function portfolio_metrics.valid_flow_fx(jsonb) from public, anon;
grant execute on function portfolio_metrics.valid_flow_fx(jsonb) to authenticated, service_role;
alter table public.portfolio_performance_periods add constraint performance_flow_fx
  check (portfolio_metrics.valid_flow_fx(external_flows));

-- Older clients may omit both fields or round-trip only the SnapTrade reference.
-- Match the numeric transfer details and use every old record at most once.
create or replace function portfolio_metrics.preserve_flow_sources()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if jsonb_typeof(new.external_flows) <> 'array' then return new; end if;
  with new_entries as (
    select flow, position, flow - array['snaptrade_id','fx'] as details
    from jsonb_array_elements(new.external_flows) with ordinality rows(flow, position)
  ), old_entries as (
    select flow, flow - array['snaptrade_id','fx'] as details,
      row_number() over (partition by flow - array['snaptrade_id','fx'] order by position) as instance
    from jsonb_array_elements(old.external_flows) with ordinality rows(flow, position)
    where not exists (select 1 from new_entries n where n.flow->>'snaptrade_id' = rows.flow->>'snaptrade_id')
  ), unsourced as (
    select *, row_number() over (partition by details order by position) as instance
    from new_entries where not (flow ? 'snaptrade_id')
  )
  select coalesce(jsonb_agg(
    case when n.flow ? 'snaptrade_id' then
      case when not (n.flow ? 'fx') and exact.flow ? 'fx' then n.flow || jsonb_build_object('fx', exact.flow->'fx')
        else n.flow end
    when o.flow ? 'snaptrade_id' then o.flow || n.flow
    else n.flow end order by n.position), '[]'::jsonb)
  into new.external_flows
  from new_entries n left join unsourced u on u.position = n.position
  left join old_entries o on o.details = u.details and o.instance = u.instance
  left join lateral (
    select prior.flow
    from jsonb_array_elements(old.external_flows) prior(flow)
    where prior.flow->>'snaptrade_id' = n.flow->>'snaptrade_id'
      and prior.flow - array['snaptrade_id','fx'] = n.details
    limit 1
  ) exact on true;
  return new;
end;
$$;
