-- Provider-linked subscriptions keep their source separate from followed companies.
alter table public.private_monitor_devices
  add column provider_links jsonb not null default '[]'::jsonb
    check (jsonb_typeof(provider_links) = 'array' and jsonb_array_length(provider_links) <= 250);

-- Use the provider's settlement date, consistent with portfolio allocation.
create view public.private_market_owned_positions with (security_invoker = true) as
select h.id, h.user_id, h.company_id
from public.private_holdings h
join public.investment_commitments c on (c.id, c.user_id) = (h.commitment_id, h.user_id)
where c.status = 'confirmed' and h.confirmed_at <= now() and h.settled_amount is not null
  and not (h.remaining_units is not distinct from 0 and h.exit_source is not null
    and h.last_disposition_on is not null and h.last_disposition_on <= (now() at time zone 'Australia/Sydney')::date);

revoke all on public.private_market_owned_positions from public, anon, authenticated, service_role;

create view public.private_market_device_companies with (security_invoker = true) as
select d.user_id, d.device_id, unnest(d.company_ids) as company_id
from public.private_monitor_devices d
union all
select d.user_id, d.device_id, coalesce(h.company_id, linked.company_id)
from public.private_monitor_devices d
cross join lateral jsonb_to_recordset(d.provider_links) as linked(holding_id uuid, company_id uuid)
join public.private_market_owned_positions h on (h.id, h.user_id) = (linked.holding_id, d.user_id)
where (h.company_id is null or linked.company_id is null or h.company_id = linked.company_id)
  and coalesce(h.company_id, linked.company_id) is not null;

revoke all on public.private_market_device_companies from public, anon, authenticated, service_role;

create function public.configure_private_monitor_ownership(
  p_user uuid, p_device uuid, p_companies uuid[], p_eligible boolean, p_enabled boolean, p_digest boolean, p_links jsonb
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if jsonb_typeof(p_links) is distinct from 'array' or jsonb_array_length(p_links) > 250 then
    raise exception 'Invalid provider links' using errcode = '22023';
  end if;
  perform public.configure_private_monitor(p_user, p_device, p_companies, p_eligible, p_enabled, p_digest);
  if p_enabled then
    -- Keep valid exited links so they can resume after an authoritative correction.
    update public.private_monitor_devices d
    set provider_links = (
      select coalesce(jsonb_agg(jsonb_build_object('holding_id', allowed.id, 'company_id', allowed.company_id)
                             order by allowed.id), '[]'::jsonb)
      from (
        select distinct on (h.id) h.id, c.id as company_id
        from jsonb_to_recordset(p_links) as linked(holding_id uuid, company_id uuid)
        join public.private_holdings h on (h.id, h.user_id) = (linked.holding_id, p_user)
        join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id) and k.status = 'confirmed'
        left join public.private_companies c on c.id = linked.company_id and c.published
        where h.confirmed_at <= now() and h.settled_amount is not null
        order by h.id, c.id
      ) allowed
    )
    where (d.user_id, d.device_id) = (p_user, p_device);
  end if;
end $$;

revoke all on function public.configure_private_monitor_ownership(uuid,uuid,uuid[],boolean,boolean,boolean,jsonb)
  from public, anon, authenticated;
grant execute on function public.configure_private_monitor_ownership(uuid,uuid,uuid[],boolean,boolean,boolean,jsonb) to service_role;

create or replace function public.collect_private_market_alerts(p_user uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare affected integer;
begin
  if p_user is not null then
    perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text, 41));
  else
    perform pg_catalog.pg_advisory_xact_lock(412345, 41);
  end if;
  with active as materialized (
    select user_id, device_id, eligible_opportunities
    from public.private_monitor_devices
    where refreshed_at >= now() - interval '90 days' and (p_user is null or user_id = p_user)
  ), monitored as materialized (
    select a.user_id, tracked.company_id
    from active a join public.private_market_device_companies tracked using (user_id, device_id)
    union
    select h.user_id, h.company_id from public.private_market_owned_positions h
    where h.company_id is not null and exists (select 1 from active a where a.user_id = h.user_id)
  ), revised as (
    update public.private_market_alerts alert
    set title = current.title, significance = current.significance, source_url = current.source_url,
        source_label = current.source_label, occurred_at = current.published_at,
        revised_at = coalesce(current.source_revised_at, statement_timestamp()), recorded_at = statement_timestamp(), push_sequence = default
    from monitored m
    join public.published_private_company_updates current on current.company_id = m.company_id
    where (alert.user_id, alert.subject_id, alert.kind) = (m.user_id, current.id, 'announcement')
      and alert.recorded_at >= now() - interval '90 days'
      and (alert.title, alert.significance, alert.source_url, alert.occurred_at)
        is distinct from (current.title, current.significance, current.source_url, current.published_at)
    returning alert.user_id, alert.subject_id
  ), funding as materialized (
    select o.id, c.id as company_id, c.name, r.stage, o.status, o.verified_at,
           o.source_url, o.provider, o.eligibility, o.jurisdictions
    from public.investment_opportunities o
    join public.funding_rounds r on r.id = o.round_id and r.published
    join public.private_companies c on c.id = r.company_id and c.published
    where o.published and o.status in ('open', 'interest')
      and o.verified_at between now() - interval '24 hours' and now()
      and r.verified_at between now() - interval '24 hours' and now()
      and (r.closes_at > now() or (o.status = 'interest' and r.closes_at is null))
  ), events as (
    select m.user_id, a.id as subject_id, 'announcement' as kind, a.company_name,
           a.title, a.significance, a.source_url, a.source_label, a.published_at as occurred_at,
           a.source_revised_at as revised_at
    from monitored m
    join public.published_private_company_updates a on a.company_id = m.company_id
    where greatest(a.source_revised_at, a.published_at) >= now() - interval '7 days'
    union all
    select m.user_id, f.id, case f.status when 'open' then 'open_round' else 'interest' end, f.name, f.stage,
           case f.status when 'open' then 'The source listed the round as open at the recorded verification time.'
                        else 'The source published an expression of interest.' end,
           f.source_url, null, f.verified_at, null::timestamptz
    from monitored m join funding f on f.company_id = m.company_id
    union all
    select distinct a.user_id, f.id, 'eligible_round', f.name, f.stage,
           'This round matched your recorded provider classification when checked. Confirm current eligibility with the provider.',
           f.source_url, null, f.verified_at, null::timestamptz
    from active a
    join public.investor_profiles p on p.user_id = a.user_id and p.country = 'AU'
    join public.investor_eligibility e on e.user_id = a.user_id and e.jurisdiction = p.country
      and e.verified_at <= now() and e.expires_at > now()
    join public.provider_connections pc on (pc.id, pc.user_id, pc.provider) = (e.connection_id, e.user_id, e.provider)
      and pc.revoked_at is null
    join public.private_provider_approvals pa on pa.provider = e.provider and pa.jurisdiction = e.jurisdiction
      and pa.enabled and pa.expires_at > now()
    join public.private_market_rules rule on (rule.jurisdiction, rule.version) = (pa.jurisdiction, pa.rule_version)
      and rule.handoff_enabled and rule.reviewed_at <= now() and rule.effective_at <= now()
      and not exists (select 1 from public.private_market_rules newer
        where newer.jurisdiction = rule.jurisdiction and newer.effective_at <= now()
          and (newer.effective_at, newer.version) > (rule.effective_at, rule.version))
    join funding f on f.provider = e.provider and f.status = 'open' and p.country = any(f.jurisdictions)
      and (f.eligibility = 'retail' or (f.eligibility = 'wholesale' and e.verified_class = 'wholesale'))
    where a.eligible_opportunities and not exists (
      select 1 from monitored m where m.user_id = a.user_id and m.company_id = f.company_id)
    union all
    select call.user_id, call.id, 'capital_call', call.name, 'Capital call due',
           'A provider-recorded payment is due ' || to_char(call.due_on, 'YYYY-MM-DD') || '.',
           null, call.source, call.provider_event_at, null::timestamptz
    from public.private_due_capital_calls call
    where exists (select 1 from active a where a.user_id = call.user_id)
    union all
    select e.user_id, e.id, 'holding_exit', e.name, 'Provider confirmed exit',
           'The provider recorded that all units were sold.', null, e.source, e.provider_event_at, null::timestamptz
    from public.private_current_holding_exits e
    where e.provider_event_at >= now() - interval '7 days'
      and exists (select 1 from active a where a.user_id = e.user_id)
    union all
    select d.user_id, d.id, 'distribution', d.name, 'Provider recorded a distribution',
           'Received on ' || to_char(d.received_on, 'YYYY-MM-DD') || '.', null, d.source, d.provider_event_at, null::timestamptz
    from public.private_reported_distributions d
    where d.provider_event_at >= now() - interval '7 days'
      and exists (select 1 from active a where a.user_id = d.user_id)
  ), inserted as (
    insert into public.private_market_alerts
      (user_id, subject_id, kind, company_name, title, significance, source_url, source_label, occurred_at, revised_at)
    select e.user_id, e.subject_id, e.kind, e.company_name, e.title, e.significance, e.source_url, e.source_label, e.occurred_at, e.revised_at
    from events e
    where e.kind <> 'announcement' or not exists (
      select 1 from revised r where (r.user_id, r.subject_id) = (e.user_id, e.subject_id))
    on conflict (user_id, kind, subject_id) do nothing
    returning id
  )
  select (select count(*) from inserted) + (select count(*) from revised) into affected;
  return affected;
end $$;

create or replace function public.private_market_alert_inbox(p_user uuid)
returns table (id uuid, subject_id uuid, kind text, company_name text, title text,
  significance text, source_url text, source_label text, occurred_at timestamptz, recorded_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with active as materialized (
    select device_id, eligible_opportunities from public.private_monitor_devices
    where user_id = p_user and refreshed_at >= now() - interval '90 days'
  ), monitored as (
    select tracked.company_id
    from active a join public.private_market_device_companies tracked using (device_id)
    where tracked.user_id = p_user
    union
    select h.company_id from public.private_market_owned_positions h
    where h.user_id = p_user and h.company_id is not null
  )
  select n.id, n.subject_id, n.kind, n.company_name, coalesce(announcement.title, n.title),
         case when n.kind = 'capital_call' then 'A provider-recorded payment is due ' || to_char(call.due_on, 'YYYY-MM-DD') || '.'
              when n.kind = 'holding_exit' then
                'All units were sold. Settlement date: ' || to_char(holding_exit.settled_on, 'YYYY-MM-DD') || '.'
              when n.kind = 'distribution' then 'Received on ' || to_char(distribution.received_on, 'YYYY-MM-DD') || '.'
              when n.kind in ('open_round', 'eligible_round') and not coalesce(opportunity.status = 'open' and
                opportunity.verified_at between now() - interval '24 hours' and now() and
                round.verified_at between now() - interval '24 hours' and now() and round.closes_at > now(), false)
              then 'The source previously listed this round as open. Current availability is unverified.'
              else coalesce(announcement.significance, n.significance) end,
         coalesce(announcement.source_url, n.source_url), coalesce(announcement.source_label, holding_exit.source, distribution.source,
           case when n.kind = 'capital_call' then call.source else n.source_label end),
         case when n.kind = 'capital_call' then call.provider_event_at
              else coalesce(announcement.published_at, holding_exit.provider_event_at, distribution.provider_event_at, n.occurred_at) end, n.recorded_at
  from public.private_market_alerts n
  left join public.published_private_company_updates announcement on n.kind = 'announcement' and announcement.id = n.subject_id
  left join public.private_current_holding_exits holding_exit
    on n.kind = 'holding_exit' and (holding_exit.id, holding_exit.user_id) = (n.subject_id, p_user)
  left join public.private_reported_distributions distribution
    on n.kind = 'distribution' and (distribution.id, distribution.user_id) = (n.subject_id, p_user)
  left join public.private_due_capital_calls call on n.kind = 'capital_call' and (call.id, call.user_id) = (n.subject_id, p_user)
  left join public.investment_opportunities opportunity on n.kind in ('open_round', 'eligible_round') and opportunity.id = n.subject_id
  left join public.funding_rounds round on round.id = opportunity.round_id
  where n.user_id = p_user and exists (select 1 from active)
    and n.recorded_at >= now() - interval '90 days'
    and case n.kind
      when 'capital_call' then call.id is not null
      when 'holding_exit' then holding_exit.id is not null
      when 'distribution' then distribution.id is not null
      when 'announcement' then exists (
        select 1 from monitored m where m.company_id = announcement.company_id)
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

create or replace function public.private_market_push_through(p_user uuid, p_device uuid, p_after bigint)
returns bigint language sql stable set search_path = '' as $$
  with monitored as materialized (
    select company_id from public.private_market_device_companies
    where (user_id, device_id) = (p_user, p_device)
    union
    select company_id from public.private_market_owned_positions where user_id = p_user and company_id is not null
  )
  select max(n.push_sequence)
  from public.private_market_alerts n
  join public.private_monitor_devices d on d.user_id = n.user_id and d.device_id = p_device
  where n.user_id = p_user and n.push_sequence > p_after and n.recorded_at >= now() - interval '24 hours'
    and d.refreshed_at >= now() - interval '90 days'
    and case n.kind
      when 'announcement' then exists (
        select 1 from public.published_private_company_updates a
        where a.id = n.subject_id
          and exists (select 1 from monitored m where m.company_id = a.company_id))
      when 'holding_exit' then exists (
        select 1 from public.private_current_holding_exits e
        where (e.id, e.user_id) = (n.subject_id, p_user))
      when 'distribution' then exists (
        select 1 from public.private_reported_distributions a
        where (a.id, a.user_id) = (n.subject_id, p_user))
      when 'capital_call' then exists (
        select 1 from public.private_due_capital_calls a where (a.id, a.user_id) = (n.subject_id, p_user))
      else exists (
        select 1 from public.investment_opportunities o
        join public.funding_rounds r on r.id = o.round_id and r.published
        join public.private_companies c on c.id = r.company_id and c.published
        where o.id = n.subject_id and o.published
          and o.verified_at between now() - interval '24 hours' and now()
          and r.verified_at between now() - interval '24 hours' and now()
          and ((o.status = 'open' and r.closes_at > now() and n.kind in ('open_round', 'eligible_round'))
            or (o.status = 'interest' and n.kind = 'interest' and (r.closes_at > now() or r.closes_at is null)))
          and ((n.kind <> 'eligible_round' and exists (select 1 from monitored m where m.company_id = c.id))
            or (n.kind = 'eligible_round' and d.eligible_opportunities and exists (
              select 1 from public.investor_profiles p
              join public.investor_eligibility e on e.user_id = p.user_id and e.jurisdiction = p.country and e.provider = o.provider
              join public.provider_connections pc on (pc.id, pc.user_id, pc.provider) = (e.connection_id, e.user_id, e.provider)
              join public.private_provider_approvals pa on pa.provider = e.provider and pa.jurisdiction = e.jurisdiction
              join public.private_market_rules rule on (rule.jurisdiction, rule.version) = (pa.jurisdiction, pa.rule_version)
              where p.user_id = p_user and p.country = 'AU' and p.country = any(o.jurisdictions)
                and e.verified_at <= now() and e.expires_at > now() and pc.revoked_at is null
                and pa.enabled and pa.expires_at > now() and rule.handoff_enabled
                and rule.reviewed_at <= now() and rule.effective_at <= now()
                and not exists (select 1 from public.private_market_rules newer
                  where newer.jurisdiction = rule.jurisdiction and newer.effective_at <= now()
                    and (newer.effective_at, newer.version) > (rule.effective_at, rule.version))
                and (o.eligibility = 'retail' or (o.eligibility = 'wholesale' and e.verified_class = 'wholesale'))))))
    end;
$$;

create or replace function public.private_market_digest_sources(p_user uuid, p_day date)
returns jsonb language sql stable set search_path = '' as $$
  with followed as materialized (
    select distinct tracked.company_id
    from public.private_monitor_devices d
    join public.private_market_device_companies tracked using (user_id, device_id)
    where d.user_id = p_user and d.digest_enabled and d.refreshed_at >= now() - interval '90 days'
  ), recent as (
    select a.id, a.company_name, a.title, a.significance, a.source_url, a.published_at,
           a.source_revised_at, coalesce(a.source_revised_at, alert.revised_at) as revised_at,
           encode(sha256(convert_to(jsonb_build_array(a.company_name, a.title, a.significance,
             a.source_url, extract(epoch from a.published_at))::text, 'UTF8')), 'hex') as revision
    from followed f
    join public.published_private_company_updates a on a.company_id = f.company_id
    left join public.private_market_alerts alert
      on (alert.user_id, alert.kind, alert.subject_id) = (p_user, 'announcement', a.id)
    where greatest(a.published_at, coalesce(a.source_revised_at, alert.revised_at)) >= now() - interval '7 days'
  ), eligible as (
    select a.*, previous.finished_at is not null
      or coalesce(a.source_revised_at >= now() - interval '7 days', false) as is_revision
    from recent a
    left join lateral (
      select j.finished_at, j.source_revisions ->> a.id::text as revision
      from public.private_market_digest_jobs j
      where j.user_id = p_user and j.digest_day between p_day - 7 and p_day
        and j.finished_at is not null and a.id = any(j.source_ids)
      order by j.digest_day desc limit 1
    ) previous on true
    where previous.finished_at is null or case when previous.revision is null
      then coalesce(a.revised_at > previous.finished_at, false)
      else a.revision <> previous.revision end
    order by greatest(a.revised_at, a.published_at) desc, a.id
    limit 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'company', s.company_name, 'title', s.title, 'summary', s.significance,
    'url', s.source_url, 'published_at', s.published_at, 'is_revision', s.is_revision, 'revision', s.revision
  ) order by greatest(s.revised_at, s.published_at) desc, s.id), '[]'::jsonb)
  from eligible s;
$$;

-- Recheck scope before sending a claimed batch to the AI provider. The save
-- procedure independently rechecks it after the model completes.
create function public.private_market_digest_is_current(p_job uuid, p_lease uuid, p_sources jsonb)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.private_market_digest_jobs job
    where job.id = p_job and job.lease_token = p_lease and job.finished_at is null and job.next_attempt_at > now()
      and p_sources is not null and p_sources <> '[]'::jsonb
      and p_sources = public.private_market_digest_sources(job.user_id, job.digest_day)
  );
$$;

revoke all on function public.private_market_digest_is_current(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.private_market_digest_is_current(uuid,uuid,jsonb) to service_role;
notify pgrst, 'reload schema';
