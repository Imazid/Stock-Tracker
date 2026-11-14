-- A provider can withdraw an outstanding capital call. Keep its last terms
-- and cancellation evidence without creating a cash flow or a reminder.
alter table public.capital_calls
  add column cancelled_at timestamptz,
  add column cancellation_source text,
  add constraint private_capital_call_cancellation_evidence check (
    (cancelled_at is null and cancellation_source is null)
    or (cancelled_at is not null and isfinite(cancelled_at) and settled_on is null
      and provider_reference is not null and provider_event_at is not null and cancelled_at > provider_event_at
      and cancellation_source is not null and length(trim(cancellation_source)) between 1 and 400)
  );

alter table public.investment_audit_logs
  add column provider_event_at timestamptz,
  add column source text;

create or replace function public.record_private_holding_activity(
  p_provider text,
  p_subject text,
  p_holding uuid,
  p_kind text,
  p_reference text,
  p_event_at timestamptz,
  p_amount numeric,
  p_currency text,
  p_record_date date,
  p_source text,
  p_method text default null,
  p_settled_on date default null
) returns boolean language plpgsql set search_path = '' as $$
declare
  holding public.private_holdings%rowtype;
  affected integer;
  prior public.distributions%rowtype;
  prior_call public.capital_calls%rowtype;
begin
  if p_kind is null or p_kind not in ('valuation','capital_call','capital_call_cancellation','distribution','distribution_reversal','opening_settlement') or
     nullif(trim(p_reference), '') is null or length(p_reference) > 200 or
     nullif(trim(p_source), '') is null or length(p_source) > 400 or
     p_event_at is null or not isfinite(p_event_at) or p_event_at > now() or
     (p_kind in ('distribution_reversal','capital_call_cancellation') and (p_amount is not null or p_record_date is not null or p_method is not null)) or
     (p_kind not in ('distribution_reversal','capital_call_cancellation') and (
       p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or
       p_amount < 0 or (p_kind <> 'valuation' and p_amount = 0) or
       p_amount >= 10000000000000000 or p_amount <> round(p_amount, 4) or
       p_record_date is null or not isfinite(p_record_date) or
       (p_kind <> 'capital_call' and p_record_date > (p_event_at at time zone 'UTC')::date + 1))) or
     (p_settled_on is not null and
       (p_kind <> 'capital_call' or not isfinite(p_settled_on) or p_settled_on > (p_event_at at time zone 'UTC')::date + 1)) or
     (p_kind = 'valuation' and (nullif(trim(p_method), '') is null or length(p_method) > 400)) then
    raise exception 'Invalid position record' using errcode = '22023';
  end if;

  select h.* into holding from public.private_holdings h
    join public.investment_commitments c on (c.id,c.user_id) = (h.commitment_id,h.user_id)
    join public.provider_connections pc on pc.user_id = h.user_id and pc.provider = c.provider and pc.revoked_at is null
    join public.private_provider_approvals a on a.provider = c.provider and a.jurisdiction = c.jurisdiction
    where h.id = p_holding and h.confirmed_at is not null and c.status = 'confirmed'
      and c.provider = p_provider and pc.external_subject = p_subject
      and (c.provider_connection_id is null or c.provider_connection_id = pc.id)
      and a.holding_activity_enabled and a.expires_at > now()
    for update of h for share of c, pc, a;
  if not found then
    raise exception 'Position record unavailable for this provider account' using errcode = '42501';
  end if;
  if p_currency is distinct from holding.currency then
    raise exception 'Record currency must match the position currency' using errcode = '22023';
  end if;

  case p_kind
  when 'valuation' then
    insert into public.valuation_history as current
      (user_id, holding_id, value, valued_on, source, methodology, provider_reference, provider_event_at)
    values (holding.user_id, holding.id, p_amount, p_record_date, trim(p_source), trim(p_method), p_reference, p_event_at)
    on conflict (holding_id, provider_reference) do update
      set value = excluded.value, valued_on = excluded.valued_on, source = excluded.source,
          methodology = excluded.methodology, provider_event_at = excluded.provider_event_at
      where current.provider_event_at < excluded.provider_event_at;
  when 'capital_call' then
    insert into public.capital_calls as current
      (user_id, holding_id, amount, due_on, settled_on, source, provider_reference, provider_event_at)
    values (holding.user_id, holding.id, p_amount, p_record_date, p_settled_on, trim(p_source), p_reference, p_event_at)
    on conflict (holding_id, provider_reference) do update
      set amount = excluded.amount, due_on = excluded.due_on, settled_on = excluded.settled_on,
          source = excluded.source, provider_event_at = excluded.provider_event_at,
          cancelled_at = null, cancellation_source = null
      where greatest(current.provider_event_at, current.cancelled_at) < excluded.provider_event_at;
  when 'capital_call_cancellation' then
    select c.* into prior_call from public.capital_calls c
      where (c.holding_id, c.user_id, c.provider_reference) = (holding.id, holding.user_id, p_reference)
        and c.provider_event_at is not null
      for update;
    if not found then
      raise exception 'A cancellation must identify a recorded capital call' using errcode = '22023';
    end if;
    if greatest(prior_call.provider_event_at, prior_call.cancelled_at) >= p_event_at then return false; end if;
    if prior_call.settled_on is not null then
      raise exception 'A paid capital call requires a corrected payment record before cancellation' using errcode = '22023';
    end if;
    update public.capital_calls set cancelled_at = p_event_at, cancellation_source = trim(p_source)
      where id = prior_call.id;
    insert into public.investment_audit_logs (user_id, action, subject_id, provider_event_at, source)
      values (holding.user_id, 'provider_capital_call_cancellation', prior_call.id, p_event_at, trim(p_source));
    return true;
  when 'distribution' then
    -- Keep existing provider references exactly as received. A newer record
    -- can reinstate a reversed payment under the same stable identity.
    insert into public.distributions as current
      (user_id, holding_id, amount, received_on, source, provider_reference, provider_event_at)
    values (holding.user_id, holding.id, p_amount, p_record_date, trim(p_source), p_reference, p_event_at)
    on conflict (holding_id, provider_reference) do update
      set amount = excluded.amount, received_on = excluded.received_on, source = excluded.source,
          provider_event_at = excluded.provider_event_at, reversed_at = null, reversal_source = null
      where greatest(current.provider_event_at, current.reversed_at) < excluded.provider_event_at;
  when 'distribution_reversal' then
    select d.* into prior from public.distributions d
      where (d.holding_id, d.user_id, d.provider_reference) = (holding.id, holding.user_id, p_reference)
        and d.provider_event_at is not null
      for update;
    if not found then
      raise exception 'A reversal must identify a recorded distribution' using errcode = '22023';
    end if;
    if greatest(prior.provider_event_at, prior.reversed_at) >= p_event_at then return false; end if;
    update public.distributions set reversed_at = p_event_at, reversal_source = trim(p_source)
      where id = prior.id;
  when 'opening_settlement' then
    if p_amount is distinct from holding.settled_amount or p_record_date > (holding.confirmed_at at time zone 'UTC')::date + 1 then
      raise exception 'Opening settlement must match confirmed capital' using errcode = '22023';
    end if;
    if holding.settled_on is not null and
      (holding.settled_on is distinct from p_record_date or holding.settlement_source is distinct from trim(p_source)) then
      raise exception 'Opening settlement conflicts with a recorded source or date' using errcode = '23505';
    end if;
    update public.private_holdings set settled_on = p_record_date, settlement_source = trim(p_source)
      where id = holding.id and settled_on is null;
  end case;
  get diagnostics affected = row_count;
  if affected > 0 then
    insert into public.investment_audit_logs (user_id, action, subject_id)
    values (holding.user_id, 'provider_' || p_kind, holding.id);
  end if;
  return affected > 0;
end $$;

-- All three monitoring paths use the same currently due obligations.
create view public.private_due_capital_calls with (security_invoker = true) as
select call.id, call.user_id, h.name, call.due_on, call.source, call.provider_event_at
from public.capital_calls call
join public.private_holdings h on (h.id, h.user_id) = (call.holding_id, call.user_id)
join public.investment_commitments k on (k.id, k.user_id) = (h.commitment_id, h.user_id)
where h.confirmed_at is not null and k.status = 'confirmed'
  and call.settled_on is null and call.cancelled_at is null and call.provider_event_at <= now()
  and call.due_on between (now() at time zone 'Australia/Sydney')::date
                      and (now() at time zone 'Australia/Sydney')::date + 7;
revoke all on public.private_due_capital_calls from public, anon, authenticated, service_role;

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
  select max(n.push_sequence)
  from public.private_market_alerts n
  join public.private_monitor_devices d on d.user_id = n.user_id and d.device_id = p_device
  where n.user_id = p_user and n.push_sequence > p_after and n.recorded_at >= now() - interval '24 hours'
    and d.refreshed_at >= now() - interval '90 days'
    and case n.kind
      when 'announcement' then exists (
        select 1 from public.published_private_company_updates a
        where a.id = n.subject_id
          and (a.company_id = any(d.company_ids) or exists (
            select 1 from public.private_holdings h join public.investment_commitments k
              on (k.id, k.user_id) = (h.commitment_id, h.user_id)
            where h.user_id = p_user and h.company_id = a.company_id and h.confirmed_at is not null and k.status = 'confirmed')))
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
