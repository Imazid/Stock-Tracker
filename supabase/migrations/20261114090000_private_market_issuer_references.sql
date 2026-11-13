-- Issuer announcements are public research sources without a provider account or offer route.
alter table public.investment_opportunities
  drop constraint investment_opportunities_provider_check,
  add constraint investment_opportunities_provider_check check (
    provider in ('birchal', 'onmarket', 'angellist', 'syndex') or
    (provider = 'issuer' and status in ('closed', 'unverified') and handoff_url is null)
  );

insert into public.private_companies
  (id, name, sector, country, location, description, founders, investors, source_url, verified_at, published)
values
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01', 'Heidi', 'Healthcare technology', 'AU', 'Founded in Melbourne',
   'Builds clinical workflow software, including tools for clinical documentation.', array['Thomas Kelly'],
   array['Blackbird', 'Phoenix Court', 'Point72 Private Investments', 'Headline'],
   'https://www.heidihealth.com/en-gb/blog/heidi-secures-us340m-to-scale-agents-across-health-systems-globally',
   '2026-11-14 07:00:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e02', 'AdvanCell', 'Biotechnology', 'AU', 'Brisbane and Boston',
   'Develops investigational targeted radiopharmaceutical therapies for cancer.', null,
   array['Ally Bridge Group', 'Alpha Wave', 'Fidelity Management & Research Company'],
   'https://www.advancell.com.au/news/advancell-closes-us-315-million-oversubscribed-series-d-financing-to-advance-targeted-alpha-therapies-and-expand-clinical-and-commercial-manufacturing-infrastructure/',
   '2026-11-14 07:00:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e03', 'MoPA: Museum of Play and Art', 'Education and entertainment', 'AU', 'Australia',
   'Art Play Productions operates interactive children’s museums.', null, null,
   'https://www.museumofplayandart.com.au/', '2026-11-14 07:00:00+11', true);

insert into public.funding_rounds
  (id, company_id, stage, raised, target, valuation, valuation_method, currency, source_url, verified_at, published)
values
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e11', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e01', 'Series C',
   100000000, null, 900000000, 'Issuer-reported round valuation. Methodology undisclosed.', 'USD',
   'https://www.heidihealth.com/en-gb/blog/heidi-secures-us340m-to-scale-agents-across-health-systems-globally',
   '2026-11-14 07:00:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e12', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e02', 'Series D',
   315000000, null, null, null, 'USD',
   'https://www.advancell.com.au/news/advancell-closes-us-315-million-oversubscribed-series-d-financing-to-advance-targeted-alpha-therapies-and-expand-clinical-and-commercial-manufacturing-infrastructure/',
   '2026-11-14 07:00:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e13', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e03', '2026 crowd-sourced funding',
   null, 5000000, null, null, 'AUD',
   'https://storage.googleapis.com/birchal-uploads/209b02ce-0064-41f7-9434-3cc5cb24c84c/209b02ce-0064-41f7-9434-3cc5cb24c84c.pdf',
   '2026-11-14 07:00:00+11', true);

insert into public.investment_opportunities
  (id, round_id, provider, category, status, eligibility, jurisdictions, source_url, offer_document_url, verified_at, published)
values
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e21', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e11', 'issuer', 'Series B or later',
   'closed', 'provider review', '{}',
   'https://www.heidihealth.com/en-gb/blog/heidi-secures-us340m-to-scale-agents-across-health-systems-globally',
   null, '2026-11-14 07:00:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e22', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e12', 'issuer', 'Series B or later',
   'closed', 'provider review', '{}',
   'https://www.advancell.com.au/news/advancell-closes-us-315-million-oversubscribed-series-d-financing-to-advance-targeted-alpha-therapies-and-expand-clinical-and-commercial-manufacturing-infrastructure/',
   null, '2026-11-14 07:00:00+11', true),
  ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e23', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e13', 'birchal', 'Crowdfunding',
   'unverified', 'provider review', array['AU'], 'https://www.museumofplayandart.com.au/',
   'https://storage.googleapis.com/birchal-uploads/209b02ce-0064-41f7-9434-3cc5cb24c84c/209b02ce-0064-41f7-9434-3cc5cb24c84c.pdf',
   '2026-11-14 07:00:00+11', true);

insert into public.corporate_actions (company_id, title, significance, published_at, source_url, published)
values ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01', 'Company restructuring',
  'The CEO reported an approximately 18% global headcount reduction and a reorganization of product and research teams.',
  '2026-11-04 00:00:00+11', 'https://www.heidihealth.com/en-us/blog/changes-to-our-team-at-heidi', true);
