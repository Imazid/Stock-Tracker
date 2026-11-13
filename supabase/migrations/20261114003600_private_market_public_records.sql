-- Historical issuer-published facts, with independent primary references. No
-- campaign is open or enabled for handoff. Leave undisclosed fields as NULL.
insert into public.private_companies
  (id, name, sector, country, location, description, founders, source_url, verified_at, published)
values ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3401', 'Grong Grong Solar Farm',
  'Renewable energy', 'AU', 'Grong Grong, NSW',
  'Community-owned solar generation project in the NSW Riverina.',
  array['Jonathan Prendergast','Gerald Arends'], 'https://gronggrongsolarfarm.com.au/about/',
  '2026-11-14 00:00:00+11', true);

insert into public.funding_rounds
  (id, company_id, stage, raised, target, currency, source_url, verified_at, published)
values
  ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3402', 'd83bc2fc-1a39-483f-a4d5-f02cbb1e3401',
    '2022 crowd-sourced funding', 750000, 750000, 'AUD',
    'https://gronggrongsolarfarm.com.au/grong-grong-solar-farm-completes-successful-csf-raise/',
    '2026-11-14 00:00:00+11', true),
  ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3403', 'd83bc2fc-1a39-483f-a4d5-f02cbb1e3401',
    '2023 crowd-sourced funding', null, null, 'AUD', 'https://gronggrongsolarfarm.com.au/news/',
    '2026-11-14 00:00:00+11', true);

insert into public.investment_opportunities
  (round_id, provider, category, status, eligibility, jurisdictions, source_url, offer_document_url, verified_at, published)
values
  ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3402', 'birchal', 'Crowdfunding', 'closed', 'retail', array['AU'],
    'https://gronggrongsolarfarm.com.au/grong-grong-solar-farm-completes-successful-csf-raise/',
    'https://gronggrongsolarfarm.com.au/wp-content/uploads/2022/06/Grong-Grong-Solar-Farm-CSF-Offer-Document-2022-06-15.pdf',
    '2026-11-14 00:00:00+11', true),
  ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3403', 'birchal', 'Crowdfunding', 'closed', 'retail', array['AU'],
    'https://gronggrongsolarfarm.com.au/how-to-invest/', null,
    '2026-11-14 00:00:00+11', true);

insert into public.corporate_actions (company_id, title, significance, published_at, source_url, published)
values ('d83bc2fc-1a39-483f-a4d5-f02cbb1e3401', 'Solar farm commissioning',
  'The company reported partial electricity generation and supply into the local network during commissioning.',
  '2024-10-17 00:00:00+11', 'https://gronggrongsolarfarm.com.au/grong-grong-solar-farm-commissioning-update/', true);
