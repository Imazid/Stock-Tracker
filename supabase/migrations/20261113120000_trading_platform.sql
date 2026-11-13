-- Stock Tracker — paper trading and agents (server side).
--
-- The trading rules live in code (TradingCore in Swift on the phone; the same engine in
-- TypeScript under supabase/functions/_shared/trading on the server). This file is the
-- database those rules write to, and the part of the rules that must hold even if the
-- code above it is wrong or bypassed:
--
--   * Only paper (simulated) trading exists. A row marked live is refused in orders,
--     proposals, fills, accounts and agents unless the owner's live flag is on — and a
--     CHECK constraint keeps every live flag off in this build.
--   * Clients can read their own rows and write nothing. Every write comes from the edge
--     functions (trading-api, agent-scheduler), which run the validator and the risk
--     engine first. The `authenticated` role has SELECT only.
--   * Orders follow one state machine (OrderStatus.canTransition in Orders.swift), are
--     idempotent per user (client_order_id) and a proposal maps to at most one order.
--   * No leverage, margin or short selling: positions and paper cash can't go negative.
--   * The audit trail is append-only and hash-chained here, by trigger, with the same
--     canonical text as AuditEvent.canonical in Audit.swift. No UPDATE, no DELETE.
--   * The kill switch stops agent orders in the database too, whatever the caller sends.
--
-- Money is in the account's currency (USD or AUD). Numbers are double precision because
-- the engine works in doubles and rounds to the cent itself; a stored value reads back as
-- exactly the number the engine wrote. Nested structures the phone decodes with its own
-- types (strategy, risk report, evidence, run steps, instrument) are jsonb in the shape
-- Swift's Codable writes (camelCase keys, dates as milliseconds since 1970).
--
-- Not in the brief's list by name: `trading_portfolio_snapshots` (the brief says
-- `portfolio_snapshots`, which already exists for the app's own daily totals — see
-- 20261017000000_stocktracker_schema.sql) and `trading_idempotency_keys` (so a retried
-- API call returns its first answer instead of acting twice).

-- =============================================================================
-- Account-level policy: the kill switch and the live-trading flags
-- =============================================================================
create table if not exists public.risk_policies (
  user_id                         uuid primary key references auth.users(id) on delete cascade,
  kill_switch_engaged             boolean not null default false,
  kill_switch_at                  timestamptz,
  max_symbol_exposure_pct         double precision not null default 35
                                  check (max_symbol_exposure_pct > 0 and max_symbol_exposure_pct <= 100),
  max_total_daily_notional        double precision not null default 250000 check (max_total_daily_notional > 0),
  live_manual_orders_enabled      boolean not null default false,
  live_approval_agents_enabled    boolean not null default false,
  live_autonomous_agents_enabled  boolean not null default false,
  created_at                      timestamptz not null default now(),
  updated_at                      timestamptz not null default now(),
  -- Real-money trading does not exist in this build. Turning any of these on takes a
  -- migration that drops this constraint — a deliberate, reviewable change — not an UPDATE.
  constraint live_trading_not_available_in_this_build
    check (not live_manual_orders_enabled and not live_approval_agents_enabled and not live_autonomous_agents_enabled),
  constraint risk_policies_kill_switch_time
    check (kill_switch_engaged or kill_switch_at is null)
);

-- =============================================================================
-- Broker connections (described, never trusted with more than they were granted)
-- =============================================================================
-- There is deliberately no credentials column: nothing here can hold a key or a token.
create table if not exists public.broker_connections (
  id           uuid primary key default gen_random_uuid(),
  seq          bigint generated always as identity,
  user_id      uuid not null references auth.users(id) on delete cascade,
  adapter_id   text not null check (char_length(adapter_id) between 1 and 64),
  name         text not null check (char_length(name) between 1 and 80),
  environment  text not null check (environment in ('paper', 'sandbox', 'live')),
  permissions  text[] not null default array['read']::text[]
               check (permissions <@ array['read', 'trade']::text[]),
  created_at   timestamptz not null default now(),
  -- A read-only connection is never permission to trade, and no live connection can be
  -- given trade permission in this build.
  constraint broker_connections_no_live_trade_in_this_build
    check (environment <> 'live' or not ('trade' = any (permissions)))
);
create index if not exists broker_connections_user_idx on public.broker_connections (user_id);

-- =============================================================================
-- Trading accounts (the ledger: one paper portfolio, or one agent's budget)
-- =============================================================================
create table if not exists public.trading_accounts (
  id                uuid primary key,
  seq               bigint generated always as identity,    -- insertion order, as the engine keeps its lists
  user_id           uuid not null references auth.users(id) on delete cascade,
  name              text not null check (char_length(name) between 1 and 80),
  kind              text not null check (kind in ('manualPaper', 'agentPaper')),
  mode              text not null default 'paper' check (mode in ('paper', 'live')),
  -- Currencies.supported in the core. A book holds one currency and is never converted.
  currency          text not null check (currency in ('USD', 'AUD', 'GBP', 'EUR', 'CHF', 'JPY', 'HKD', 'SGD', 'KRW', 'INR')),
  agent_id          uuid,                                   -- the agent that owns an agentPaper book
  starting_cash     double precision not null check (starting_cash >= 0),
  cash              double precision not null,
  realized_pnl      double precision not null default 0,
  fees_paid         double precision not null default 0 check (fees_paid >= 0),
  peak_equity       double precision not null check (peak_equity >= 0),
  day_key           text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  day_start_equity  double precision not null,
  realized_today    double precision not null default 0,
  notional_today    double precision not null default 0 check (notional_today >= 0),
  last_fill_at      jsonb not null default '{}'::jsonb check (jsonb_typeof(last_fill_at) = 'object'),
  last_buy_at       jsonb not null default '{}'::jsonb check (jsonb_typeof(last_buy_at) = 'object'),
  last_exit_at      jsonb not null default '{}'::jsonb check (jsonb_typeof(last_exit_at) = 'object'),
  created_at        timestamptz not null,                   -- when the book started (or was last reset)
  marked_at         timestamptz,                            -- when positions were last priced
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,                            -- history is kept; a deleted book just stops showing
  unique (id, user_id),
  -- No margin and no borrowing: paper cash can't go below zero.
  constraint trading_accounts_cash_not_negative check (mode <> 'paper' or cash >= 0)
);
create index if not exists trading_accounts_user_idx on public.trading_accounts (user_id, created_at desc) where deleted_at is null;
create index if not exists trading_accounts_mark_idx on public.trading_accounts (marked_at nulls first) where deleted_at is null;

create table if not exists public.positions (
  id               uuid primary key default gen_random_uuid(),
  seq              bigint generated always as identity,      -- opening order, as the engine keeps it
  user_id          uuid not null references auth.users(id) on delete cascade,
  ledger_id        uuid not null,
  instrument_id    text not null,
  instrument       jsonb not null,
  -- No short selling: a holding can't go below zero.
  quantity         double precision not null check (quantity >= 0),
  cost_basis       double precision not null check (cost_basis >= 0),
  opened_at        timestamptz not null,
  last_price       double precision not null check (last_price >= 0),
  last_price_time  timestamptz,
  updated_at       timestamptz not null default now(),
  unique (ledger_id, instrument_id),
  foreign key (ledger_id, user_id) references public.trading_accounts (id, user_id) on delete cascade,
  constraint positions_instrument_shape
    check (instrument_id = (instrument ->> 'venue') || ':' || (instrument ->> 'symbol'))
);
create index if not exists positions_user_idx on public.positions (user_id);

-- Equity over time for one book (the brief's `portfolio_snapshots`).
create table if not exists public.trading_portfolio_snapshots (
  id         uuid primary key default gen_random_uuid(),
  seq        bigint generated always as identity,
  user_id    uuid not null references auth.users(id) on delete cascade,
  ledger_id  uuid not null,
  time       timestamptz not null,
  equity     double precision not null,
  cash       double precision not null,
  foreign key (ledger_id, user_id) references public.trading_accounts (id, user_id) on delete cascade
);
create index if not exists trading_portfolio_snapshots_ledger_idx on public.trading_portfolio_snapshots (ledger_id, time desc);
create index if not exists trading_portfolio_snapshots_user_idx on public.trading_portfolio_snapshots (user_id, time desc);

-- =============================================================================
-- Agents and their strategies
-- =============================================================================
create table if not exists public.trading_agents (
  id                         uuid primary key,
  seq                        bigint generated always as identity,
  user_id                    uuid not null references auth.users(id) on delete cascade,
  name                       text not null check (char_length(name) between 1 and 80),
  template_id                text,
  mode                       text not null check (mode in ('researchOnly', 'signals', 'paper', 'approvalRequired', 'autonomousLive')),
  status                     text not null default 'active' check (status in ('active', 'paused', 'stopped')),
  pause_reason               text check (pause_reason in ('user', 'killSwitch', 'dailyLossLimit', 'drawdownLimit', 'repeatedErrors')),
  risk_policy                jsonb not null check (jsonb_typeof(risk_policy) = 'object'),
  ledger_id                  uuid,
  budget                     double precision not null check (budget >= 0),
  review_each_paper_trade    boolean not null default false,
  schedule_interval_minutes  integer not null check (schedule_interval_minutes between 5 and 10080),
  strategy_version           integer not null default 1 check (strategy_version >= 1),
  created_at                 timestamptz not null,
  last_run_at                timestamptz,
  next_run_at                timestamptz,
  consecutive_errors         integer not null default 0 check (consecutive_errors >= 0),
  last_error                 text,
  daily_loss_notified_day    text,                           -- so the daily-loss notice goes out once a day
  locked_until               timestamptz,                    -- scheduler lease (see claim_due_agents)
  locked_by                  uuid,
  updated_at                 timestamptz not null default now(),
  deleted_at                 timestamptz,
  unique (id, user_id),
  foreign key (ledger_id, user_id) references public.trading_accounts (id, user_id)
);
create index if not exists trading_agents_user_idx on public.trading_agents (user_id, created_at desc) where deleted_at is null;
create index if not exists trading_agents_due_idx on public.trading_agents (next_run_at nulls first)
  where deleted_at is null and status = 'active';

-- One row per saved version of an agent's strategy. Versions are only ever added, so
-- every signal and trade can name the exact rules that produced it.
create table if not exists public.agent_strategy_versions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  agent_id    uuid not null,
  version     integer not null check (version >= 1),
  spec        jsonb not null check (jsonb_typeof(spec) = 'object'),
  note        text not null default '',
  author      text not null check (author in ('user', 'copilot', 'template')),
  created_at  timestamptz not null,
  unique (agent_id, version),
  foreign key (agent_id, user_id) references public.trading_agents (id, user_id) on delete cascade
);
create index if not exists agent_strategy_versions_user_idx on public.agent_strategy_versions (user_id);

create table if not exists public.agent_runs (
  id                uuid primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  agent_id          uuid not null,
  strategy_version  integer not null,
  trigger           text not null check (trigger in ('schedule', 'manual')),
  started_at        timestamptz not null,
  finished_at       timestamptz not null,
  status            text not null check (status in ('completed', 'skipped', 'failed')),
  summary           text not null default '',
  steps             jsonb not null default '[]'::jsonb check (jsonb_typeof(steps) = 'array'),
  signal_ids        uuid[] not null default '{}',
  proposal_ids      uuid[] not null default '{}',
  order_ids         uuid[] not null default '{}',
  created_at        timestamptz not null default now(),
  foreign key (agent_id, user_id) references public.trading_agents (id, user_id) on delete cascade
);
create index if not exists agent_runs_agent_idx on public.agent_runs (agent_id, started_at desc);
create index if not exists agent_runs_user_idx on public.agent_runs (user_id, started_at desc);

create table if not exists public.trading_signals (
  id                uuid primary key,
  seq               bigint generated always as identity,
  user_id           uuid not null references auth.users(id) on delete cascade,
  agent_id          uuid not null,
  strategy_version  integer not null,
  instrument_id     text not null,
  instrument        jsonb not null,
  action            text not null check (action in ('buy', 'sell', 'hold')),
  headline          text not null,
  evidence          jsonb not null default '[]'::jsonb check (jsonb_typeof(evidence) = 'array'),
  bar_time          timestamptz not null,
  close             double precision not null check (close > 0),
  rule_margin       double precision,
  exit_reason       text check (exit_reason in ('rule', 'stopLoss', 'takeProfit', 'trailingStop', 'timeLimit', 'rebalance')),
  created_at        timestamptz not null,
  provenance        jsonb not null check (provenance ->> 'kind' in ('market', 'fixture')),   -- never synthetic
  -- One signal per bar per direction per version: re-running on the same bar can't repeat it.
  unique (agent_id, instrument_id, bar_time, action, strategy_version),
  foreign key (agent_id, user_id) references public.trading_agents (id, user_id) on delete cascade
);
create index if not exists trading_signals_user_idx on public.trading_signals (user_id, created_at desc);

-- =============================================================================
-- Proposals, orders and fills
-- =============================================================================
create table if not exists public.trade_proposals (
  id                uuid primary key,
  seq               bigint generated always as identity,
  user_id           uuid not null references auth.users(id) on delete cascade,
  agent_id          uuid not null,
  signal_id         uuid not null references public.trading_signals(id),
  strategy_version  integer not null,
  ledger_id         uuid not null,
  instrument_id     text not null,
  instrument        jsonb not null,
  side              text not null check (side in ('buy', 'sell')),
  quantity          double precision not null check (quantity > 0),
  reference_price   double precision not null check (reference_price > 0),
  notional          double precision not null check (notional >= 0),
  estimated_fee     double precision not null default 0 check (estimated_fee >= 0),
  mode              text not null default 'paper' check (mode in ('paper', 'live')),
  status            text not null check (status in ('pending', 'submitted', 'rejected', 'expired', 'blocked', 'failed')),
  risk              jsonb not null check (jsonb_typeof(risk) = 'object'),
  headline          text not null,
  sizing_note       text,
  signal_bar_time   timestamptz not null,
  created_at        timestamptz not null,
  expires_at        timestamptz not null,
  resolved_at       timestamptz,
  resolution_note   text,
  order_id          uuid,
  client_order_id   text not null,
  -- A proposal maps to at most one order, and an order to at most one proposal.
  unique (order_id),
  unique (user_id, client_order_id),
  foreign key (agent_id, user_id) references public.trading_agents (id, user_id) on delete cascade,
  foreign key (ledger_id, user_id) references public.trading_accounts (id, user_id) on delete cascade,
  constraint trade_proposals_resolution check ((status = 'pending') = (resolved_at is null)),
  constraint trade_proposals_order_only_when_executed check (order_id is null or status in ('submitted', 'failed'))
);
create index if not exists trade_proposals_user_idx on public.trade_proposals (user_id, created_at desc);
create index if not exists trade_proposals_pending_idx on public.trade_proposals (user_id, expires_at) where status = 'pending';
-- An agent can have only one waiting proposal per instrument and side.
create unique index if not exists trade_proposals_one_pending_idx
  on public.trade_proposals (agent_id, instrument_id, side) where status = 'pending';

create table if not exists public.orders (
  id                  uuid primary key,
  seq                 bigint generated always as identity,
  user_id             uuid not null references auth.users(id) on delete cascade,
  client_order_id     text not null check (char_length(client_order_id) between 1 and 128),
  ledger_id           uuid not null,
  instrument_id       text not null,
  instrument          jsonb not null,
  side                text not null check (side in ('buy', 'sell')),
  type                text not null check (type in ('market', 'limit', 'stop', 'stopLimit')),
  quantity            double precision not null,
  limit_price         double precision check (limit_price is null or limit_price > 0),
  stop_price          double precision check (stop_price is null or stop_price > 0),
  time_in_force       text not null check (time_in_force in ('day', 'gtc', 'ioc', 'fok')),
  source_kind         text not null check (source_kind in ('manual', 'agent')),
  agent_id            uuid,
  proposal_id         uuid references public.trade_proposals(id),
  mode                text not null default 'paper' check (mode in ('paper', 'live')),
  status              text not null check (status in ('pendingSubmit', 'accepted', 'partiallyFilled', 'filled', 'canceled', 'rejected', 'expired')),
  filled_quantity     double precision not null default 0,
  average_fill_price  double precision not null default 0 check (average_fill_price >= 0),
  fees                double precision not null default 0 check (fees >= 0),
  reference_price     double precision not null,
  created_at          timestamptz not null,
  updated_at          timestamptz not null,
  expires_at          timestamptz,
  stop_triggered_at   timestamptz,
  status_note         text,
  signal_bar_time     timestamptz,
  broker_order_id     text,                                   -- a venue's own id (live only; always null here)
  -- Idempotency: the same client order id is never accepted twice for one person.
  unique (user_id, client_order_id),
  unique (id, user_id),
  foreign key (ledger_id, user_id) references public.trading_accounts (id, user_id) on delete cascade,
  foreign key (agent_id, user_id) references public.trading_agents (id, user_id) on delete cascade,
  -- A refused order is still recorded, and what was refused may have had no size or price.
  constraint orders_quantity_positive check (quantity >= 0 and (quantity > 0 or status = 'rejected')),
  constraint orders_reference_price_positive check (reference_price >= 0 and (reference_price > 0 or status = 'rejected')),
  constraint orders_filled_within_quantity check (filled_quantity >= 0 and filled_quantity <= quantity),
  constraint orders_agent_source check ((source_kind = 'agent') = (agent_id is not null)),
  constraint orders_filled_means_filled check (status <> 'filled' or filled_quantity > 0),
  constraint orders_rejected_never_filled check (status <> 'rejected' or filled_quantity = 0)
);
create unique index if not exists orders_one_per_proposal_idx on public.orders (proposal_id) where proposal_id is not null;
create index if not exists orders_user_idx on public.orders (user_id, created_at desc);
create index if not exists orders_ledger_idx on public.orders (ledger_id, created_at desc);
create index if not exists orders_open_idx on public.orders (user_id, expires_at)
  where status in ('pendingSubmit', 'accepted', 'partiallyFilled');

alter table public.trade_proposals drop constraint if exists trade_proposals_order_fk;
alter table public.trade_proposals
  add constraint trade_proposals_order_fk foreign key (order_id) references public.orders(id) deferrable initially deferred;

-- Fills are facts: once written they are never changed or removed.
create table if not exists public.order_fills (
  id               uuid primary key,
  seq              bigint generated always as identity,
  user_id          uuid not null references auth.users(id) on delete cascade,
  order_id         uuid not null,
  fill_no          integer not null check (fill_no >= 1),
  ledger_id        uuid not null,
  instrument_id    text not null,
  instrument       jsonb not null,
  side             text not null check (side in ('buy', 'sell')),
  quantity         double precision not null check (quantity > 0),
  price            double precision not null check (price > 0),
  fee              double precision not null default 0 check (fee >= 0),
  time             timestamptz not null,
  source_kind      text not null check (source_kind in ('manual', 'agent')),
  agent_id         uuid,
  proposal_id      uuid,
  mode             text not null default 'paper' check (mode in ('paper', 'live')),
  realized_pnl     double precision,
  signal_bar_time  timestamptz,
  created_at       timestamptz not null default now(),
  -- A retried write can't book the same fill twice.
  unique (order_id, fill_no),
  foreign key (order_id, user_id) references public.orders (id, user_id) on delete cascade,
  foreign key (ledger_id, user_id) references public.trading_accounts (id, user_id) on delete cascade
);
create index if not exists order_fills_user_idx on public.order_fills (user_id, time desc);
create index if not exists order_fills_ledger_idx on public.order_fills (ledger_id, time desc);
create index if not exists order_fills_agent_signal_idx on public.order_fills (agent_id, signal_bar_time) where agent_id is not null;

-- =============================================================================
-- Things to tell the person about (the engine's notices), and the audit trail
-- =============================================================================
create table if not exists public.agent_events (
  id             uuid primary key default gen_random_uuid(),
  seq            bigint generated always as identity,
  user_id        uuid not null references auth.users(id) on delete cascade,
  kind           text not null check (kind in ('approvalNeeded', 'proposalBlocked', 'orderSubmitted', 'orderFilled',
                                               'orderPartiallyFilled', 'orderRejected', 'orderCanceled', 'agentPaused',
                                               'dailyLossReached', 'dataUnavailable')),
  title          text not null,
  body           text not null,
  mode           text not null default 'paper' check (mode in ('paper', 'live')),
  agent_id       uuid,
  order_id       uuid,
  proposal_id    uuid,
  instrument_id  text,
  created_at     timestamptz not null
);
create index if not exists agent_events_user_idx on public.agent_events (user_id, created_at desc, seq desc);

-- No foreign keys to the rows an event describes: history outlives them.
create table if not exists public.audit_events (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  sequence       bigint not null check (sequence >= 1),
  time           timestamptz not null,
  actor          text not null check (actor in ('user', 'agent', 'system', 'copilot')),
  kind           text not null check (kind in (
                   'portfolioCreated', 'portfolioReset', 'portfolioDeleted',
                   'agentCreated', 'agentRenamed', 'agentDeleted', 'agentPaused', 'agentResumed', 'agentStopped',
                   'strategyChanged', 'riskPolicyChanged', 'modeChanged', 'liveRequestRefused',
                   'killSwitchEngaged', 'killSwitchReleased', 'signalGenerated',
                   'proposalCreated', 'proposalBlocked', 'proposalApproved', 'proposalRejected', 'proposalExpired', 'proposalFailed',
                   'orderSubmitted', 'orderRejected', 'orderPartiallyFilled', 'orderFilled', 'orderCanceled', 'orderExpired',
                   'backtestRun')),
  summary        text not null,
  mode           text check (mode in ('paper', 'live')),
  agent_id       uuid,
  ledger_id      uuid,
  order_id       uuid,
  proposal_id    uuid,
  instrument_id  text,
  details        jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  previous_hash  text not null check (previous_hash ~ '^[0-9a-f]{64}$'),
  hash           text not null check (hash ~ '^[0-9a-f]{64}$'),
  created_at     timestamptz not null default now(),
  unique (user_id, sequence)
);
create index if not exists audit_events_user_time_idx on public.audit_events (user_id, time desc);

-- A retried API call returns its first answer instead of acting twice. Clients can't read this.
create table if not exists public.trading_idempotency_keys (
  user_id     uuid not null references auth.users(id) on delete cascade,
  key         text not null check (char_length(key) between 8 and 128),
  action      text not null,
  status      integer not null,
  response    jsonb not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, key)
);

-- =============================================================================
-- Guards
-- =============================================================================

-- Live rows are refused unless the owner's matching live flag is on. With the CHECK
-- constraint on risk_policies no flag can be on, so in this build every live row is refused.
create or replace function public.trading_live_flag(p_user uuid, p_source_kind text, p_agent uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_policy public.risk_policies%rowtype;
  v_mode text;
begin
  select * into v_policy from public.risk_policies where user_id = p_user;
  if not found then
    return false;
  end if;
  if p_source_kind = 'any' then
    return v_policy.live_manual_orders_enabled or v_policy.live_approval_agents_enabled or v_policy.live_autonomous_agents_enabled;
  end if;
  if p_source_kind = 'manual' then
    return v_policy.live_manual_orders_enabled;
  end if;
  select mode into v_mode from public.trading_agents where id = p_agent and user_id = p_user;
  if v_mode = 'approvalRequired' then
    return v_policy.live_approval_agents_enabled;
  elsif v_mode = 'autonomousLive' then
    return v_policy.live_autonomous_agents_enabled;
  end if;
  return false;
end $$;

create or replace function public.trading_guard_live() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_allowed boolean := false;
  v_order public.orders%rowtype;
begin
  if tg_table_name = 'trading_agents' then
    if new.mode = 'approvalRequired' then
      v_allowed := coalesce((select live_approval_agents_enabled from public.risk_policies where user_id = new.user_id), false);
    elsif new.mode = 'autonomousLive' then
      v_allowed := coalesce((select live_autonomous_agents_enabled from public.risk_policies where user_id = new.user_id), false);
    else
      return new;
    end if;
    if not v_allowed then
      raise exception 'live trading is not enabled: an agent cannot be put in % mode', new.mode using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.mode is distinct from 'live' then
    return new;
  end if;
  if tg_table_name = 'trading_accounts' then
    v_allowed := public.trading_live_flag(new.user_id, 'any', null);
  elsif tg_table_name = 'orders' then
    v_allowed := public.trading_live_flag(new.user_id, new.source_kind, new.agent_id);
  elsif tg_table_name = 'trade_proposals' then
    v_allowed := public.trading_live_flag(new.user_id, 'agent', new.agent_id);
  elsif tg_table_name = 'order_fills' then
    select * into v_order from public.orders where id = new.order_id;
    v_allowed := found and public.trading_live_flag(new.user_id, v_order.source_kind, v_order.agent_id);
  end if;
  if not v_allowed then
    raise exception 'live trading is not enabled: a live row was refused in %', tg_table_name using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- The order status state machine, exactly as OrderStatus.canTransition (Orders.swift).
create or replace function public.trading_order_can_transition(p_from text, p_to text) returns boolean
language sql immutable set search_path = '' as $$
  select case p_from
    when 'pendingSubmit'   then p_to in ('accepted', 'partiallyFilled', 'filled', 'canceled', 'rejected', 'expired')
    when 'accepted'        then p_to in ('partiallyFilled', 'filled', 'canceled', 'rejected', 'expired')
    when 'partiallyFilled' then p_to in ('partiallyFilled', 'filled', 'canceled', 'expired')
    else false
  end
$$;

create or replace function public.trading_guard_order() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_ledger_mode text;
begin
  if tg_op = 'INSERT' then
    -- An order starts life sent, working or refused. It can't be born filled.
    if new.status not in ('pendingSubmit', 'accepted', 'rejected') then
      raise exception 'a new order cannot start as %', new.status using errcode = 'check_violation';
    end if;
    if new.filled_quantity <> 0 or new.average_fill_price <> 0 or new.fees <> 0 then
      raise exception 'a new order cannot already have fills' using errcode = 'check_violation';
    end if;
    select mode into v_ledger_mode from public.trading_accounts where id = new.ledger_id;
    if v_ledger_mode is distinct from new.mode then
      raise exception 'a % order cannot be booked to a % account', new.mode, v_ledger_mode using errcode = 'check_violation';
    end if;
    -- The kill switch stops agent orders here too, whatever the caller sent.
    if new.source_kind = 'agent' and new.status <> 'rejected'
       and exists (select 1 from public.risk_policies where user_id = new.user_id and kill_switch_engaged) then
      raise exception 'the kill switch is on: no agent can place orders' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if old.status in ('filled', 'canceled', 'rejected', 'expired') then
    raise exception 'order % is % and can no longer change', old.id, old.status using errcode = 'check_violation';
  end if;
  if new.status is distinct from old.status and not public.trading_order_can_transition(old.status, new.status) then
    raise exception 'an order cannot move from % to %', old.status, new.status using errcode = 'check_violation';
  end if;
  if new.id is distinct from old.id or new.user_id is distinct from old.user_id
     or new.client_order_id is distinct from old.client_order_id or new.ledger_id is distinct from old.ledger_id
     or new.instrument_id is distinct from old.instrument_id or new.side is distinct from old.side
     or new.type is distinct from old.type or new.quantity is distinct from old.quantity
     or new.limit_price is distinct from old.limit_price or new.stop_price is distinct from old.stop_price
     or new.time_in_force is distinct from old.time_in_force or new.source_kind is distinct from old.source_kind
     or new.agent_id is distinct from old.agent_id or new.proposal_id is distinct from old.proposal_id
     or new.mode is distinct from old.mode or new.reference_price is distinct from old.reference_price
     or new.created_at is distinct from old.created_at then
    raise exception 'what an order asked for cannot be changed after it is placed' using errcode = 'check_violation';
  end if;
  if new.filled_quantity < old.filled_quantity then
    raise exception 'a fill cannot be taken back' using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- At commit, an order's filled quantity must be what its fills add up to.
create or replace function public.trading_check_order_fills() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_filled double precision;
  v_sum double precision;
begin
  select filled_quantity into v_filled from public.orders where id = new.id;
  if not found then
    return null;
  end if;
  select coalesce(sum(quantity), 0) into v_sum from public.order_fills where order_id = new.id;
  if abs(v_sum - v_filled) > 1e-6 then
    raise exception 'order % says % filled but its fills add up to %', new.id, v_filled, v_sum using errcode = 'check_violation';
  end if;
  return null;
end $$;

create or replace function public.trading_guard_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_order public.orders%rowtype;
begin
  select * into v_order from public.orders where id = new.order_id;
  if not found then
    raise exception 'a fill needs an order' using errcode = 'check_violation';
  end if;
  if v_order.status = 'rejected' then
    raise exception 'a rejected order cannot be filled' using errcode = 'check_violation';
  end if;
  if new.ledger_id is distinct from v_order.ledger_id or new.side is distinct from v_order.side
     or new.instrument_id is distinct from v_order.instrument_id or new.mode is distinct from v_order.mode
     or new.source_kind is distinct from v_order.source_kind or new.agent_id is distinct from v_order.agent_id then
    raise exception 'a fill must match its order' using errcode = 'check_violation';
  end if;
  if new.source_kind = 'agent'
     and exists (select 1 from public.risk_policies where user_id = new.user_id and kill_switch_engaged) then
    raise exception 'the kill switch is on: no agent order can fill' using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- A proposal that has been resolved stays resolved, and the kill switch lets none wait.
create or replace function public.trading_guard_proposal() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if old.status <> 'pending' and new.status is distinct from old.status then
      raise exception 'proposal % is already % and cannot become %', old.id, old.status, new.status using errcode = 'check_violation';
    end if;
    if new.id is distinct from old.id or new.user_id is distinct from old.user_id or new.agent_id is distinct from old.agent_id
       or new.signal_id is distinct from old.signal_id or new.ledger_id is distinct from old.ledger_id
       or new.instrument_id is distinct from old.instrument_id or new.side is distinct from old.side
       or new.quantity is distinct from old.quantity or new.reference_price is distinct from old.reference_price
       or new.mode is distinct from old.mode or new.client_order_id is distinct from old.client_order_id
       or new.strategy_version is distinct from old.strategy_version or new.created_at is distinct from old.created_at then
      raise exception 'what a proposal asked for cannot be changed' using errcode = 'check_violation';
    end if;
    if old.order_id is not null and new.order_id is distinct from old.order_id then
      raise exception 'a proposal maps to at most one order' using errcode = 'check_violation';
    end if;
  end if;
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from new.status)
     and exists (select 1 from public.risk_policies where user_id = new.user_id and kill_switch_engaged) then
    raise exception 'the kill switch is on: no proposal can wait for approval' using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- Append-only tables. An UPDATE is always refused. A DELETE is refused while the owner
-- exists: the only way these rows go is with the whole account (auth.users cascade).
create or replace function public.trading_refuse_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% is append-only: rows cannot be changed', tg_table_name using errcode = 'check_violation';
end $$;

create or replace function public.trading_refuse_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'TRUNCATE' then
    raise exception '% is append-only: it cannot be emptied', tg_table_name using errcode = 'check_violation';
  end if;
  if exists (select 1 from auth.users where id = old.user_id) then
    raise exception '% is append-only: rows cannot be removed', tg_table_name using errcode = 'check_violation';
  end if;
  return old;
end $$;

-- The audit hash chain. Sequence, previous_hash and hash are computed here — whatever the
-- writer supplied for them is ignored — under a per-person lock, so two writers can't
-- take the same place in the chain. The canonical text is AuditEvent.canonical (Audit.swift):
--   previousHash|sequence|time in ms|actor|kind|summary|mode|AGENT|LEDGER|ORDER|PROPOSAL|instrument|k=v;k=v
-- with UUIDs in upper case (as Swift prints them), absent values empty, and detail keys in
-- code-point order.
create or replace function public.trading_audit_canonical(
  p_previous_hash text, p_sequence bigint, p_time timestamptz, p_actor text, p_kind text, p_summary text, p_mode text,
  p_agent uuid, p_ledger uuid, p_order uuid, p_proposal uuid, p_instrument text, p_details jsonb
) returns text
language sql immutable set search_path = '' as $$
  select p_previous_hash
    || '|' || p_sequence::text
    || '|' || round(extract(epoch from p_time) * 1000)::bigint::text
    || '|' || p_actor
    || '|' || p_kind
    || '|' || p_summary
    || '|' || coalesce(p_mode, '')
    || '|' || coalesce(upper(p_agent::text), '')
    || '|' || coalesce(upper(p_ledger::text), '')
    || '|' || coalesce(upper(p_order::text), '')
    || '|' || coalesce(upper(p_proposal::text), '')
    || '|' || coalesce(p_instrument, '')
    || '|' || coalesce((select string_agg(d.key || '=' || d.value, ';' order by d.key collate "C")
                        from jsonb_each_text(p_details) as d), '')
$$;

create or replace function public.trading_audit_chain() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_last record;
begin
  if exists (select 1 from jsonb_each(new.details) as d where jsonb_typeof(d.value) <> 'string') then
    raise exception 'audit details must be text values' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('trading-audit:' || new.user_id::text, 0));
  select sequence, hash into v_last from public.audit_events
    where user_id = new.user_id order by sequence desc limit 1;
  if found then
    new.sequence := v_last.sequence + 1;
    new.previous_hash := v_last.hash;
  else
    new.sequence := 1;
    new.previous_hash := repeat('0', 64);
  end if;
  new.hash := encode(sha256(convert_to(public.trading_audit_canonical(
    new.previous_hash, new.sequence, new.time, new.actor, new.kind, new.summary, new.mode,
    new.agent_id, new.ledger_id, new.order_id, new.proposal_id, new.instrument_id, new.details), 'UTF8')), 'hex');
  return new;
end $$;

-- Recomputes a person's chain from the start and reports the first break, if any.
-- Runs as the caller: a signed-in person can check their own trail (row-level security
-- shows them nothing else); the service role can check anyone's.
create or replace function public.verify_audit_chain(p_user uuid)
returns table (is_intact boolean, broken_at_sequence bigint, event_count bigint)
language plpgsql stable set search_path = '' as $$
declare
  v_previous text := repeat('0', 64);
  v_expected bigint := 1;
  v_count bigint := 0;
  v_event record;
begin
  select count(*) into v_count from public.audit_events where user_id = p_user;
  for v_event in
    select * from public.audit_events where user_id = p_user order by sequence
  loop
    if v_event.sequence <> v_expected
       or v_event.previous_hash <> v_previous
       or v_event.hash <> encode(sha256(convert_to(public.trading_audit_canonical(
            v_event.previous_hash, v_event.sequence, v_event.time, v_event.actor, v_event.kind, v_event.summary, v_event.mode,
            v_event.agent_id, v_event.ledger_id, v_event.order_id, v_event.proposal_id, v_event.instrument_id, v_event.details),
            'UTF8')), 'hex') then
      return query select false, v_event.sequence, v_count;
      return;
    end if;
    v_previous := v_event.hash;
    v_expected := v_expected + 1;
  end loop;
  return query select true, null::bigint, v_count;
end $$;

-- =============================================================================
-- Triggers
-- =============================================================================
do $$
declare t text;
begin
  foreach t in array array['risk_policies', 'trading_accounts', 'positions', 'trading_agents'] loop
    execute format('drop trigger if exists %I_touch on public.%I', t, t);
    execute format('create trigger %I_touch before update on public.%I
                    for each row execute function public.touch_updated_at()', t, t);
  end loop;

  foreach t in array array['trading_accounts', 'trading_agents', 'trade_proposals', 'orders', 'order_fills'] loop
    execute format('drop trigger if exists %I_live_guard on public.%I', t, t);
    execute format('create trigger %I_live_guard before insert or update on public.%I
                    for each row execute function public.trading_guard_live()', t, t);
  end loop;

  foreach t in array array['audit_events', 'order_fills', 'agent_strategy_versions'] loop
    execute format('drop trigger if exists %I_no_update on public.%I', t, t);
    execute format('create trigger %I_no_update before update on public.%I
                    for each row execute function public.trading_refuse_update()', t, t);
    execute format('drop trigger if exists %I_no_delete on public.%I', t, t);
    execute format('create trigger %I_no_delete before delete on public.%I
                    for each row execute function public.trading_refuse_delete()', t, t);
    execute format('drop trigger if exists %I_no_truncate on public.%I', t, t);
    execute format('create trigger %I_no_truncate before truncate on public.%I
                    for each statement execute function public.trading_refuse_delete()', t, t);
  end loop;
end $$;

drop trigger if exists orders_guard on public.orders;
create trigger orders_guard before insert or update on public.orders
  for each row execute function public.trading_guard_order();

drop trigger if exists orders_fills_agree on public.orders;
create constraint trigger orders_fills_agree after insert or update on public.orders
  deferrable initially deferred for each row execute function public.trading_check_order_fills();

drop trigger if exists order_fills_guard on public.order_fills;
create trigger order_fills_guard before insert on public.order_fills
  for each row execute function public.trading_guard_fill();

drop trigger if exists trade_proposals_guard on public.trade_proposals;
create trigger trade_proposals_guard before insert or update on public.trade_proposals
  for each row execute function public.trading_guard_proposal();

drop trigger if exists audit_events_chain on public.audit_events;
create trigger audit_events_chain before insert on public.audit_events
  for each row execute function public.trading_audit_chain();

-- =============================================================================
-- The scheduler's lease
-- =============================================================================
-- Hands out agents whose run time has come, at most `p_max`, and marks each as taken for
-- `p_lease_seconds`. Rows another invocation is holding are skipped (not waited for), so
-- two schedulers running at once never get the same agent. A lease that is never released
-- (a crashed run) simply expires. Agents in a live mode, paused agents and everyone whose
-- kill switch is on are never handed out.
create or replace function public.claim_due_agents(
  p_max integer,
  p_lease_seconds integer default 120,
  p_now timestamptz default now(),
  p_worker uuid default gen_random_uuid()
) returns table (agent_id uuid, user_id uuid, worker uuid)
language plpgsql set search_path = '' as $$
begin
  return query
  with due as (
    select a.id
    from public.trading_agents a
    where a.deleted_at is null
      and a.status = 'active'
      and a.mode in ('researchOnly', 'signals', 'paper')
      and (a.next_run_at is null or a.next_run_at <= p_now)
      and (a.locked_until is null or a.locked_until <= p_now)
      and not exists (select 1 from public.risk_policies p where p.user_id = a.user_id and p.kill_switch_engaged)
    order by a.next_run_at nulls first, a.id
    limit greatest(least(coalesce(p_max, 0), 200), 0)
    for update of a skip locked
  )
  update public.trading_agents a
     set locked_until = p_now + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 1)),
         locked_by = p_worker
    from due
   where a.id = due.id
  returning a.id, a.user_id, p_worker;
end $$;

-- Gives a lease back early. Only the holder can (a late worker can't free someone else's).
create or replace function public.release_agent_lease(p_agent uuid, p_worker uuid) returns boolean
language plpgsql set search_path = '' as $$
begin
  update public.trading_agents set locked_until = null, locked_by = null
   where id = p_agent and locked_by = p_worker;
  return found;
end $$;

-- =============================================================================
-- Row-level security and privileges
-- =============================================================================
-- People read their own rows. Nobody but the edge functions writes.
do $$
declare t text;
begin
  foreach t in array array['risk_policies', 'broker_connections', 'trading_accounts', 'positions',
                           'trading_portfolio_snapshots', 'trading_agents', 'agent_strategy_versions', 'agent_runs',
                           'trading_signals', 'trade_proposals', 'orders', 'order_fills', 'agent_events', 'audit_events',
                           'trading_idempotency_keys']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    if t <> 'trading_idempotency_keys' then
      execute format('drop policy if exists "read own rows" on public.%I', t);
      execute format('create policy "read own rows" on public.%I for select to authenticated using (user_id = (select auth.uid()))', t);
      execute format('grant select on public.%I to authenticated', t);
    end if;
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;

  -- Even the service role's ordinary queries can't rewrite history.
  foreach t in array array['audit_events', 'order_fills', 'agent_strategy_versions'] loop
    execute format('revoke update, delete, truncate on public.%I from service_role', t);
  end loop;
end $$;

revoke all on function public.trading_live_flag(uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.trading_guard_live() from public, anon, authenticated;
revoke all on function public.trading_guard_order() from public, anon, authenticated;
revoke all on function public.trading_check_order_fills() from public, anon, authenticated;
revoke all on function public.trading_guard_fill() from public, anon, authenticated;
revoke all on function public.trading_guard_proposal() from public, anon, authenticated;
revoke all on function public.trading_refuse_update() from public, anon, authenticated;
revoke all on function public.trading_refuse_delete() from public, anon, authenticated;
revoke all on function public.trading_audit_chain() from public, anon, authenticated;
revoke all on function public.trading_audit_canonical(text, bigint, timestamptz, text, text, text, text, uuid, uuid, uuid, uuid, text, jsonb) from public, anon;
revoke all on function public.trading_order_can_transition(text, text) from public, anon;
revoke all on function public.claim_due_agents(integer, integer, timestamptz, uuid) from public, anon, authenticated;
revoke all on function public.release_agent_lease(uuid, uuid) from public, anon, authenticated;
revoke all on function public.verify_audit_chain(uuid) from public, anon;
grant execute on function public.trading_audit_canonical(text, bigint, timestamptz, text, text, text, text, uuid, uuid, uuid, uuid, text, jsonb) to authenticated, service_role;
grant execute on function public.trading_order_can_transition(text, text) to authenticated, service_role;
grant execute on function public.verify_audit_chain(uuid) to authenticated, service_role;
grant execute on function public.claim_due_agents(integer, integer, timestamptz, uuid) to service_role;
grant execute on function public.release_agent_lease(uuid, uuid) to service_role;

-- =============================================================================
-- Every-minute schedule (pg_cron + pg_net), when the project has them
-- =============================================================================
-- The job calls the agent-scheduler function with a secret header. Neither the address
-- nor the secret is written here or in any table: both are read at run time from Vault,
--   select vault.create_secret('https://<project>.supabase.co/functions/v1/agent-scheduler', 'trading_scheduler_url');
--   select vault.create_secret('<the value of the function's TRADING_SCHEDULER_SECRET>', 'trading_scheduler_secret');
-- Until both exist the job does nothing. On a project (or a local stack) without pg_cron
-- or pg_net this section is skipped; run `select public.trading_schedule_cron();` after
-- enabling them.
create or replace function public.trading_invoke_scheduler() returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    return 'skipped: pg_net is not installed';
  end if;
  if pg_catalog.to_regclass('vault.decrypted_secrets') is null then
    return 'skipped: Vault is not available';
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_url using 'trading_scheduler_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_secret using 'trading_scheduler_secret';
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return 'skipped: the scheduler address or secret is not set';
  end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 55000)'
    using v_url,
          jsonb_build_object('content-type', 'application/json', 'x-scheduler-secret', v_secret),
          jsonb_build_object('source', 'pg_cron');
  return 'requested';
end $$;

create or replace function public.trading_schedule_cron() returns text
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    return 'skipped: pg_cron is not installed';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    return 'skipped: pg_net is not installed';
  end if;
  execute $job$select cron.schedule('trading-agent-scheduler', '* * * * *', 'select public.trading_invoke_scheduler()')$job$;
  return 'scheduled';
end $$;

revoke all on function public.trading_invoke_scheduler() from public, anon, authenticated;
revoke all on function public.trading_schedule_cron() from public, anon, authenticated;
grant execute on function public.trading_invoke_scheduler() to service_role;
grant execute on function public.trading_schedule_cron() to service_role;

do $$
declare
  v_result text;
begin
  v_result := public.trading_schedule_cron();
  raise notice 'trading scheduler: %', v_result;
exception when others then
  -- A project that can't schedule must still be able to migrate.
  raise notice 'trading scheduler: skipped (%)', sqlerrm;
end $$;
