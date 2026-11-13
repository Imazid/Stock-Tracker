create schema portfolio_metrics;
revoke all on schema portfolio_metrics from public, anon, authenticated;
grant usage on schema portfolio_metrics to authenticated, service_role;

-- Daily end-of-day portfolio valuations immediately after all external transfers on that date.
alter table public.portfolio_performance_periods
  add column transfer_values_usd jsonb not null default '{}'::jsonb;

create function portfolio_metrics.valid_transfer_values(values_by_date jsonb, flows jsonb, starts_on date, ends_on date)
returns boolean language plpgsql immutable strict security invoker set search_path = '' as $$
declare
  entry record;
  valuation_date date;
  amount numeric;
begin
  if jsonb_typeof(values_by_date) <> 'object' then return false; end if;
  for entry in select * from jsonb_each(values_by_date) loop
    if entry.key !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(entry.value) <> 'number' then return false; end if;
    valuation_date := entry.key::date;
    amount := (entry.value #>> '{}')::numeric;
    if valuation_date <= starts_on or valuation_date >= ends_on
      or amount < 0 or amount > 9999999999999.99 or amount <> round(amount, 2)
      or not exists (select 1 from jsonb_array_elements(flows) f where f->>'date' = entry.key)
    then return false; end if;
  end loop;
  return true;
exception when invalid_datetime_format or datetime_field_overflow or invalid_parameter_value then return false;
end;
$$;
revoke all on function portfolio_metrics.valid_transfer_values(jsonb, jsonb, date, date) from public, anon;
grant execute on function portfolio_metrics.valid_transfer_values(jsonb, jsonb, date, date) to authenticated, service_role;

alter table public.portfolio_performance_periods add constraint performance_transfer_values
  check (portfolio_metrics.valid_transfer_values(transfer_values_usd, external_flows, starts_on, ends_on));

-- Older clients update cash flows without sending transfer valuations.
-- Preserve values for surviving dates and remove values whose transfer date was removed.
create function portfolio_metrics.prune_transfer_values()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if jsonb_typeof(new.external_flows) <> 'array' then return new; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into new.transfer_values_usd
  from jsonb_each(new.transfer_values_usd)
  where key between to_char(new.starts_on + 1, 'YYYY-MM-DD') and to_char(new.ends_on - 1, 'YYYY-MM-DD')
    and exists (select 1 from jsonb_array_elements(new.external_flows) f where f->>'date' = key);
  return new;
end;
$$;
revoke all on function portfolio_metrics.prune_transfer_values() from public, anon, authenticated;
create trigger prune_transfer_values
before update of external_flows, starts_on, ends_on on public.portfolio_performance_periods
for each row
when (new.transfer_values_usd = old.transfer_values_usd and new.transfer_values_usd <> '{}'::jsonb
  and (new.external_flows is distinct from old.external_flows
    or new.starts_on is distinct from old.starts_on or new.ends_on is distinct from old.ends_on))
execute function portfolio_metrics.prune_transfer_values();

create function portfolio_metrics.time_weighted_growth(
  ends_on date, opening_value numeric, closing_value numeric, flows jsonb, values_by_date jsonb
) returns table (factor numeric, invested boolean)
language plpgsql immutable strict security invoker set search_path = '' as $$
declare
  previous_value numeric := opening_value;
  pre_transfer_value numeric;
  boundary record;
begin
  factor := 1;
  invested := false;
  for boundary in
    with daily_flows as (
      select (f->>'date')::date as day,
        sum((f->>'amount')::numeric * case when f->>'kind' = 'deposit' then 1 else -1 end) as net
      from jsonb_array_elements(flows) f group by 1
    )
    select day, net, (values_by_date->>to_char(day, 'YYYY-MM-DD'))::numeric as value
    from daily_flows where day < ends_on
    union all
    select ends_on, coalesce((select net from daily_flows where day = ends_on), 0), closing_value
    order by 1
  loop
    pre_transfer_value := boundary.value - boundary.net;
    if pre_transfer_value is null or pre_transfer_value < 0 then return; end if;
    if previous_value > 0 then
      invested := true;
      factor := factor * (pre_transfer_value / previous_value);
    elsif pre_transfer_value > 0 then
      return;
    end if;
    previous_value := boundary.value;
  end loop;
  return next;
end;
$$;
revoke all on function portfolio_metrics.time_weighted_growth(date, numeric, numeric, jsonb, jsonb) from public, anon;
grant execute on function portfolio_metrics.time_weighted_growth(date, numeric, numeric, jsonb, jsonb) to authenticated, service_role;

-- Solve the dated investor cash flows in log space for the cumulative period return.
-- The scale factor keeps exponentials bounded without changing the sign of the NPV.
create function portfolio_metrics.net_present_value(amounts double precision[], weights double precision[], log_rate double precision)
returns double precision language sql immutable strict security invoker set search_path = '' as $$
  select sum(amount * exp(-log_rate * weight + least(log_rate, 0::double precision)))
  from unnest(amounts, weights) cash(amount, weight);
$$;
revoke all on function portfolio_metrics.net_present_value(double precision[], double precision[], double precision) from public, anon;
grant execute on function portfolio_metrics.net_present_value(double precision[], double precision[], double precision) to authenticated, service_role;

create function portfolio_metrics.money_weighted_return(
  starts_on date, ends_on date, opening_value numeric, closing_value numeric, flows jsonb
) returns numeric language plpgsql immutable strict security invoker set search_path = '' as $$
declare
  amounts double precision[];
  weights double precision[];
  sign_changes integer;
  left_rate double precision := -60;
  right_rate double precision := 60;
  left_npv double precision;
  right_npv double precision;
  mid_rate double precision;
  mid_npv double precision;
  prefix_lower double precision := 0;
  prefix_upper double precision := 0;
  prefix_size double precision := 0;
  positive_prefixes boolean := true;
  negative_prefixes boolean := true;
  at_left double precision;
  at_right double precision;
  coefficient double precision;
  period_return numeric;
  days integer := ends_on - starts_on;
begin
  if days <= 0 then return null; end if;
  with cash as (
    select starts_on as day, -opening_value as amount
    union all select ends_on, closing_value
    union all select (f->>'date')::date,
      (f->>'amount')::numeric * case when f->>'kind' = 'deposit' then -1 else 1 end
      from jsonb_array_elements(flows) f
  ), daily as (
    select day, sum(amount) as amount from cash group by day having sum(amount) <> 0
  ), signs as (
    select *, lag(sign(amount)) over (order by day) as previous_sign from daily
  )
  select array_agg(amount::double precision order by day),
    array_agg((day - starts_on)::double precision / days order by day),
    count(*) filter (where sign(amount) <> previous_sign)
  into amounts, weights, sign_changes from signs;

  if sign_changes = 0 then return null; end if;
  left_npv := portfolio_metrics.net_present_value(amounts, weights, left_rate);
  right_npv := portfolio_metrics.net_present_value(amounts, weights, right_rate);
  if sign(left_npv) = sign(right_npv) then return null; end if;
  for iteration in 1..62 loop
    mid_rate := (left_rate + right_rate) / 2;
    mid_npv := portfolio_metrics.net_present_value(amounts, weights, mid_rate);
    if mid_npv = 0 then
      left_rate := mid_rate;
      right_rate := mid_rate;
      exit;
    elsif sign(mid_npv) = sign(left_npv) then
      left_rate := mid_rate;
    else
      right_rate := mid_rate;
    end if;
    exit when right_rate - left_rate < 1e-13;
  end loop;

  if sign_changes > 1 then
    -- At a root, the coefficients after dividing the dated cash-flow polynomial
    -- by its linear root factor have the opposite sign of the discounted prefixes.
    -- A single sign across all prefixes certifies there is no other positive root.
    -- Bound each prefix over the final bracket to avoid certifying near-zero signs.
    for i in 1..cardinality(amounts) - 1 loop
      coefficient := amounts[i];
      at_left := coefficient * exp(-left_rate * weights[i]);
      at_right := coefficient * exp(-right_rate * weights[i]);
      prefix_lower := prefix_lower + least(at_left, at_right);
      prefix_upper := prefix_upper + greatest(at_left, at_right);
      prefix_size := prefix_size + greatest(abs(at_left), abs(at_right));
      positive_prefixes := positive_prefixes and prefix_lower > prefix_size * 1e-10;
      negative_prefixes := negative_prefixes and prefix_upper < -prefix_size * 1e-10;
    end loop;
    if not (positive_prefixes or negative_prefixes) then return null; end if;
  end if;

  period_return := 100 * (exp(((left_rate + right_rate) / 2)::numeric) - 1);
  return round(period_return, 8);
end;
$$;
revoke all on function portfolio_metrics.money_weighted_return(date, date, numeric, numeric, jsonb) from public, anon;
grant execute on function portfolio_metrics.money_weighted_return(date, date, numeric, numeric, jsonb) to authenticated, service_role;

create or replace view public.portfolio_performance_results with (security_invoker = true) as
select p.id, p.user_id, p.starts_on, p.ends_on, p.opening_value_usd, p.closing_value_usd, p.external_flows,
  flows.deposits_usd, flows.withdrawals_usd,
  p.closing_value_usd - p.opening_value_usd - flows.net_usd as investment_change_usd,
  case when p.opening_value_usd + flows.weighted_usd > 0 then
    round(100 * (p.closing_value_usd - p.opening_value_usd - flows.net_usd)
      / (p.opening_value_usd + flows.weighted_usd), 8)
  end as return_pct,
  p.transfer_values_usd,
  case when methods.invested then round(100 * (methods.factor - 1), 8) end as time_weighted_return_pct,
  portfolio_metrics.money_weighted_return(p.starts_on, p.ends_on, p.opening_value_usd, p.closing_value_usd, p.external_flows) as money_weighted_return_pct,
  methods.factor as twr_factor,
  methods.invested as twr_invested
from public.portfolio_performance_periods p
left join lateral portfolio_metrics.time_weighted_growth(p.ends_on, p.opening_value_usd, p.closing_value_usd,
  p.external_flows, p.transfer_values_usd) methods on true
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
create or replace view public.portfolio_performance_summary with (security_invoker = true) as
with boundaries as (
  select r.id, r.user_id, r.starts_on, r.ends_on, r.opening_value_usd, r.closing_value_usd, r.external_flows,
    r.deposits_usd, r.withdrawals_usd, r.investment_change_usd, r.return_pct, r.twr_factor, r.twr_invested,
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
select totals.*,
  portfolio_metrics.money_weighted_return(totals.starts_on, totals.ends_on, first.opening_value_usd, last.closing_value_usd,
    coalesce(flows.entries, '[]'::jsonb)) as money_weighted_return_pct
from (
  select user_id, min(starts_on) as starts_on, max(ends_on) as ends_on,
    count(*) as periods, sum(deposits_usd) as deposits_usd, sum(withdrawals_usd) as withdrawals_usd,
    sum(investment_change_usd) as investment_change_usd,
    case when count(return_pct) <> count(*) or bool_or(return_pct < -100) then null
      when bool_or(return_pct = -100) then -100::numeric
      else round(100 * (exp(sum(ln(nullif(greatest(0, 1 + return_pct / 100), 0)))) - 1), 8)
    end as return_pct,
    case when count(twr_factor) <> count(*) or not bool_or(twr_invested) then null
      when bool_or(twr_factor = 0) then -100::numeric
      else round(100 * (exp(sum(ln(nullif(twr_factor, 0)))) - 1), 8)
    end as time_weighted_return_pct
  from chains where chain = 0 group by user_id
) totals
join public.portfolio_performance_periods first on first.user_id = totals.user_id and first.starts_on = totals.starts_on
join public.portfolio_performance_periods last on last.user_id = totals.user_id and last.ends_on = totals.ends_on
cross join lateral (
  select jsonb_agg(f.value) as entries
  from public.portfolio_performance_periods p cross join lateral jsonb_array_elements(p.external_flows) f
  where p.user_id = totals.user_id and p.starts_on >= totals.starts_on and p.ends_on <= totals.ends_on
) flows;

revoke all on public.portfolio_performance_summary from public, anon, authenticated;
grant select on public.portfolio_performance_summary to authenticated, service_role;
