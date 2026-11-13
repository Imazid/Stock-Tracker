-- Server-side secret custody (2026-11-13).
--
-- The iOS app used to carry SnapTrade's consumer key, each user's SnapTrade userSecret
-- and the OpenAI/Gemini keys. Those move to Edge Functions (snaptrade-proxy, ai-proxy):
--
--   secure_credentials  per-user secrets, sealed with envelope encryption by the Edge
--                       Function (supabase/functions/_shared/secure/envelope.ts). No row is
--                       readable or writable by app users: RLS is on and there are NO
--                       policies; only the service role (Edge Functions) reaches it.
--   credential_events   append-only lifecycle log a person can read for their own account.
--   ai_usage_daily      per-user daily AI request count, incremented atomically by
--                       consume_ai_quota(), which only the service role may call.

-- Sealed credentials ----------------------------------------------------------
create table if not exists public.secure_credentials (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  purpose       text not null check (purpose in ('snaptrade_user', 'broker_api_key')),
  provider      text not null check (provider ~ '^[a-z0-9_]{1,32}$'),
  -- A non-secret identifier at the provider (e.g. the SnapTrade user id).
  external_ref  text check (external_ref is null or char_length(external_ref) between 1 and 200),
  sealed        jsonb not null,
  kek_id        text not null check (kek_id ~ '^[A-Za-z0-9_-]{1,32}$'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  constraint secure_credentials_sealed_shape check (
    jsonb_typeof(sealed) = 'object'
    and sealed ?& array['v', 'alg', 'kid', 'wrappedDek', 'dekIv', 'iv', 'ciphertext']
    and sealed ->> 'kid' = kek_id
  ),
  -- Belt and braces: a plaintext secret field can never be stored by mistake.
  constraint secure_credentials_no_plaintext check (
    not (sealed ?| array['userSecret', 'secret', 'apiSecret', 'privateKey', 'password'])
  )
);

-- One live SnapTrade identity per person, and one person per SnapTrade identity.
create unique index if not exists secure_credentials_one_snaptrade_per_user
  on public.secure_credentials (user_id)
  where purpose = 'snaptrade_user' and revoked_at is null;
create unique index if not exists secure_credentials_snaptrade_ref_unique
  on public.secure_credentials (external_ref)
  where purpose = 'snaptrade_user' and revoked_at is null;
create index if not exists secure_credentials_user_idx on public.secure_credentials (user_id);

drop trigger if exists secure_credentials_touch on public.secure_credentials;
create trigger secure_credentials_touch before update on public.secure_credentials
  for each row execute function public.touch_updated_at();

alter table public.secure_credentials enable row level security;
alter table public.secure_credentials force row level security;
revoke all on table public.secure_credentials from anon, authenticated;
grant select, insert, update on table public.secure_credentials to service_role;

-- Credential lifecycle log ----------------------------------------------------
create table if not exists public.credential_events (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  credential_id  uuid,
  action         text not null check (action in ('created', 'imported', 'revoked', 'rotated', 'deleted')),
  provider       text not null check (provider ~ '^[a-z0-9_]{1,32}$'),
  occurred_at    timestamptz not null default now()
);
create index if not exists credential_events_user_idx on public.credential_events (user_id, occurred_at desc);

-- Append-only: no updates ever; deletes only when the owning account is deleted (the FK
-- cascade runs this trigger one level deeper than a direct DELETE statement does).
create or replace function public.credential_events_append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' or pg_trigger_depth() < 2 then
    raise exception 'credential_events is append-only' using errcode = '42501';
  end if;
  return old;
end $$;

drop trigger if exists credential_events_append_only on public.credential_events;
create trigger credential_events_append_only before update or delete on public.credential_events
  for each row execute function public.credential_events_append_only();

alter table public.credential_events enable row level security;
revoke all on table public.credential_events from anon, authenticated;
grant select on table public.credential_events to authenticated;
grant select, insert on table public.credential_events to service_role;

drop policy if exists credential_events_read_own on public.credential_events;
create policy credential_events_read_own on public.credential_events
  for select to authenticated using (user_id = (select auth.uid()));

-- AI request ceiling ----------------------------------------------------------
create table if not exists public.ai_usage_daily (
  user_id        uuid not null references auth.users(id) on delete cascade,
  usage_date     date not null,
  request_count  integer not null default 0 check (request_count >= 0),
  primary key (user_id, usage_date)
);

alter table public.ai_usage_daily enable row level security;
revoke all on table public.ai_usage_daily from anon, authenticated;
grant select on table public.ai_usage_daily to authenticated;

drop policy if exists ai_usage_daily_read_own on public.ai_usage_daily;
create policy ai_usage_daily_read_own on public.ai_usage_daily
  for select to authenticated using (user_id = (select auth.uid()));

-- Records one request for today (UTC) if the person is under p_limit. Concurrent calls
-- serialise on the row, so the count can never pass the limit.
create or replace function public.consume_ai_quota(p_user_id uuid, p_limit integer)
returns table (allowed boolean, used integer)
language plpgsql security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_used  integer;
begin
  if p_user_id is null or p_limit is null or p_limit < 0 then
    raise exception 'consume_ai_quota: invalid arguments' using errcode = '22023';
  end if;
  if p_limit = 0 then
    return query select false, 0;
    return;
  end if;

  insert into public.ai_usage_daily as u (user_id, usage_date, request_count)
  values (p_user_id, v_today, 1)
  on conflict (user_id, usage_date) do update
    set request_count = u.request_count + 1
    where u.request_count < p_limit
  returning u.request_count into v_used;

  if v_used is null then
    select d.request_count into v_used
      from public.ai_usage_daily d
     where d.user_id = p_user_id and d.usage_date = v_today;
    return query select false, v_used;
  else
    return query select true, v_used;
  end if;
end $$;

revoke all on function public.consume_ai_quota(uuid, integer) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid, integer) to service_role;
