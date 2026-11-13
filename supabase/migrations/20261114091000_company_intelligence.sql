-- Public filing data may be persisted. Licensed responses stay outside these tables.
create table public.research_instruments (
    instrument_id text primary key,
    venue text not null,
    symbol text not null,
    company_name text not null,
    exchange text not null,
    sec_cik text not null check (sec_cik ~ '^[0-9]{10}$'),
    source_url text not null,
    observed_at timestamptz not null,
    unique (venue, symbol)
);

create table public.research_snapshots (
    instrument_id text not null references public.research_instruments on delete cascade,
    dataset text not null check (dataset in ('sec-companyfacts')),
    retrieved_at timestamptz not null,
    source_url text not null,
    payload jsonb not null check (jsonb_typeof(payload) = 'array'),
    primary key (instrument_id, dataset, retrieved_at)
);

alter table public.research_instruments enable row level security;
alter table public.research_snapshots enable row level security;
revoke all on public.research_instruments, public.research_snapshots from public, anon, authenticated;
grant select, insert, update on public.research_instruments to service_role;
grant select, insert on public.research_snapshots to service_role;

create table public.company_research_alerts (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users on delete cascade,
    instrument_id text not null check (instrument_id ~ '^(us|asx|lse|xetra|euronextParis|euronextAmsterdam|six|tse|hkex|sgx|krx|nse):[A-Z0-9][A-Z0-9.&-]{0,19}$'),
    kind text not null check (kind in ('price_above', 'price_below', 'volume_above', 'filing', 'insider', 'news')),
    threshold numeric check (threshold > 0 and threshold <= 1e15),
    currency text check (currency ~ '^[A-Z]{3}$'),
    created_at timestamptz not null default now(),
    next_check_at timestamptz not null default now(),
    last_checked_at timestamptz,
    last_problem text,
    last_condition boolean,
    lease_until timestamptz,
    lease_token uuid,
    check ((kind in ('price_above', 'price_below', 'volume_above')) = (threshold is not null)),
    check ((kind in ('price_above', 'price_below')) = (currency is not null)),
    unique (id, user_id),
    unique nulls not distinct (user_id, instrument_id, kind, threshold, currency)
);

create index company_research_alerts_due_idx on public.company_research_alerts (next_check_at, id);
create index company_research_alerts_owner_idx on public.company_research_alerts (user_id, instrument_id);

create table public.company_research_alert_events (
    id bigint generated always as identity primary key,
    alert_id uuid not null,
    user_id uuid not null,
    event_key text not null,
    title text not null,
    url text,
    occurred_at timestamptz not null,
    foreign key (alert_id, user_id) references public.company_research_alerts (id, user_id) on delete cascade,
    unique (alert_id, event_key)
);

create index company_research_alert_events_owner_idx on public.company_research_alert_events (user_id, occurred_at desc);

alter table public.company_research_alerts enable row level security;
alter table public.company_research_alert_events enable row level security;
revoke all on public.company_research_alerts, public.company_research_alert_events from public, anon, authenticated;
grant select, delete on public.company_research_alerts to authenticated;
grant insert (user_id, instrument_id, kind, threshold, currency) on public.company_research_alerts to authenticated;
grant select on public.company_research_alert_events to authenticated;
grant select, update on public.company_research_alerts to service_role;
grant select, insert on public.company_research_alert_events to service_role;
grant usage on sequence public.company_research_alert_events_id_seq to service_role;

create policy company_alert_owner_read on public.company_research_alerts for select to authenticated
    using ((select auth.uid()) = user_id);
create policy company_alert_owner_create on public.company_research_alerts for insert to authenticated
    with check ((select auth.uid()) = user_id);
create policy company_alert_owner_delete on public.company_research_alerts for delete to authenticated
    using ((select auth.uid()) = user_id);
create policy company_alert_event_owner_read on public.company_research_alert_events for select to authenticated
    using ((select auth.uid()) = user_id);

create function public.limit_company_research_alerts()
returns trigger language plpgsql security invoker set search_path = ''
as $$
begin
    perform pg_advisory_xact_lock(hashtextextended('company-research-alert:' || new.user_id::text, 0));
    if (select count(*) from public.company_research_alerts where user_id = new.user_id) >= 100 then
        raise exception using errcode = '23514', message = 'Company research alert limit reached';
    end if;
    return new;
end;
$$;

revoke all on function public.limit_company_research_alerts() from public, anon, authenticated;
create trigger company_research_alert_limit before insert on public.company_research_alerts
    for each row execute function public.limit_company_research_alerts();

create function public.claim_company_research_alerts(batch_size integer)
returns setof public.company_research_alerts language sql security invoker set search_path = ''
as $$
    with due as (
        select id from public.company_research_alerts
        where next_check_at <= now() and (lease_until is null or lease_until <= now())
        order by next_check_at, id
        limit greatest(0, least(batch_size, 25))
        for update skip locked
    )
    update public.company_research_alerts alert
    set lease_token = gen_random_uuid(), lease_until = now() + interval '3 minutes'
    from due where alert.id = due.id
    returning alert.*;
$$;

create function public.finish_company_research_alert(
    target_id uuid, token uuid, observed_condition boolean, problem text, new_events jsonb
) returns boolean language plpgsql security invoker set search_path = ''
as $$
declare
    owner_id uuid;
begin
    update public.company_research_alerts
    set lease_token = null, lease_until = null,
        last_checked_at = case when problem is null then now() else last_checked_at end,
        last_condition = coalesce(observed_condition, last_condition), last_problem = problem,
        next_check_at = now() + interval '10 minutes'
    where id = target_id and lease_token = token
    returning user_id into owner_id;
    if owner_id is null then return false; end if;

    insert into public.company_research_alert_events (alert_id, user_id, event_key, title, url, occurred_at)
    select target_id, owner_id, event_key, title, url, occurred_at
    from jsonb_to_recordset(new_events) as event(event_key text, title text, url text, occurred_at timestamptz)
    on conflict (alert_id, event_key) do nothing;
    return true;
end;
$$;

revoke all on function public.claim_company_research_alerts(integer),
    public.finish_company_research_alert(uuid, uuid, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.claim_company_research_alerts(integer),
    public.finish_company_research_alert(uuid, uuid, boolean, text, jsonb) to service_role;
