-- Record changes to published evidence without treating re-verification as a correction.
alter table public.private_company_financials add column source_revised_at timestamptz;

create trigger private_financial_disclosure_revision
before update on public.private_company_financials for each row
when (old.published and new.published and old.verified_at <= now()
  and (old.period_end_on, old.period_kind, old.assurance, old.currency, old.revenue,
       old.annual_recurring_revenue, old.net_profit_loss, old.operating_cash_flow,
       old.cash_and_equivalents, old.published_on, old.source_url)
    is distinct from
      (new.period_end_on, new.period_kind, new.assurance, new.currency, new.revenue,
       new.annual_recurring_revenue, new.net_profit_loss, new.operating_cash_flow,
       new.cash_and_equivalents, new.published_on, new.source_url))
execute function public.stamp_private_source_revision();

create or replace view public.published_private_company_updates with (security_invoker = true) as
with financials as (
  select f.*
  from public.private_company_financials f
  where f.published and f.verified_at <= now()
    and f.published_on <= (now() at time zone 'Australia/Sydney')::date
), filings as (
  -- A filing can disclose several periods. Use its most recent period as the alert and citation.
  select distinct on (f.company_id, f.source_url) f.*
  from financials f
  order by f.company_id, f.source_url, f.period_end_on desc, f.period_kind, f.id
), updates as (
  select a.id, a.company_id, c.name as company_name, a.title, a.significance,
         a.source_url, a.source_label, a.published_at, null::date as round_announced_on, a.source_revised_at,
         null::date as financial_published_on
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
         r.source_url, 'Funding round source', r.announced_on::timestamp at time zone 'UTC', r.announced_on, r.source_revised_at, null::date
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
        and a.published and a.published_at <= now())
  union all
  select f.id, f.company_id, c.name,
         case when f.assurance = 'audited' then 'Audited financial results' else 'Issuer-reported financial update' end,
         'For the ' ||
         case f.period_kind
           when 'financial_year' then 'year ended ' || to_char(f.period_end_on, 'YYYY-MM-DD')
           else 'month of ' || to_char(f.period_end_on, 'YYYY-MM')
         end || ', the issuer disclosed ' ||
         concat_ws(', ',
           case when f.revenue is not null then 'revenue of ' || f.currency || ' ' || trim_scale(f.revenue) end,
           case when f.annual_recurring_revenue is not null then 'annual recurring revenue of ' || f.currency || ' ' || trim_scale(f.annual_recurring_revenue) end,
           case when f.net_profit_loss is not null then 'net profit or loss of ' || f.currency || ' ' || trim_scale(f.net_profit_loss) end,
           case when f.operating_cash_flow is not null then 'operating cash flow of ' || f.currency || ' ' || trim_scale(f.operating_cash_flow) end,
           case when f.cash_and_equivalents is not null then 'cash and cash equivalents of ' || f.currency || ' ' || trim_scale(f.cash_and_equivalents) end
         ) || '.' ||
         case when prior.assurance = 'audited' and f.assurance = 'audited'
                and f.revenue is not null and prior.revenue > 0 and prior.currency = f.currency then
           ' The same filing reported audited revenue of ' || f.currency || ' ' || trim_scale(prior.revenue) ||
           ' for the year ended ' || to_char(prior.period_end_on, 'YYYY-MM-DD') ||
           '. Audited revenue changed by ' || trim_scale(round(100 * (f.revenue - prior.revenue) / prior.revenue, 1)) || '%.'
         else '' end,
         f.source_url, 'Issuer financial disclosure',
         f.published_on::timestamp at time zone 'Australia/Sydney', null::date,
         greatest(f.source_revised_at, prior.source_revised_at), f.published_on
  from filings f
  join public.private_companies c on c.id = f.company_id and c.published
  left join financials prior on prior.company_id = f.company_id and prior.source_url = f.source_url
    and prior.period_kind = 'financial_year' and f.period_kind = 'financial_year'
    and prior.period_end_on = (f.period_end_on - interval '1 year')::date
)
select updates.*, greatest(published_at, source_revised_at) as activity_at from updates;
