-- Stock Tracker — Supabase schema, reconstructed 2026-10-17 from the app's own
-- queries (SyncModels.swift, SyncManager.swift, ReferralModels.swift, ReferralService.swift).
--
-- Why this exists: the original project (sdirmgv…mhzm.supabase.co) no longer resolves
-- (NXDOMAIN) and no schema was kept in the repo. To bring accounts, sync and referrals back:
--   1. Create a Supabase project, then from the repo root:
--        supabase link --project-ref <ref> && supabase db push
--      (or paste this file into the dashboard's SQL editor).
--   2. Authentication → enable Email (and Apple for Sign in with Apple). The app shows a
--      6-digit code screen when email confirmation is on: add {{ .Token }} to the
--      "Confirm signup" email template, or turn confirmation off.
--   3. Put the project URL + anon key in Config/Secrets.plist (SupabaseURL / SupabaseAnonKey).
-- Locally: `supabase start` in the repo root runs this exact backend on port 58321
-- (supabase/config.toml), which Stock TrackerUITests/AccountSyncTests drives end to end.
--
-- Every table is per-user and protected by row-level security: a signed-in user can
-- only read and write their own rows. Prices are never stored here — the app re-fetches
-- them. Money columns are USD (the app's money invariant, see FXRates.swift).

create extension if not exists pgcrypto;

-- updated_at maintenance -----------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Watchlist ------------------------------------------------------------------
create table if not exists public.watchlist_assets (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  symbol      text not null,
  name        text not null default '',
  kind        text not null check (kind in ('Stock', 'Crypto')),
  exchange    text,
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (user_id, symbol)                       -- upsert onConflict "user_id,symbol"
);

-- Portfolio holdings (id = the app's PortfolioHolding.id) ------------------------
create table if not exists public.portfolio_holdings (
  id              uuid primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  asset_symbol    text not null,
  asset_name      text not null default '',
  asset_kind      text not null,
  asset_exchange  text,
  shares          double precision not null check (shares >= 0),
  avg_cost        double precision not null check (avg_cost >= 0),   -- USD
  date_added      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create index if not exists portfolio_holdings_user_idx on public.portfolio_holdings (user_id);

-- Transactions (children of holdings; id = the app's Transaction.id) ------------
create table if not exists public.transactions (
  id                uuid primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  holding_id        uuid not null references public.portfolio_holdings(id) on delete cascade,
  transaction_date  timestamptz not null,
  shares            double precision not null check (shares > 0),
  price_per_share   double precision not null check (price_per_share >= 0),  -- USD
  type              text not null check (type in ('Buy', 'Sell')),
  fees              double precision not null default 0 check (fees >= 0),  -- USD brokerage
  avg_cost_at_sale  double precision,  -- USD; sells only, for holdings whose buys aren't in the ledger
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz
);
create index if not exists transactions_user_idx on public.transactions (user_id);
create index if not exists transactions_holding_idx on public.transactions (holding_id);

-- Price alerts (id = the app's PriceAlert.id) ------------------------------------
create table if not exists public.price_alerts (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  symbol        text not null,
  asset_name    text not null default '',
  target_price  double precision not null check (target_price > 0),     -- USD
  condition     text not null check (condition in ('Above', 'Below')),
  is_active     boolean not null default true,
  repeats       boolean not null default false,   -- "Every time" alerts re-arm instead of deleting
  is_armed      boolean not null default true,    -- false after firing until price moves 0.5% back
  last_triggered_at timestamptz,
  asset_kind    text check (asset_kind in ('Stock', 'Crypto')),  -- what to quote when it isn't watchlisted
  asset_exchange text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);
create index if not exists price_alerts_user_idx on public.price_alerts (user_id);

-- Daily portfolio value snapshots ---------------------------------------------------
create table if not exists public.portfolio_snapshots (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  snapshot_date  date not null,
  total_value    double precision not null,                              -- USD
  updated_at     timestamptz not null default now(),
  unique (user_id, snapshot_date)                -- upsert onConflict "user_id,snapshot_date"
);

-- Referrals -------------------------------------------------------------------------
create table if not exists public.referral_codes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null unique references auth.users(id) on delete cascade,
  code        text not null unique,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.referrals (
  id                    uuid primary key default gen_random_uuid(),
  referrer_id           uuid not null references auth.users(id) on delete cascade,
  referee_id            uuid not null unique references auth.users(id) on delete cascade, -- one code per user
  code_used             text not null,
  status                text not null default 'pending'
                        check (status in ('pending', 'qualified', 'rewarded', 'expired', 'blocked')),
  signed_up_at          timestamptz default now(),      -- "set by default on INSERT" (ReferralModels)
  portfolio_created_at  timestamptz,
  first_holding_at      timestamptz,
  block_reason          text,
  expires_at            timestamptz not null default now() + interval '30 days',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check (referrer_id <> referee_id)
);
create index if not exists referrals_referrer_idx on public.referrals (referrer_id);

-- One 8-character code per user; returns the code (ReferralService.generate).
create or replace function public.generate_referral_code(p_user_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  new_code text;
begin
  if p_user_id is distinct from auth.uid() then
    raise exception 'not allowed';
  end if;
  select code into new_code from referral_codes where user_id = p_user_id;
  if new_code is not null then
    return new_code;
  end if;
  loop
    -- No 0/O/1/I so codes read unambiguously.
    new_code := (
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (floor(random() * 32) + 1)::int, 1), '')
      from generate_series(1, 8)
    );
    begin
      insert into referral_codes (user_id, code) values (p_user_id, new_code);
      return new_code;
    exception when unique_violation then
      -- collision on code: try again
    end;
  end loop;
end $$;
revoke all on function public.generate_referral_code(uuid) from public;
grant execute on function public.generate_referral_code(uuid) to authenticated;

-- updated_at triggers -------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['watchlist_assets', 'portfolio_holdings', 'transactions',
                           'price_alerts', 'portfolio_snapshots', 'referral_codes', 'referrals']
  loop
    execute format('drop trigger if exists %I_touch on public.%I', t, t);
    execute format('create trigger %I_touch before update on public.%I
                    for each row execute function public.touch_updated_at()', t, t);
  end loop;
end $$;

-- Row-level security -----------------------------------------------------------------
alter table public.watchlist_assets    enable row level security;
alter table public.portfolio_holdings  enable row level security;
alter table public.transactions        enable row level security;
alter table public.price_alerts        enable row level security;
alter table public.portfolio_snapshots enable row level security;
alter table public.referral_codes      enable row level security;
alter table public.referrals           enable row level security;

do $$
declare t text;
begin
  foreach t in array array['watchlist_assets', 'portfolio_holdings', 'transactions',
                           'price_alerts', 'portfolio_snapshots']
  loop
    execute format('drop policy if exists "own rows" on public.%I', t);
    execute format('create policy "own rows" on public.%I for all to authenticated
                    using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
  end loop;
end $$;

-- Codes: owners read their own. Anyone else checks one code at a time through
-- referral_code_owner() (a readable table let any user list every code + owner id).
-- Codes are created only via generate_referral_code().
drop policy if exists "read active or own" on public.referral_codes;
drop policy if exists "read own" on public.referral_codes;
create policy "read own" on public.referral_codes for select to authenticated
  using (user_id = auth.uid());

create or replace function public.referral_code_owner(p_code text) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from referral_codes where code = upper(trim(p_code)) and is_active
$$;
revoke all on function public.referral_code_owner(text) from public;
grant execute on function public.referral_code_owner(text) to authenticated;

-- Referrals: both sides can read; only the referee creates it (with themselves as referee)
-- and records their own qualification events. Rewards are granted server-side, never here.
drop policy if exists "parties read" on public.referrals;
create policy "parties read" on public.referrals for select to authenticated
  using (referrer_id = auth.uid() or referee_id = auth.uid());
drop policy if exists "referee inserts" on public.referrals;
create policy "referee inserts" on public.referrals for insert to authenticated
  with check (referee_id = auth.uid() and status = 'pending'
              and referrer_id = public.referral_code_owner(code_used));  -- no made-up referrers
drop policy if exists "referee updates" on public.referrals;
create policy "referee updates" on public.referrals for update to authenticated
  using (referee_id = auth.uid())
  with check (referee_id = auth.uid() and status in ('pending', 'qualified', 'expired'));
