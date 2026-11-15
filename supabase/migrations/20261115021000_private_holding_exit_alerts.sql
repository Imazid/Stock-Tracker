-- Provider-confirmed exits enter the existing opt-in monitoring inbox.
alter table public.private_market_alerts
  drop constraint private_market_alerts_kind_check,
  add constraint private_market_alerts_kind_check check
    (kind in ('announcement', 'open_round', 'interest', 'capital_call', 'eligible_round', 'holding_exit'));

-- A full exit is valid only while the position and its current settlement
-- agree. Direct grants are unnecessary: monitored access is through RPCs.
create index private_holdings_full_exit_owner on public.private_holdings (user_id)
  where confirmed_at is not null and remaining_units = 0;

create view public.private_current_holding_exits with (security_invoker = true) as
select active_sale.id, h.user_id, h.id as holding_id, h.name, active_sale.source,
       active_sale.settled_on, active_sale.provider_event_at
from public.private_holdings h
join public.investment_commitments c on (c.id, c.user_id) = (h.commitment_id, h.user_id)
cross join lateral (
  select d.id, d.source, d.settled_on, d.provider_event_at
  from public.private_holding_dispositions d
  where d.holding_id = h.id and d.user_id = h.user_id and not d.reversed
  order by d.settled_on desc, d.provider_event_at desc, d.id
  limit 1
) active_sale
where h.confirmed_at is not null and c.status = 'confirmed' and h.remaining_units = 0
  and h.last_disposition_on = active_sale.settled_on and h.exit_source = active_sale.source
  and active_sale.settled_on <= (now() at time zone 'Australia/Sydney')::date
  and active_sale.provider_event_at <= now();
revoke all on public.private_current_holding_exits from public, anon, authenticated, service_role;

create or replace function public.collect_private_market_alerts(p_user uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare inserted integer;
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
    select m.user_id, a.id as subject_id, 'announcement' as kind, c.name as company_name,
           a.title, a.significance, a.source_url, null::text as source_label, a.published_at as occurred_at
    from monitored m
    join public.private_companies c on c.id = m.company_id and c.published
    join public.corporate_actions a on a.company_id = c.id and a.published
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
    select h.user_id, call.id, 'capital_call', h.name, 'Capital call due',
           'A provider-recorded payment is due ' || to_char(call.due_on, 'YYYY-MM-DD') || '.',
           null, call.source, coalesce(call.provider_event_at, now())
    from public.capital_calls call
    join public.private_holdings h on (h.id, h.user_id) = (call.holding_id, call.user_id) and h.confirmed_at is not null
    join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id) and k.status = 'confirmed'
    where call.settled_on is null and call.provider_event_at is not null
      and call.due_on between (now() at time zone 'Australia/Sydney')::date
                          and (now() at time zone 'Australia/Sydney')::date + 7
      and exists (select 1 from active a where a.user_id = h.user_id)
    union all
    select e.user_id, e.id, 'holding_exit', e.name, 'Provider confirmed exit',
           'The provider recorded that all units were sold.', null, e.source, e.provider_event_at
    from public.private_current_holding_exits e
    where e.provider_event_at >= now() - interval '7 days'
      and exists (select 1 from active a where a.user_id = e.user_id)
  )
  insert into public.private_market_alerts
    (user_id, subject_id, kind, company_name, title, significance, source_url, source_label, occurred_at)
  select user_id, subject_id, kind, company_name, title, significance, source_url, source_label, occurred_at from events
  on conflict (user_id, kind, subject_id) do nothing;
  get diagnostics inserted = row_count;
  return inserted;
end $$;

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
              when n.kind = 'holding_exit' then
                'All units were sold. Settlement date: ' || to_char(holding_exit.settled_on, 'YYYY-MM-DD') || '.'
              when n.kind in ('open_round', 'eligible_round') and not coalesce(opportunity.status = 'open' and
                opportunity.verified_at between now() - interval '24 hours' and now() and
                round.verified_at between now() - interval '24 hours' and now() and round.closes_at > now(), false)
              then 'The source previously listed this round as open. Current availability is unverified.'
              else coalesce(announcement.significance, n.significance) end,
         n.source_url, coalesce(announcement.source_label, holding_exit.source,
           case when n.kind = 'capital_call' then call.source else n.source_label end),
         case when n.kind = 'capital_call' then call.provider_event_at
              else coalesce(announcement.published_at, holding_exit.provider_event_at, n.occurred_at) end, n.recorded_at
  from public.private_market_alerts n
  left join public.corporate_actions announcement on n.kind = 'announcement' and announcement.id = n.subject_id
  left join public.private_current_holding_exits holding_exit
    on n.kind = 'holding_exit' and (holding_exit.id, holding_exit.user_id) = (n.subject_id, p_user)
  left join public.capital_calls call on n.kind = 'capital_call' and (call.id, call.user_id) = (n.subject_id, p_user)
  left join public.investment_opportunities opportunity on n.kind in ('open_round', 'eligible_round') and opportunity.id = n.subject_id
  left join public.funding_rounds round on round.id = opportunity.round_id
  where n.user_id = p_user and exists (select 1 from active)
    and n.recorded_at >= now() - interval '90 days'
    and case n.kind
      when 'capital_call' then call.id is not null and call.settled_on is null
        and call.due_on between (now() at time zone 'Australia/Sydney')::date and (now() at time zone 'Australia/Sydney')::date + 7
      when 'holding_exit' then holding_exit.id is not null
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

create or replace function public.private_market_push_through(p_user uuid, p_device uuid, p_after bigint)
returns bigint language sql stable set search_path = '' as $$
  select max(n.push_sequence)
  from public.private_market_alerts n
  join public.private_monitor_devices d on d.user_id = n.user_id and d.device_id = p_device
  where n.user_id = p_user and n.push_sequence > p_after and n.recorded_at >= now() - interval '24 hours'
    and d.refreshed_at >= now() - interval '90 days'
    and case n.kind
      when 'announcement' then exists (
        select 1 from public.corporate_actions a join public.private_companies c on c.id = a.company_id and c.published
        where a.id = n.subject_id and a.published and a.published_at <= now()
          and (a.company_id = any(d.company_ids) or exists (
            select 1 from public.private_holdings h join public.investment_commitments k
              on (k.id, k.user_id) = (h.commitment_id, h.user_id)
            where h.user_id = p_user and h.company_id = a.company_id and h.confirmed_at is not null and k.status = 'confirmed')))
      when 'holding_exit' then exists (
        select 1 from public.private_current_holding_exits e
        where (e.id, e.user_id) = (n.subject_id, p_user))
      when 'capital_call' then exists (
        select 1 from public.capital_calls a join public.private_holdings h on (h.id, h.user_id) = (a.holding_id, a.user_id)
          join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
        where a.id = n.subject_id and a.user_id = p_user and a.settled_on is null and a.provider_event_at is not null
          and h.confirmed_at is not null and k.status = 'confirmed'
          and a.due_on between (now() at time zone 'Australia/Sydney')::date and (now() at time zone 'Australia/Sydney')::date + 7)
      else exists (
        select 1 from public.investment_opportunities o
        join public.funding_rounds r on r.id = o.round_id and r.published
        join public.private_companies c on c.id = r.company_id and c.published
        where o.id = n.subject_id and o.published
          and o.verified_at between now() - interval '24 hours' and now()
          and r.verified_at between now() - interval '24 hours' and now()
          and ((o.status = 'open' and r.closes_at > now() and n.kind in ('open_round', 'eligible_round'))
            or (o.status = 'interest' and n.kind = 'interest' and (r.closes_at > now() or r.closes_at is null)))
          and ((n.kind <> 'eligible_round' and (c.id = any(d.company_ids) or exists (
            select 1 from public.private_holdings h join public.investment_commitments k
              on (k.id, k.user_id) = (h.commitment_id, h.user_id)
            where h.user_id = p_user and h.company_id = c.id and h.confirmed_at is not null and k.status = 'confirmed')))
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
