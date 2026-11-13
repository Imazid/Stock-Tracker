-- Support for trading-api's `state` read, which hands the app a person's whole trading
-- state with bounded history (the newest N runs, signals, proposals, orders, fills and
-- audit events, in the order they happened).
--
-- 1. Agent runs get the insertion-order column the other history tables already have, so
--    runs recorded in the same instant still come back in the order they were written.
-- 2. Indexes for "the newest N rows of this person's history".

alter table public.agent_runs add column if not exists seq bigint generated always as identity;

create index if not exists agent_runs_user_seq_idx on public.agent_runs (user_id, seq desc);
create index if not exists trading_signals_user_seq_idx on public.trading_signals (user_id, seq desc);
create index if not exists trade_proposals_user_seq_idx on public.trade_proposals (user_id, seq desc);
create index if not exists orders_user_seq_idx on public.orders (user_id, seq desc);
create index if not exists order_fills_user_seq_idx on public.order_fills (user_id, seq desc);
create index if not exists agent_strategy_versions_agent_idx on public.agent_strategy_versions (agent_id, version);
