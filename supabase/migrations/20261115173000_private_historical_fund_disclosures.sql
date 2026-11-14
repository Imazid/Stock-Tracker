-- Public reports of completed financings. Keep fund commitments separate from issuer equity proceeds.
alter table public.funding_rounds
  add column financing_structure text check (financing_structure in ('fund', 'spv')),
  add column capital_commitments numeric(20,4)
    check (capital_commitments is null or (capital_commitments > 0 and financing_structure is not distinct from 'fund'));

with disclosures(company_id, round_id, opportunity_id, company_name, sector, country, description, company_url,
                 stage, category, financing_structure, capital_commitments, currency, announced_on, source_url) as (
  values
    ('8d0edeaf-c9b8-41ae-ac04-590d7643bcc0'::uuid, '00128d15-425d-47d8-98e1-bc18e1c325be'::uuid,
     'd959a869-785e-465c-9af8-978d10f608cd'::uuid, 'Blackbird', 'Venture capital', 'AU',
     'Venture capital manager investing in Australian and New Zealand founders.',
     'https://www.blackbird.vc/about-blackbird',
     '2026 early-stage and growth funds', 'Venture fund', 'fund', 1050000000, 'AUD', date '2026-08-25',
     'https://www.blackbird.vc/blog/a-billion-reasons-to-invest-right-at-the-very-beginning'),
    ('ed291c50-7641-414c-ae85-a84255e09eef', '591e60a5-b4e7-4919-a57e-40e8cd4fe2d4',
     '7e62db81-26b8-4807-b211-fa738b0d816a', 'Pacific Equity Partners', 'Private equity', 'AU',
     'Australian private markets manager advising a range of investment strategies.',
     'https://www.pep.com.au/',
     'Fund VII', 'Private equity', 'fund', 3200000000, 'AUD', date '2025-08-05',
     'https://www.ocorian.com/knowledge-hub/news/pacific-equity-partners-fund-vii-raise-complete-3200-million-hard-cap'),
    ('4fa7b8d4-29de-480e-97e0-7871078eb85d', '34469849-92f5-4093-8a13-12777702a517',
     '9009357f-e507-43b0-9eba-76944953e4aa', 'Secureframe', 'Security and compliance software', 'US',
     'Builds software for security and compliance programmes.',
     'https://secureframe.com/',
     'Roll Up Vehicle', 'Syndicate or SPV', 'spv', null, 'USD', null,
     'https://www.angellist.com/blog/secureframe-roll-up-vehicle-case-study')
), companies as (
  insert into public.private_companies (id, name, sector, country, description, source_url, verified_at, published)
  select company_id, company_name, sector, country, description, company_url, '2026-11-14 23:21:00+00', true
  from disclosures
  returning id
), rounds as (
  insert into public.funding_rounds
    (id, company_id, stage, financing_structure, capital_commitments, currency, announced_on, source_url, verified_at, published)
  select d.round_id, c.id, d.stage, d.financing_structure, d.capital_commitments, d.currency, d.announced_on,
    d.source_url, '2026-11-14 23:21:00+00', true
  from disclosures d join companies c on c.id = d.company_id
  returning id, source_url, verified_at
)
insert into public.investment_opportunities
  (id, round_id, provider, category, status, eligibility, jurisdictions, source_url, verified_at, published)
select d.opportunity_id, r.id, 'issuer', d.category, 'closed', 'provider review', '{}'::text[], r.source_url, r.verified_at, true
from disclosures d join rounds r on r.id = d.round_id;

create or replace trigger private_funding_round_revision
before update on public.funding_rounds for each row
when (old.published and new.published and old.announced_on <= (now() at time zone 'UTC')::date
  and (old.stage, old.raised, old.valuation, old.currency, old.source_url, old.announced_on, nullif(trim(old.traction), ''),
       old.financing_structure, old.capital_commitments)
    is distinct from
      (new.stage, new.raised, new.valuation, new.currency, new.source_url, new.announced_on, nullif(trim(new.traction), ''),
       new.financing_structure, new.capital_commitments))
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
         case r.financing_structure
           when 'fund' then 'The source reported the completed fundraise on '
           when 'spv' then 'The source reported the closed vehicle on '
           else 'The source published the round close on '
         end || to_char(r.announced_on, 'YYYY-MM-DD') || '.' ||
         case when r.capital_commitments is null then '' else
           ' Reported capital commitments were ' || r.currency || ' ' || trim_scale(r.capital_commitments)::text || '.' end ||
         case when r.raised is null then '' else
           ' Reported capital raised was ' || r.currency || ' ' || trim_scale(r.raised)::text || '.' end ||
         case when r.valuation is null then '' else
           ' Reported valuation was ' || r.currency || ' ' || trim_scale(r.valuation)::text || '.' end ||
         case when nullif(trim(r.traction), '') is null then '' else ' ' || trim(r.traction) end,
         r.source_url, case r.financing_structure
           when 'fund' then 'Fund disclosure' when 'spv' then 'Vehicle disclosure'
           else 'Funding round source' end, r.announced_on::timestamp at time zone 'UTC', r.announced_on, r.source_revised_at, null::date
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
