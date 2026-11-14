-- The announcement date describes the financing event. It is independent
-- of when Stock Tracker verified the source and of any offer deadline.
alter table public.funding_rounds add column announced_on date;

update public.funding_rounds as r
set announced_on = published_round.announced_on
from (values
  ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3402'::uuid, date '2022-07-06'),
  ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3403'::uuid, date '2023-10-24'),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e11'::uuid, date '2026-09-22'),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e12'::uuid, date '2026-07-15')
) as published_round(id, announced_on)
where r.id = published_round.id;

-- The issuer reported just over A$580,000. Keep that rounded figure in the
-- disclosure, since the exact proceeds are unavailable.
update public.funding_rounds
set source_url = 'https://gronggrongsolarfarm.com.au/grong-grong-solar-farms-2nd-csf-raise-now-officially-closed/',
    traction = 'The issuer reported raising just over A$580,000 for remaining construction costs.',
    verified_at = '2026-11-14 10:54:00+11'
where id = 'd83bc2fc-1a39-483f-a4d5-f02cbb1e3403';

update public.investment_opportunities
set source_url = 'https://gronggrongsolarfarm.com.au/grong-grong-solar-farms-2nd-csf-raise-now-officially-closed/',
    verified_at = '2026-11-14 10:54:00+11'
where round_id = 'd83bc2fc-1a39-483f-a4d5-f02cbb1e3403' and provider = 'birchal' and status = 'closed';

-- The Heidi Series B press release and the lead investor give the original
-- event date. AdvanCell's original release supplies the Series C date.
insert into public.funding_rounds
  (id, company_id, stage, raised, valuation, valuation_method, currency, announced_on, source_url, verified_at, published)
values
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e14', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e01', 'Series A follow-on',
    16600000, null, null, 'USD', date '2025-03-03',
    'https://www.heidihealth.com/en-us/blog/heidi-health-secures-usd-16-6m-in-funding-to-free-up-clinicians-to-focus-on-patient-care',
    '2026-11-14 10:54:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e15', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e01', 'Series B',
    65000000, 465000000, 'Issuer-reported round valuation. Methodology undisclosed.', 'USD', date '2025-10-06',
    'https://www.heidihealth.com/en-us/blog/heidi-series-b', '2026-11-14 10:54:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e16', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e02', 'Series C',
    112000000, null, null, 'USD', date '2025-02-03',
    'https://www.advancell.com.au/wp-content/uploads/2025/05/679ffe05b209a3b771be4523_Advancell-PR-_2025_0131_ADVC-FINAL.pdf',
    '2026-11-14 10:54:00+11', true);

insert into public.investment_opportunities
  (id, round_id, provider, category, status, eligibility, jurisdictions, source_url, verified_at, published)
select historical.opportunity_id, r.id, 'issuer', historical.category, 'closed', 'provider review',
       '{}'::text[], r.source_url, r.verified_at, true
from public.funding_rounds r
join (values
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e14'::uuid, 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e24'::uuid, 'Series A'),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e15'::uuid, 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e25'::uuid, 'Series B or later'),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e16'::uuid, 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e26'::uuid, 'Series B or later')
) as historical(round_id, opportunity_id, category) on r.id = historical.round_id;
