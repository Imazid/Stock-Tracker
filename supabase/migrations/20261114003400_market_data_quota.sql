create table public.market_data_usage (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_start timestamptz not null,
  request_count integer not null check (request_count between 1 and 120)
);

alter table public.market_data_usage enable row level security;
revoke all on table public.market_data_usage from public, anon, authenticated;
grant select, insert, update on table public.market_data_usage to service_role;

create function public.consume_market_data_quota(p_user_id uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare
  current_window timestamptz := date_trunc('minute', statement_timestamp());
begin
  insert into public.market_data_usage as usage (user_id, window_start, request_count)
  values (p_user_id, current_window, 1)
  on conflict (user_id) do update
  set window_start = greatest(usage.window_start, excluded.window_start),
      request_count = case when usage.window_start < excluded.window_start then 1
                           else usage.request_count + 1 end
  where usage.window_start < excluded.window_start or usage.request_count < 120;
  return found;
end;
$$;
revoke all on function public.consume_market_data_quota(uuid) from public, anon, authenticated;
grant execute on function public.consume_market_data_quota(uuid) to service_role;
