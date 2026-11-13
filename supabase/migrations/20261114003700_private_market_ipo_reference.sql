-- Public issuer and exchange facts. ASX gives an expected closing day, without
-- an application time, so the catalogue leaves the offer status unverified.
insert into public.private_companies
  (id, name, sector, country, location, description, source_url, verified_at, published)
values ('eb84aafc-f0b1-46a4-9f40-cc6d16447701', 'Alvear Tungsten Limited',
  'Mining', 'AU', 'Melbourne, Victoria', 'Mineral exploration and development.',
  'https://alveartungsten.com/', '2026-11-14 00:00:00+11', true);

insert into public.funding_rounds
  (id, company_id, stage, target, currency, source_url, verified_at, published)
values ('eb84aafc-f0b1-46a4-9f40-cc6d16447702', 'eb84aafc-f0b1-46a4-9f40-cc6d16447701',
  'Proposed IPO · ASX: ATW', 7500000, 'AUD', 'https://www.asx.com.au/listings/upcoming-floats-and-listings.',
  '2026-11-14 00:00:00+11', true);

insert into public.investment_opportunities
  (id, round_id, provider, category, status, eligibility, jurisdictions, source_url,
   offer_document_url, verified_at, published)
values ('eb84aafc-f0b1-46a4-9f40-cc6d16447703', 'eb84aafc-f0b1-46a4-9f40-cc6d16447702', 'onmarket', 'Pre-IPO',
  'unverified', 'provider review', array['AU'], 'https://www.onmarket.com.au/offers/alvear-tungsten/',
  'https://alveartungsten.com/', '2026-11-14 00:00:00+11', true);

insert into public.share_classes (round_id, name, rights, source_url, published)
values ('eb84aafc-f0b1-46a4-9f40-cc6d16447702', 'Fully paid ordinary shares',
  'The public offer concerns ordinary shares. The issuer’s prospectus sets out the terms.',
  'https://alveartungsten.com/', true);
