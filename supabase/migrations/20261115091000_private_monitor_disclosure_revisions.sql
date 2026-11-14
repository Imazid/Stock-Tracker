-- Re-queue a published disclosure only when its stored material content changes.
-- The existing collector lock serializes both initial alerts and corrections.
alter table public.private_market_alerts add column revised_at timestamptz;

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
        revised_at = statement_timestamp(), recorded_at = statement_timestamp(), push_sequence = default
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
           a.title, a.significance, a.source_url, a.source_label, a.published_at as occurred_at
    from monitored m
    join public.published_private_company_updates a on a.company_id = m.company_id
    where a.published_at between now() - interval '7 days' and now()
    union all
    select m.user_id, f.id, case f.status when 'open' then 'open_round' else 'interest' end, f.name, f.stage,
           case f.status when 'open' then 'The source listed the round as open at the recorded verification time.'
                        else 'The source published an expression of interest.' end,
           f.source_url, null, f.verified_at
    from monitored m join funding f on f.company_id = m.company_id
    union all
    select distinct a.user_id, f.id, 'eligible_round', f.name, f.stage,
           'This round matched your recorded provider classification when checked. Confirm current eligibility with the provider.',
           f.source_url, null, f.verified_at
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
           null, call.source, call.provider_event_at
    from public.private_due_capital_calls call
    where exists (select 1 from active a where a.user_id = call.user_id)
    union all
    select e.user_id, e.id, 'holding_exit', e.name, 'Provider confirmed exit',
           'The provider recorded that all units were sold.', null, e.source, e.provider_event_at
    from public.private_current_holding_exits e
    where e.provider_event_at >= now() - interval '7 days'
      and exists (select 1 from active a where a.user_id = e.user_id)
    union all
    select d.user_id, d.id, 'distribution', d.name, 'Provider recorded a distribution',
           'Received on ' || to_char(d.received_on, 'YYYY-MM-DD') || '.', null, d.source, d.provider_event_at
    from public.private_reported_distributions d
    where d.provider_event_at >= now() - interval '7 days'
      and exists (select 1 from active a where a.user_id = d.user_id)
  ), inserted as (
    insert into public.private_market_alerts
      (user_id, subject_id, kind, company_name, title, significance, source_url, source_label, occurred_at)
    select e.user_id, e.subject_id, e.kind, e.company_name, e.title, e.significance, e.source_url, e.source_label, e.occurred_at
    from events e
    where e.kind <> 'announcement' or not exists (
      select 1 from revised r where (r.user_id, r.subject_id) = (e.user_id, e.subject_id))
    on conflict (user_id, kind, subject_id) do nothing
    returning id
  )
  select (select count(*) from inserted) + (select count(*) from revised) into affected;
  return affected;
end $$;

-- Keep the existing inbox interface for older workers. The authenticated Edge
-- function uses this projection to include a separate revision timestamp.
create function public.private_market_alert_inbox_with_revisions(p_user uuid)
returns table (id uuid, subject_id uuid, kind text, company_name text, title text,
  significance text, source_url text, source_label text, occurred_at timestamptz,
  recorded_at timestamptz, revised_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select inbox.*, alert.revised_at
  from public.private_market_alert_inbox(p_user) inbox
  join public.private_market_alerts alert on (alert.id, alert.user_id) = (inbox.id, p_user)
  order by inbox.recorded_at desc, inbox.id;
$$;

revoke all on function public.private_market_alert_inbox_with_revisions(uuid) from public, anon, authenticated;
grant execute on function public.private_market_alert_inbox_with_revisions(uuid) to service_role;
