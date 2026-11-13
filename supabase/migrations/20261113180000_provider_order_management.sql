-- Stock Tracker — provider connections, credential vault and provider order management.
--
-- Companion to 20261113120000_trading_platform.sql (practice trading in our own database).
-- This file is the database for orders that go to a PROVIDER (Alpaca paper today; real money
-- only after the reviewed change described under "Platform gates"). Code: supabase/functions/
-- _shared/oms (rules), _shared/brokers (provider adapters), _shared/vault (encryption), and
-- the edge functions broker-connections and broker-orders.
--
-- What must hold even if the code above is wrong:
--   * Clients read their own rows and write nothing. Every write comes from the edge functions
--     (service role), which run validation, gates, the risk engine and the approval checks.
--   * Credentials are never readable by any client role: broker_credentials has RLS on and no
--     policy at all, and SELECT is revoked. Only sealed (AES-256-GCM envelope) blobs are stored.
--   * Intents follow one state machine (oms/lifecycle.ts); every transition is recorded in an
--     append-only table; nothing leaves reconciliation_required by being sent again.
--   * An approval belongs to the intent's owner, binds the intent hash, and is used once.
--   * Money and quantities are numeric (exact), never floating point.
--   * Real-money (live) rows can't exist in this build: CHECK constraints refuse them, the
--     same way 20261113120000 keeps every live flag off. Enabling live trading is a migration
--     that drops those constraints — a reviewed change, not an UPDATE.
--
-- Order-independence: if 20261113120000 has run, broker_connections already exists and is
-- only extended here; if not, the same base table is created so this file applies alone.

-- =============================================================================
-- Platform gates (administrator-controlled; clients may read)
-- =============================================================================
create table if not exists public.platform_gates (
  id          text primary key check (id in ('provider_paper_execution', 'live_execution', 'automated_live_execution',
                                             'personalised_recommendations', 'custodial_features')),
  enabled     boolean not null default false,
  reason      text not null default '' check (char_length(reason) <= 1000),
  updated_at  timestamptz not null default now(),
  updated_by  text,
  -- Real money is not available in this build; neither are agent mandates; custody never.
  constraint platform_gates_live_not_in_this_build
    check (id not in ('live_execution', 'automated_live_execution') or not enabled),
  constraint platform_gates_never_custodial
    check (id <> 'custodial_features' or not enabled)
);

insert into public.platform_gates (id, enabled, reason) values
  ('provider_paper_execution', false, 'Orders to a provider''s paper (practice) account. No real money.'),
  ('live_execution', false, 'Real-money orders. Requires licensing, provider agreement and operational review (docs/REGULATORY_REVIEW.md).'),
  ('automated_live_execution', false, 'Agent orders without a per-order approval. Requires legal review.'),
  ('personalised_recommendations', false, 'Advice for a person''s circumstances. Agents give factual information and general analysis only.'),
  ('custodial_features', false, 'Holding or moving customer assets. Never enabled.')
on conflict (id) do nothing;

-- =============================================================================
-- Connections (extends the base table from 20261113120000)
-- =============================================================================
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
  constraint broker_connections_no_live_trade_in_this_build
    check (environment <> 'live' or not ('trade' = any (permissions)))
);

alter table public.broker_connections add column if not exists provider_account_id text check (char_length(provider_account_id) <= 128);
alter table public.broker_connections add column if not exists status text not null default 'active';
alter table public.broker_connections add column if not exists key_hint text not null default '…' check (char_length(key_hint) <= 8);
alter table public.broker_connections add column if not exists sync_state text not null default 'never';
alter table public.broker_connections add column if not exists last_synced_at timestamptz;
alter table public.broker_connections add column if not exists sync_error text check (char_length(sync_error) <= 500);
alter table public.broker_connections add column if not exists revoked_at timestamptz;
alter table public.broker_connections add column if not exists updated_at timestamptz not null default now();

do $$ begin
  alter table public.broker_connections add constraint broker_connections_status_values
    check (status in ('active', 'needs_attention', 'revoked'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.broker_connections add constraint broker_connections_sync_values
    check (sync_state in ('never', 'running', 'ok', 'failed'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.broker_connections add constraint broker_connections_revoked_consistent
    check ((status = 'revoked') = (revoked_at is not null));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.broker_connections add constraint broker_connections_known_adapter
    check (adapter_id in ('alpaca', 'coinbase', 'snaptrade', 'paper'));
exception when duplicate_object then null; when check_violation then
  raise notice 'broker_connections has adapter ids outside the known list; constraint not added';
end $$;

create index if not exists broker_connections_user_idx on public.broker_connections (user_id);
create unique index if not exists broker_connections_one_active_per_account
  on public.broker_connections (user_id, adapter_id, environment, provider_account_id)
  where status <> 'revoked' and provider_account_id is not null;

alter table public.broker_connections enable row level security;
drop policy if exists broker_connections_select_own on public.broker_connections;
create policy broker_connections_select_own on public.broker_connections for select to authenticated using (user_id = auth.uid());

-- =============================================================================
-- Credential vault (no client can read this table, ever)
-- =============================================================================
create table if not exists public.broker_credentials (
  connection_id  uuid primary key references public.broker_connections(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  -- SealedSecret from _shared/vault/envelope.ts: {v, alg, kekID, wrappedDEK, wrapIV, iv, ciphertext}
  sealed         jsonb not null check (sealed ? 'ciphertext' and sealed ? 'wrappedDEK' and sealed ? 'kekID'
                                        and not (sealed ? 'secretKey') and not (sealed ? 'privateKeyPEM')),
  kek_id         text not null check (char_length(kek_id) between 1 and 32),
  created_at     timestamptz not null default now(),
  rotated_at     timestamptz
);
alter table public.broker_credentials enable row level security;
-- Deliberately no policies. Belt and braces:
revoke all on public.broker_credentials from anon, authenticated;

-- A revoked connection keeps no credential.
create or replace function public.oms_drop_credentials_on_revoke() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'revoked' and old.status is distinct from 'revoked' then
    delete from public.broker_credentials where connection_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists broker_connections_drop_credentials on public.broker_connections;
create trigger broker_connections_drop_credentials after update of status on public.broker_connections
  for each row execute function public.oms_drop_credentials_on_revoke();

-- =============================================================================
-- Provider order intents
-- =============================================================================
create table if not exists public.order_intents (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  connection_id      uuid not null references public.broker_connections(id) on delete restrict,
  provider           text not null check (provider in ('alpaca', 'coinbase')),
  environment        text not null check (environment in ('paper', 'sandbox', 'live')),
  symbol             text not null check (symbol ~ '^[A-Z0-9][A-Z0-9./-]{0,23}$'),
  asset_class        text not null check (asset_class in ('us_equity', 'crypto')),
  side               text not null check (side in ('buy', 'sell')),
  order_type         text not null check (order_type in ('market', 'limit', 'stop', 'stop_limit')),
  time_in_force      text not null check (time_in_force in ('day', 'gtc', 'ioc', 'fok')),
  quantity           numeric(38, 18) check (quantity > 0),
  notional           numeric(38, 18) check (notional > 0),
  limit_price        numeric(38, 18) check (limit_price > 0),
  stop_price         numeric(38, 18) check (stop_price > 0),
  origin_kind        text not null check (origin_kind in ('manual', 'agent')),
  agent_id           uuid,
  rationale          text check (char_length(rationale) <= 4000),
  client_order_id    text not null check (client_order_id ~ '^[A-Za-z0-9-]{8,48}$'),
  intent_hash        text not null check (intent_hash ~ '^[0-9a-f]{64}$'),
  status             text not null default 'draft',
  estimate           jsonb not null default '{}'::jsonb,
  risk               jsonb,                      -- latest RiskEvaluationView
  provider_order_id  text check (char_length(provider_order_id) <= 128),
  reconciling_since  timestamptz,
  created_at         timestamptz not null default now(),
  expires_at         timestamptz not null,
  updated_at         timestamptz not null default now(),
  unique (user_id, client_order_id),
  constraint order_intents_status_values check (status in ('draft', 'risk_checked', 'awaiting_approval', 'approved', 'submitting',
    'submitted', 'partially_filled', 'filled', 'rejected', 'expired', 'cancelled', 'failed', 'reconciliation_required')),
  constraint order_intents_one_size check ((quantity is null) <> (notional is null)),
  constraint order_intents_notional_market_only check (notional is null or order_type = 'market'),
  constraint order_intents_limit_price check ((order_type in ('limit', 'stop_limit')) = (limit_price is not null)),
  constraint order_intents_stop_price check ((order_type in ('stop', 'stop_limit')) = (stop_price is not null)),
  constraint order_intents_agent_reason check (origin_kind = 'manual' or (agent_id is not null and coalesce(char_length(btrim(rationale)), 0) > 0)),
  constraint order_intents_live_not_in_this_build check (environment <> 'live')
);
create index if not exists order_intents_user_idx on public.order_intents (user_id, created_at desc);
create index if not exists order_intents_open_idx on public.order_intents (status, updated_at)
  where status in ('submitting', 'submitted', 'partially_filled', 'reconciliation_required');

-- The legal moves: identical to NEXT in _shared/oms/lifecycle.ts.
create or replace function public.oms_intent_can_transition(p_from text, p_to text) returns boolean
language sql immutable as $$
  select case p_from
    when 'draft' then p_to in ('risk_checked', 'rejected', 'expired', 'cancelled')
    when 'risk_checked' then p_to in ('awaiting_approval', 'risk_checked', 'rejected', 'expired', 'cancelled')
    when 'awaiting_approval' then p_to in ('approved', 'risk_checked', 'rejected', 'expired', 'cancelled')
    when 'approved' then p_to in ('submitting', 'rejected', 'expired', 'cancelled')
    when 'submitting' then p_to in ('submitted', 'partially_filled', 'filled', 'rejected', 'failed', 'reconciliation_required', 'cancelled', 'expired')
    when 'submitted' then p_to in ('partially_filled', 'filled', 'cancelled', 'expired', 'rejected', 'reconciliation_required')
    when 'partially_filled' then p_to in ('partially_filled', 'filled', 'cancelled', 'expired', 'reconciliation_required')
    when 'reconciliation_required' then p_to in ('submitted', 'partially_filled', 'filled', 'cancelled', 'expired', 'rejected', 'failed', 'reconciliation_required')
    else false
  end
$$;

create table if not exists public.order_intent_transitions (
  id           bigint generated always as identity primary key,
  intent_id    uuid not null references public.order_intents(id) on delete cascade,
  user_id      uuid not null,
  from_status  text,
  to_status    text not null,
  note         text check (char_length(note) <= 500),
  at           timestamptz not null default now()
);
create index if not exists order_intent_transitions_intent_idx on public.order_intent_transitions (intent_id, id);

-- What an intent may never change once drafted (the fields its hash covers) and the state
-- machine, checked before the write.
create or replace function public.oms_guard_intent() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then raise exception 'an order intent starts as a draft' using errcode = 'check_violation'; end if;
    return new;
  end if;
  if (new.user_id, new.connection_id, new.provider, new.environment, new.symbol, new.asset_class, new.side, new.order_type,
      new.time_in_force, new.quantity, new.notional, new.limit_price, new.stop_price, new.client_order_id, new.intent_hash,
      new.origin_kind, new.agent_id, new.created_at)
     is distinct from
     (old.user_id, old.connection_id, old.provider, old.environment, old.symbol, old.asset_class, old.side, old.order_type,
      old.time_in_force, old.quantity, old.notional, old.limit_price, old.stop_price, old.client_order_id, old.intent_hash,
      old.origin_kind, old.agent_id, old.created_at) then
    raise exception 'an order intent can''t be edited; draft a new one' using errcode = 'check_violation';
  end if;
  if new.status is distinct from old.status then
    if not public.oms_intent_can_transition(old.status, new.status) then
      raise exception 'an order can''t go from % to %', old.status, new.status using errcode = 'check_violation';
    end if;
    if new.status = 'reconciliation_required' and old.status <> 'reconciliation_required' then
      new.reconciling_since := now();
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists order_intents_guard on public.order_intents;
create trigger order_intents_guard before insert or update on public.order_intents
  for each row execute function public.oms_guard_intent();

-- The log is written AFTER the row exists (a BEFORE trigger can't reference it yet).
create or replace function public.oms_log_intent_transition() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status
     or (new.status = 'partially_filled' and old.status = 'partially_filled') then
    insert into public.order_intent_transitions (intent_id, user_id, from_status, to_status, note)
      values (new.id, new.user_id, case when tg_op = 'INSERT' then null else old.status end, new.status,
              nullif(current_setting('oms.transition_note', true), ''));
  end if;
  return null;
end $$;
drop trigger if exists order_intents_log on public.order_intents;
create trigger order_intents_log after insert or update of status on public.order_intents
  for each row execute function public.oms_log_intent_transition();

-- =============================================================================
-- Approvals (one per intent, single use, owner only)
-- =============================================================================
create table if not exists public.order_approvals (
  intent_id             uuid primary key references public.order_intents(id) on delete cascade,
  approver_id           uuid not null references auth.users(id) on delete cascade,
  approved_intent_hash  text not null check (approved_intent_hash ~ '^[0-9a-f]{64}$'),
  aal                   text not null check (aal in ('aal1', 'aal2')),
  approved_at           timestamptz not null default now(),
  expires_at            timestamptz not null,
  consumed_at           timestamptz,
  constraint order_approvals_expiry check (expires_at > approved_at),
  constraint order_approvals_consumed_in_time check (consumed_at is null or consumed_at <= expires_at)
);

create or replace function public.oms_guard_approval() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_hash text; v_env text;
begin
  select user_id, intent_hash, environment into v_owner, v_hash, v_env from public.order_intents where id = new.intent_id;
  if v_owner is null then raise exception 'no such order' using errcode = 'foreign_key_violation'; end if;
  if new.approver_id <> v_owner then raise exception 'only the account owner can approve an order' using errcode = 'check_violation'; end if;
  if new.approved_intent_hash <> v_hash then raise exception 'the approval doesn''t match the order' using errcode = 'check_violation'; end if;
  if v_env = 'live' and new.aal <> 'aal2' then raise exception 'a live order needs a second factor' using errcode = 'check_violation'; end if;
  if tg_op = 'UPDATE' then
    if (new.intent_id, new.approver_id, new.approved_intent_hash, new.aal, new.approved_at, new.expires_at)
       is distinct from (old.intent_id, old.approver_id, old.approved_intent_hash, old.aal, old.approved_at, old.expires_at) then
      raise exception 'an approval can''t be changed' using errcode = 'check_violation';
    end if;
    if old.consumed_at is not null then raise exception 'this approval has already been used' using errcode = 'check_violation'; end if;
  end if;
  return new;
end $$;
drop trigger if exists order_approvals_guard on public.order_approvals;
create trigger order_approvals_guard before insert or update on public.order_approvals
  for each row execute function public.oms_guard_approval();

-- The atomic "use it once" step. Returns true only for the single caller that consumed it.
create or replace function public.oms_consume_approval(p_intent uuid, p_now timestamptz) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  update public.order_approvals set consumed_at = p_now
   where intent_id = p_intent and consumed_at is null and expires_at > p_now;
  get diagnostics v_count = row_count;
  return v_count = 1;
end $$;
revoke all on function public.oms_consume_approval(uuid, timestamptz) from public, anon, authenticated;

-- =============================================================================
-- What the provider reports: orders, fills, positions, balances
-- =============================================================================
create table if not exists public.broker_orders (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  connection_id       uuid not null references public.broker_connections(id) on delete cascade,
  intent_id           uuid references public.order_intents(id) on delete set null,   -- null: placed outside this app
  provider_order_id   text not null check (char_length(provider_order_id) between 1 and 128),
  client_order_id     text,
  symbol              text not null,
  side                text not null check (side in ('buy', 'sell')),
  order_type          text not null,
  status              text not null,
  provider_status     text not null,
  quantity            numeric(38, 18),
  notional            numeric(38, 18),
  filled_quantity     numeric(38, 18) not null default 0 check (filled_quantity >= 0),
  average_fill_price  numeric(38, 18),
  limit_price         numeric(38, 18),
  stop_price          numeric(38, 18),
  submitted_at        timestamptz,
  provider_updated_at timestamptz,
  updated_at          timestamptz not null default now(),
  unique (connection_id, provider_order_id)
);
create index if not exists broker_orders_user_idx on public.broker_orders (user_id, updated_at desc);

create table if not exists public.broker_fills (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  connection_id      uuid not null references public.broker_connections(id) on delete cascade,
  provider_fill_id   text not null check (char_length(provider_fill_id) between 1 and 128),
  provider_order_id  text not null,
  symbol             text not null,
  side               text not null check (side in ('buy', 'sell')),
  quantity           numeric(38, 18) not null check (quantity > 0),
  price              numeric(38, 18) not null check (price > 0),
  fee                numeric(38, 18) check (fee >= 0),
  fee_currency       text,
  executed_at        timestamptz not null,
  ingested_at        timestamptz not null default now(),
  -- Idempotent ingestion: the same provider fill can arrive by sync, stream and webhook.
  unique (connection_id, provider_fill_id)
);
create index if not exists broker_fills_user_idx on public.broker_fills (user_id, executed_at desc);

create table if not exists public.broker_position_snapshots (
  id                  bigint generated always as identity primary key,
  user_id             uuid not null references auth.users(id) on delete cascade,
  connection_id       uuid not null references public.broker_connections(id) on delete cascade,
  symbol              text not null,
  asset_class         text not null check (asset_class in ('us_equity', 'crypto')),
  quantity            numeric(38, 18) not null,
  average_entry_price numeric(38, 18),
  cost_basis          numeric(38, 18),
  market_value        numeric(38, 18),
  currency            text not null check (currency ~ '^[A-Z]{3,5}$'),
  observed_at         timestamptz not null
);
create index if not exists broker_position_snapshots_idx on public.broker_position_snapshots (connection_id, observed_at desc);

create table if not exists public.broker_balance_snapshots (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  connection_id  uuid not null references public.broker_connections(id) on delete cascade,
  currency       text not null check (currency ~ '^[A-Z]{3,5}$'),
  total          numeric(38, 18) not null,
  available      numeric(38, 18) not null,
  reserved       numeric(38, 18) not null,
  observed_at    timestamptz not null
);
create index if not exists broker_balance_snapshots_idx on public.broker_balance_snapshots (connection_id, observed_at desc);

-- =============================================================================
-- Risk limits for a provider account (versioned; every evaluation records the version)
-- =============================================================================
create table if not exists public.provider_risk_policies (
  connection_id   uuid primary key references public.broker_connections(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  version         integer not null default 1 check (version >= 1),
  -- The engine's RiskPolicy (_shared/trading/risk.ts) and the OMS AccountLimits (_shared/oms/risk.ts).
  limits          jsonb not null check (jsonb_typeof(limits) = 'object'),
  account_limits  jsonb not null default '{}'::jsonb check (jsonb_typeof(account_limits) = 'object'),
  updated_at      timestamptz not null default now()
);
create or replace function public.oms_bump_policy_version() returns trigger language plpgsql as $$
begin
  if (new.limits, new.account_limits) is distinct from (old.limits, old.account_limits) then
    new.version := old.version + 1;
  else
    new.version := old.version;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists provider_risk_policies_version on public.provider_risk_policies;
create trigger provider_risk_policies_version before update on public.provider_risk_policies
  for each row execute function public.oms_bump_policy_version();

-- A retried state-changing call returns its first answer instead of acting twice.
create table if not exists public.oms_idempotency_keys (
  user_id     uuid not null references auth.users(id) on delete cascade,
  key         text not null check (char_length(key) between 8 and 128),
  action      text not null,
  status      integer not null,
  response    jsonb not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, key)
);

-- =============================================================================
-- Sync cursors, webhook de-duplication, OMS events
-- =============================================================================
create table if not exists public.provider_sync_cursors (
  connection_id  uuid not null references public.broker_connections(id) on delete cascade,
  stream         text not null check (stream in ('fills', 'orders', 'activities')),
  cursor         text,
  updated_at     timestamptz not null default now(),
  primary key (connection_id, stream)
);

create table if not exists public.provider_webhook_events (
  provider       text not null check (provider in ('alpaca', 'coinbase')),
  event_id       text not null check (char_length(event_id) between 1 and 200),
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  received_at    timestamptz not null default now(),
  processed_at   timestamptz,
  primary key (provider, event_id)
);

-- Append-only record of everything the order system did (who, what, which order). No secrets,
-- no prompts, no model reasoning: identifiers, codes and decisions only.
create table if not exists public.oms_events (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  intent_id   uuid references public.order_intents(id) on delete set null,
  kind        text not null check (kind ~ '^[a-z_]+\.[a-z_]+$'),
  detail      jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  at          timestamptz not null default now()
);
create index if not exists oms_events_user_idx on public.oms_events (user_id, id desc);

create or replace function public.oms_refuse_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = 'check_violation';
end $$;
drop trigger if exists oms_events_append_only on public.oms_events;
create trigger oms_events_append_only before update or delete on public.oms_events
  for each row execute function public.oms_refuse_change();
drop trigger if exists order_intent_transitions_append_only on public.order_intent_transitions;
create trigger order_intent_transitions_append_only before update or delete on public.order_intent_transitions
  for each row execute function public.oms_refuse_change();

-- =============================================================================
-- Row level security: read your own rows; write nothing
-- =============================================================================
do $$
declare t text;
begin
  foreach t in array array['order_intents', 'order_intent_transitions', 'order_approvals', 'broker_orders', 'broker_fills',
                           'broker_position_snapshots', 'broker_balance_snapshots', 'oms_events', 'provider_risk_policies'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_own', t);
    if t = 'order_approvals' then
      execute format('create policy %I on public.%I for select to authenticated using (approver_id = auth.uid())', t || '_select_own', t);
    else
      execute format('create policy %I on public.%I for select to authenticated using (user_id = auth.uid())', t || '_select_own', t);
    end if;
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

alter table public.platform_gates enable row level security;
drop policy if exists platform_gates_read on public.platform_gates;
create policy platform_gates_read on public.platform_gates for select to authenticated using (true);
revoke insert, update, delete, truncate on public.platform_gates from anon, authenticated;
grant select on public.platform_gates to authenticated;

alter table public.provider_sync_cursors enable row level security;
alter table public.provider_webhook_events enable row level security;
alter table public.oms_idempotency_keys enable row level security;
revoke all on public.provider_sync_cursors, public.provider_webhook_events, public.oms_idempotency_keys from anon, authenticated;

revoke insert, update, delete, truncate on public.broker_connections from anon, authenticated;
grant select (id, user_id, adapter_id, name, environment, permissions, created_at, provider_account_id, status,
              key_hint, sync_state, last_synced_at, sync_error, revoked_at, updated_at)
  on public.broker_connections to authenticated;
