-- Upkeep for the agent scheduler (supabase/functions/agent-scheduler).
--
-- 1. A day-long cache of each coin's market-wide traded value. Alpaca's crypto bars count
--    one venue, so the liquidity check needs CoinGecko's 24-hour volume; the phone keeps
--    that figure for a day, and so does the server. Without a cache every scheduler run
--    would ask CoinGecko again, and its public limit is about five calls a minute.
--    Market data only: no person's data, nothing secret. Still, nobody signed in can read
--    or write it; only the edge functions (service role) use it.
-- 2. An index so the scheduler can prune idempotency keys older than 30 days cheaply.

create table if not exists public.trading_volume_cache (
  instrument_id  text primary key check (char_length(instrument_id) between 3 and 64),
  -- US dollars traded across the whole market in the last 24 hours. Only a real, positive
  -- figure is ever stored: unknown stays unknown (no row).
  dollar_volume  double precision not null
                 check (dollar_volume > 0 and dollar_volume < 'Infinity'::double precision),
  source         text not null check (char_length(source) between 1 and 64),
  fetched_at     timestamptz not null
);

alter table public.trading_volume_cache enable row level security;
revoke all on table public.trading_volume_cache from public, anon, authenticated;
grant select, insert, update, delete on table public.trading_volume_cache to service_role;

create index if not exists trading_idempotency_keys_created_at_idx
  on public.trading_idempotency_keys (created_at);
