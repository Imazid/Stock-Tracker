-- Keep one copy of each broker-sourced transfer per performance period.
create function portfolio_metrics.valid_flow_sources(flows jsonb)
returns boolean language sql immutable strict security invoker set search_path = '' as $$
  select coalesce(bool_and(jsonb_typeof(flow->'snaptrade_id') = 'string'
    and (flow->>'snaptrade_id') ~ '^[a-f0-9]{64}$'), true)
    and count(*) = count(distinct flow->>'snaptrade_id')
  from jsonb_array_elements(case when jsonb_typeof(flows) = 'array' then flows else '[]'::jsonb end) flow
  where flow ? 'snaptrade_id';
$$;
revoke all on function portfolio_metrics.valid_flow_sources(jsonb) from public, anon;
grant execute on function portfolio_metrics.valid_flow_sources(jsonb) to authenticated, service_role;

alter table public.portfolio_performance_periods add constraint performance_flow_sources
  check (portfolio_metrics.valid_flow_sources(external_flows));

-- Older clients only round-trip date, kind and amount. Keep the source on
-- matching transfers, with each older entry used at most once.
create function portfolio_metrics.preserve_flow_sources()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if jsonb_typeof(new.external_flows) <> 'array' then return new; end if;
  with new_entries as (
    select flow, position, flow - 'snaptrade_id' as details
    from jsonb_array_elements(new.external_flows) with ordinality rows(flow, position)
  ), old_entries as (
    select flow->'snaptrade_id' as source, flow - 'snaptrade_id' as details,
      row_number() over (partition by flow - 'snaptrade_id' order by position) as instance
    from jsonb_array_elements(old.external_flows) with ordinality rows(flow, position)
    where not exists (select 1 from new_entries n where n.flow->>'snaptrade_id' = rows.flow->>'snaptrade_id')
  ), unsourced as (
    select *, row_number() over (partition by details order by position) as instance
    from new_entries where not (flow ? 'snaptrade_id')
  )
  select coalesce(jsonb_agg(case when o.source is null then n.flow
    else n.flow || jsonb_build_object('snaptrade_id', o.source) end order by n.position), '[]'::jsonb)
  into new.external_flows
  from new_entries n left join unsourced u on u.position = n.position
  left join old_entries o on o.details = u.details and o.instance = u.instance;
  return new;
end;
$$;
revoke all on function portfolio_metrics.preserve_flow_sources() from public, anon, authenticated;
create trigger preserve_flow_sources
before update of external_flows on public.portfolio_performance_periods
for each row when (old.external_flows is distinct from new.external_flows)
execute function portfolio_metrics.preserve_flow_sources();
