-- Record material public corrections once on the source. A follower can see
-- the correction even if they joined after the original publication.
alter table public.corporate_actions add column source_revised_at timestamptz;
alter table public.funding_rounds add column source_revised_at timestamptz;

create function public.stamp_private_source_revision()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.source_revised_at := statement_timestamp();
  return new;
end;
$$;

create trigger private_corporate_action_revision
before update on public.corporate_actions for each row
when (old.published and new.published and old.published_at <= now()
  and (old.title, old.significance, old.source_url, old.published_at)
    is distinct from (new.title, new.significance, new.source_url, new.published_at))
execute function public.stamp_private_source_revision();

create trigger private_funding_round_revision
before update on public.funding_rounds for each row
when (old.published and new.published and old.announced_on <= (now() at time zone 'UTC')::date
  and (old.stage, old.raised, old.valuation, old.currency, old.source_url, old.announced_on, nullif(trim(old.traction), ''))
    is distinct from
      (new.stage, new.raised, new.valuation, new.currency, new.source_url, new.announced_on, nullif(trim(new.traction), '')))
execute function public.stamp_private_source_revision();

revoke all on function public.stamp_private_source_revision() from public, anon, authenticated, service_role;

create or replace view public.published_private_company_updates with (security_invoker = true) as
select a.id, a.company_id, c.name as company_name, a.title, a.significance,
       a.source_url, a.source_label, a.published_at, null::date as round_announced_on, a.source_revised_at
from public.corporate_actions a
join public.private_companies c on c.id = a.company_id and c.published
where a.published and a.published_at <= now()
union all
select r.id, r.company_id, c.name, r.stage || ' closed',
       'The source published the round close on ' || to_char(r.announced_on, 'YYYY-MM-DD') || '.' ||
       case when r.raised is null then '' else
         ' Reported capital raised was ' || r.currency || ' ' || trim_scale(r.raised)::text || '.' end ||
       case when r.valuation is null then '' else
         ' Reported valuation was ' || r.currency || ' ' || trim_scale(r.valuation)::text || '.' end ||
       case when nullif(trim(r.traction), '') is null then '' else ' ' || trim(r.traction) end,
       r.source_url, 'Funding round source', r.announced_on::timestamp at time zone 'UTC', r.announced_on, r.source_revised_at
from public.funding_rounds r
join public.private_companies c on c.id = r.company_id and c.published
where r.published and isfinite(r.announced_on)
  and r.announced_on <= (now() at time zone 'UTC')::date
  and exists (select 1 from public.investment_opportunities o
    where o.round_id = r.id and o.published and o.status = 'closed')
  and not exists (select 1 from public.investment_opportunities o
    where o.round_id = r.id and o.published and o.status in ('open', 'interest'))
  and not exists (select 1 from public.corporate_actions a
    where a.company_id = r.company_id and a.source_url = r.source_url
      and a.published and a.published_at <= now());

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
    select user_id, company_ids, eligible_opportunities
    from public.private_monitor_devices
    where refreshed_at >= now() - interval '90 days' and (p_user is null or user_id = p_user)
  ), monitored as materialized (
    select a.user_id, unnest(a.company_ids) as company_id from active a
    union
    select h.user_id, h.company_id from public.private_holdings h
      join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
      where h.confirmed_at is not null and k.status = 'confirmed' and h.company_id is not null
        and exists (select 1 from active a where a.user_id = h.user_id)
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

create or replace function public.private_market_digest_sources(p_user uuid, p_day date)
returns jsonb language sql stable set search_path = '' as $$
  with followed as materialized (
    select distinct unnest(d.company_ids) as company_id
    from public.private_monitor_devices d
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
