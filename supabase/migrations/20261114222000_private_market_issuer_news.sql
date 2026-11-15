-- Public newsroom metadata enriches company updates. The adapter cannot
-- publish offer terms, valuations, eligibility or investment routes.
alter table public.corporate_actions
  add column source_label text,
  add column newsroom_seen_at timestamptz;

create unique index corporate_actions_newsroom_url
  on public.corporate_actions (company_id, source_url) where newsroom_seen_at is not null;

create table public.private_issuer_news_refresh (
  company_id uuid primary key references public.private_companies(id) on delete cascade,
  etag text check (length(etag) <= 160),
  next_check_at timestamptz not null default now(),
  last_checked_at timestamptz,
  last_success_at timestamptz,
  last_error text,
  lease uuid
);
alter table public.private_issuer_news_refresh enable row level security;
revoke all on public.private_issuer_news_refresh from public, anon, authenticated, service_role;

insert into public.private_issuer_news_refresh (company_id)
values ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e02');

create function public.claim_private_issuer_news()
returns table (company uuid, token uuid, etag text)
language sql security definer set search_path = '' as $$
  update public.private_issuer_news_refresh r
    set next_check_at = now() + interval '5 minutes', lease = gen_random_uuid()
    where r.company_id = 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e02'
      and r.next_check_at <= now()
      and exists (select 1 from public.private_companies c where c.id = r.company_id and c.published)
  returning r.company_id, r.lease, r.etag;
$$;

create function public.finish_private_issuer_news(
  p_company uuid, p_token uuid, p_etag text, p_notices jsonb, p_error text, p_retry_seconds integer
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  written integer;
begin
  perform 1 from public.private_issuer_news_refresh r
    where (r.company_id, r.lease) = (p_company, p_token) and r.next_check_at > now()
    for update;
  if not found then return 0; end if;

  if p_notices is null or jsonb_typeof(p_notices) <> 'array' or jsonb_array_length(p_notices) > 10
    or p_company <> 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e02' then
    raise exception 'Invalid newsroom results' using errcode = '22023';
  end if;

  insert into public.corporate_actions
    (company_id, title, significance, published_at, source_url, source_label, newsroom_seen_at, published)
  select p_company, n.title, n.significance, n.published_at, n.source_url, 'AdvanCell newsroom', now(), true
  from jsonb_to_recordset(p_notices) as n(title text, significance text, published_at timestamptz, source_url text)
  where n.published_at between now() - interval '180 days' and now()
    and n.source_url ~ '^https://www[.]advancell[.]com[.]au/news/[a-z0-9-]{1,240}/$'
    and length(n.title) between 1 and 160 and length(n.significance) between 1 and 500
    and exists (select 1 from public.private_companies c where c.id = p_company and c.published)
    and not exists (
      select 1 from public.corporate_actions old
      where old.company_id = p_company and old.source_url = n.source_url and old.newsroom_seen_at is null
    )
  on conflict (company_id, source_url) where newsroom_seen_at is not null do update
    set title = excluded.title, significance = excluded.significance, published_at = excluded.published_at
    where (corporate_actions.title, corporate_actions.significance, corporate_actions.published_at)
      is distinct from (excluded.title, excluded.significance, excluded.published_at);
  get diagnostics written = row_count;

  update public.private_issuer_news_refresh r set
    lease = null, etag = p_etag, last_checked_at = now(),
    last_success_at = case when p_error is null then now() else r.last_success_at end,
    last_error = left(p_error, 80),
    next_check_at = now() + case when p_error is null then interval '6 hours'
      else make_interval(secs => greatest(3600, least(coalesce(p_retry_seconds, 3600), 86400))) end
    where r.company_id = p_company;
  return written;
end $$;

create function public.invoke_private_issuer_news()
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  worker_url text;
  worker_secret text;
  request_id bigint;
begin
  if pg_catalog.to_regclass('vault.decrypted_secrets') is null or
    not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') or
    not exists (select 1 from public.private_issuer_news_refresh r
      join public.private_companies c on c.id = r.company_id and c.published where r.next_check_at <= now())
    then return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_url using 'private_market_digest_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into worker_secret using 'private_market_digest_secret';
  if coalesce(worker_url, '') = '' or coalesce(worker_secret, '') = '' then return null; end if;
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 55000)'
    into request_id using worker_url, jsonb_build_object(
      'content-type', 'application/json', 'x-scheduler-secret', worker_secret
    ), '{"action":"scheduled_issuer_news"}'::jsonb;
  return request_id;
end $$;

revoke all on function public.claim_private_issuer_news(),
  public.finish_private_issuer_news(uuid,uuid,text,jsonb,text,integer), public.invoke_private_issuer_news()
  from public, anon, authenticated, service_role;
grant execute on function public.claim_private_issuer_news(),
  public.finish_private_issuer_news(uuid,uuid,text,jsonb,text,integer) to service_role;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
    and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    execute $job$select cron.schedule('private-market-issuer-news', '7 * * * *',
      'select public.invoke_private_issuer_news()')$job$;
  end if;
end $$;

-- Resolve edited newsroom metadata from the published source on read.
create or replace function public.private_market_alert_inbox(p_user uuid)
returns table (id uuid, subject_id uuid, kind text, company_name text, title text,
  significance text, source_url text, source_label text, occurred_at timestamptz, recorded_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with active as materialized (
    select company_ids, eligible_opportunities from public.private_monitor_devices
    where user_id = p_user and refreshed_at >= now() - interval '90 days'
  ), monitored as (
    select unnest(company_ids) as company_id from active
    union
    select h.company_id from public.private_holdings h
    join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
    where h.user_id = p_user and h.confirmed_at is not null and k.status = 'confirmed'
  )
  select n.id, n.subject_id, n.kind, n.company_name, coalesce(announcement.title, n.title),
         case when n.kind = 'capital_call' then 'A provider-recorded payment is due ' || to_char(call.due_on, 'YYYY-MM-DD') || '.'
              when n.kind in ('open_round', 'eligible_round') and not coalesce(opportunity.status = 'open' and
                opportunity.verified_at between now() - interval '24 hours' and now() and
                round.verified_at between now() - interval '24 hours' and now() and round.closes_at > now(), false)
              then 'The source previously listed this round as open. Current availability is unverified.'
              else coalesce(announcement.significance, n.significance) end,
         n.source_url, coalesce(announcement.source_label, case when n.kind = 'capital_call' then call.source else n.source_label end),
         case when n.kind = 'capital_call' then call.provider_event_at else coalesce(announcement.published_at, n.occurred_at) end, n.recorded_at
  from public.private_market_alerts n
  left join public.corporate_actions announcement on n.kind = 'announcement' and announcement.id = n.subject_id
  left join public.capital_calls call on n.kind = 'capital_call' and (call.id, call.user_id) = (n.subject_id, p_user)
  left join public.investment_opportunities opportunity on n.kind in ('open_round', 'eligible_round') and opportunity.id = n.subject_id
  left join public.funding_rounds round on round.id = opportunity.round_id
  where n.user_id = p_user and exists (select 1 from active)
    and n.recorded_at >= now() - interval '90 days'
    and case n.kind
      when 'capital_call' then call.id is not null and call.settled_on is null
        and call.due_on between (now() at time zone 'Australia/Sydney')::date and (now() at time zone 'Australia/Sydney')::date + 7
      when 'announcement' then exists (
        select 1 from public.corporate_actions a join public.private_companies c on c.id = a.company_id and c.published
          join monitored m on m.company_id = c.id where a.id = n.subject_id and a.published and a.published_at <= now())
      else exists (
        select 1 from public.investment_opportunities o
          join public.funding_rounds r on r.id = o.round_id and r.published
          join public.private_companies c on c.id = r.company_id and c.published
        where o.id = n.subject_id and o.published and (
          (n.kind = 'eligible_round' and exists (select 1 from active where eligible_opportunities)) or
          (n.kind <> 'eligible_round' and exists (select 1 from monitored m where m.company_id = c.id))))
    end
  order by n.recorded_at desc, n.id
  limit 100;
$$;
