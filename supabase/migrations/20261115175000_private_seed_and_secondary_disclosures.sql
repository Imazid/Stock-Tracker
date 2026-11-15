-- A purchase of existing shares is separate from primary capital raised.
alter table public.funding_rounds
  add column secondary_purchase_amount numeric(20,4),
  add column secondary_closed_on date,
  add constraint funding_rounds_secondary_purchase_check check (
    (secondary_purchase_amount is null and secondary_closed_on is null)
    or (raised is null and target is null and financing_structure is null
      and (secondary_purchase_amount is null or secondary_purchase_amount > 0)
      and (secondary_closed_on is null or isfinite(secondary_closed_on)))
  );

insert into public.private_companies
  (id, name, sector, country, description, founders, investors, source_url, verified_at, published)
values
  ('d77d17a6-a9e8-4580-bdfe-e26915e36dc5', 'Adora', 'Product analytics software', 'AU',
   'Builds analytics tools that help teams understand how people use their software.',
   array['Nathan Scully', 'Omar Salem'],
   array['Blackbird', 'Skip Capital', 'Designer Fund', 'Garuda Ventures', 'Co Ventures'],
   'https://www.blackbird.vc/portfolio/adora', '2026-11-15 00:55:00+00', true),
  ('2bf9569c-da32-4b8b-9f82-dddb7dfd3d87', 'Figma', 'Design software', 'US',
   'Collaborative design and product development software. Figma began trading on the NYSE in July 2025 under the symbol FIG.',
   null, null, 'https://www.figma.com/blog/figma-ipo-founder-letter/', '2026-11-15 00:55:00+00', true);

insert into public.funding_rounds
  (id, company_id, stage, raised, secondary_purchase_amount, secondary_closed_on,
   currency, announced_on, source_url, verified_at, published)
values
  ('0aa57025-14d6-4dab-994d-6103accd04a4', 'd77d17a6-a9e8-4580-bdfe-e26915e36dc5', 'Seed',
   7000000, null, null, 'USD', date '2026-02-11',
   'https://www.blackbird.vc/blog/investment-notes-adora-seed', '2026-11-15 00:55:00+00', true),
  ('56c8601b-50ef-4f86-977d-1db321c256a4', '2bf9569c-da32-4b8b-9f82-dddb7dfd3d87',
   '2024 pre-IPO tender offer', null, 566700000, date '2024-07-03', 'USD', date '2025-07-01',
   'https://www.sec.gov/Archives/edgar/data/1579878/000162828025033742/figma-sx1.htm',
   '2026-11-15 00:55:00+00', true);

insert into public.investment_opportunities
  (id, round_id, provider, category, status, eligibility, jurisdictions, source_url, verified_at, published)
select records.id, r.id, 'issuer', records.category, 'closed', 'provider review', '{}'::text[],
       r.source_url, r.verified_at, true
from (values
  ('aeb3425b-bda0-4ad2-98cc-7cc75ef87ed5'::uuid, '0aa57025-14d6-4dab-994d-6103accd04a4'::uuid, 'Seed or angel'),
  ('0fa8a227-cf78-4a6c-9acb-593620756b26'::uuid, '56c8601b-50ef-4f86-977d-1db321c256a4'::uuid, 'Private secondary')
) records(id, round_id, category)
join public.funding_rounds r on r.id = records.round_id;

create or replace trigger private_funding_round_revision
before update on public.funding_rounds for each row
when (old.published and new.published and old.announced_on <= (now() at time zone 'UTC')::date
  and (old.stage, old.raised, old.valuation, old.currency, old.source_url, old.announced_on, nullif(trim(old.traction), ''),
       old.financing_structure, old.capital_commitments, old.secondary_purchase_amount, old.secondary_closed_on)
    is distinct from
      (new.stage, new.raised, new.valuation, new.currency, new.source_url, new.announced_on, nullif(trim(new.traction), ''),
       new.financing_structure, new.capital_commitments, new.secondary_purchase_amount, new.secondary_closed_on))
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
         case
           when r.secondary_closed_on is not null or r.secondary_purchase_amount is not null
             then 'The source disclosed the secondary transaction on '
           when r.financing_structure = 'fund' then 'The source reported the completed fundraise on '
           when r.financing_structure = 'spv' then 'The source reported the closed vehicle on '
           else 'The source published the round close on '
         end || to_char(r.announced_on, 'YYYY-MM-DD') || '.' ||
         case when r.secondary_closed_on is null then '' else
           ' The transaction closed on ' || to_char(r.secondary_closed_on, 'YYYY-MM-DD') || '.' end ||
         case when r.secondary_purchase_amount is null then '' else
           ' Reported secondary purchase amount was ' || r.currency || ' ' || trim_scale(r.secondary_purchase_amount)::text || '.' end ||
         case when r.capital_commitments is null then '' else
           ' Reported capital commitments were ' || r.currency || ' ' || trim_scale(r.capital_commitments)::text || '.' end ||
         case when r.raised is null then '' else
           ' Reported capital raised was ' || r.currency || ' ' || trim_scale(r.raised)::text || '.' end ||
         case when r.valuation is null then '' else
           ' Reported valuation was ' || r.currency || ' ' || trim_scale(r.valuation)::text || '.' end ||
         case when nullif(trim(r.traction), '') is null then '' else ' ' || trim(r.traction) end,
         r.source_url, case
           when r.secondary_closed_on is not null or r.secondary_purchase_amount is not null then 'Secondary disclosure'
           when r.financing_structure = 'fund' then 'Fund disclosure'
           when r.financing_structure = 'spv' then 'Vehicle disclosure'
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
