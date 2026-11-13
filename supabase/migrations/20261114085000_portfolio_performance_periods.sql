-- Valuations and dated external flows reconciled against one consistent portfolio scope.
-- The holdings-only iPhone snapshots have no cash-flow coverage and stay independent.
create extension if not exists btree_gist with schema extensions;

create function public.valid_performance_flows(flows jsonb, starts_on date, ends_on date)
returns boolean language plpgsql immutable strict security invoker set search_path = '' as $$
declare
  flow jsonb;
  flow_date date;
  amount numeric;
begin
  if jsonb_typeof(flows) <> 'array' or jsonb_array_length(flows) > 366 then return false; end if;
  for flow in select value from jsonb_array_elements(flows) loop
    if jsonb_typeof(flow) <> 'object'
      or not (flow ?& array['date', 'kind', 'amount'])
      or jsonb_typeof(flow->'date') <> 'string'
      or jsonb_typeof(flow->'kind') <> 'string'
      or jsonb_typeof(flow->'amount') <> 'number'
      or (flow->>'date') !~ '^\d{4}-\d{2}-\d{2}$'
      or (flow->>'kind') not in ('deposit', 'withdrawal') then return false;
    end if;
    flow_date := (flow->>'date')::date;
    amount := (flow->>'amount')::numeric;
    if flow_date <= starts_on or flow_date > ends_on
      or amount <= 0 or amount > 9999999999999.99 or amount <> round(amount, 2) then return false;
    end if;
  end loop;
  return true;
exception when invalid_datetime_format or datetime_field_overflow then return false;
end;
$$;
revoke all on function public.valid_performance_flows(jsonb, date, date) from public, anon;
grant execute on function public.valid_performance_flows(jsonb, date, date) to authenticated, service_role;

create table public.portfolio_performance_periods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  starts_on date not null,
  ends_on date not null,
  opening_value_usd numeric(15,2) not null check (opening_value_usd between 0 and 9999999999999.99),
  closing_value_usd numeric(15,2) not null check (closing_value_usd between 0 and 9999999999999.99),
  external_flows jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  constraint performance_dates check (starts_on >= date '1900-01-01' and starts_on < ends_on and ends_on <= date '9999-12-31'),
  constraint performance_flows check (public.valid_performance_flows(external_flows, starts_on, ends_on)),
  constraint performance_no_overlap exclude using gist (user_id with =, daterange(starts_on, ends_on, '[)') with &&)
);
create index portfolio_performance_user_end_idx on public.portfolio_performance_periods (user_id, ends_on desc);

create trigger portfolio_performance_touch before update on public.portfolio_performance_periods
  for each row execute function public.touch_updated_at();

alter table public.portfolio_performance_periods enable row level security;
revoke all on public.portfolio_performance_periods from public, anon, authenticated;
grant select, insert, update, delete on public.portfolio_performance_periods to authenticated;
grant all on public.portfolio_performance_periods to service_role;
create policy portfolio_performance_owner on public.portfolio_performance_periods
  for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Modified Dietz uses end-of-day flow weights. Adjacent periods can share a valuation date.
create view public.portfolio_performance_results with (security_invoker = true) as
select p.id, p.user_id, p.starts_on, p.ends_on, p.opening_value_usd, p.closing_value_usd, p.external_flows,
  flows.deposits_usd, flows.withdrawals_usd,
  p.closing_value_usd - p.opening_value_usd - flows.net_usd as investment_change_usd,
  case when p.opening_value_usd + flows.weighted_usd > 0 then
    round(100 * (p.closing_value_usd - p.opening_value_usd - flows.net_usd)
      / (p.opening_value_usd + flows.weighted_usd), 8)
  end as return_pct
from public.portfolio_performance_periods p
cross join lateral (
  select coalesce(sum(amount) filter (where kind = 'deposit'), 0) as deposits_usd,
    coalesce(sum(-amount) filter (where kind = 'withdrawal'), 0) as withdrawals_usd,
    coalesce(sum(amount), 0) as net_usd,
    coalesce(sum(amount * (p.ends_on - flow_date)), 0) / (p.ends_on - p.starts_on) as weighted_usd
  from (
    select (value->>'date')::date as flow_date, value->>'kind' as kind,
      (value->>'amount')::numeric * case when value->>'kind' = 'deposit' then 1 else -1 end as amount
    from jsonb_array_elements(p.external_flows)
  ) entries
) flows;
revoke all on public.portfolio_performance_results from public, anon, authenticated;
grant select on public.portfolio_performance_results to authenticated, service_role;

-- Return only the latest continuous chain. A gap or a different valuation for the
-- shared boundary starts a new chain so no unrecorded interval affects the result.
create view public.portfolio_performance_summary with (security_invoker = true) as
with boundaries as (
  select r.*,
    lag(starts_on) over chronological as next_start,
    lag(opening_value_usd) over chronological as next_opening
  from public.portfolio_performance_results r
  window chronological as (partition by user_id order by ends_on desc)
), chains as (
  select boundaries.*,
    sum(case when next_start is not null and (next_start <> ends_on or next_opening <> closing_value_usd)
      then 1 else 0 end) over (partition by user_id order by ends_on desc) as chain
  from boundaries
)
select user_id, min(starts_on) as starts_on, max(ends_on) as ends_on,
  count(*) as periods, sum(deposits_usd) as deposits_usd, sum(withdrawals_usd) as withdrawals_usd,
  sum(investment_change_usd) as investment_change_usd,
  case when count(return_pct) <> count(*) or bool_or(return_pct < -100) then null
    when bool_or(return_pct = -100) then -100::numeric
    else round(100 * (exp(sum(ln(nullif(greatest(0, 1 + return_pct / 100), 0)))) - 1), 8)
  end as return_pct
from chains where chain = 0 group by user_id;

revoke all on public.portfolio_performance_summary from public, anon, authenticated;
grant select on public.portfolio_performance_summary to authenticated, service_role;
