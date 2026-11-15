-- Dated company-level figures from issuer disclosures. Funding amounts and valuations remain on rounds.
create table public.private_company_financials (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.private_companies(id) on delete cascade,
  period_end_on date not null,
  period_kind text not null check (period_kind in ('financial_year', 'month_snapshot')),
  assurance text not null check (assurance in ('audited', 'issuer_reported')),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  revenue numeric(18,4) check (revenue >= 0),
  annual_recurring_revenue numeric(18,4) check (annual_recurring_revenue >= 0),
  net_profit_loss numeric(18,4),
  operating_cash_flow numeric(18,4),
  cash_and_equivalents numeric(18,4) check (cash_and_equivalents >= 0),
  published_on date not null check (published_on >= period_end_on),
  source_url text not null check (source_url like 'https://%'),
  verified_at timestamptz not null,
  published boolean not null default false,
  unique (company_id, period_kind, period_end_on),
  check (num_nonnulls(revenue, annual_recurring_revenue, net_profit_loss, operating_cash_flow, cash_and_equivalents) > 0),
  -- A month-only observation uses the first day as a storage key and is displayed without a day.
  check (period_kind <> 'month_snapshot' or extract(day from period_end_on) = 1),
  check (published_on <= (verified_at at time zone 'Australia/Sydney')::date)
);

alter table public.private_company_financials enable row level security;
revoke all on public.private_company_financials from public, anon, authenticated;
grant select on public.private_company_financials to anon, authenticated;
grant select, insert, update, delete on public.private_company_financials to service_role;
create policy published_private_company_financials on public.private_company_financials
  for select to anon, authenticated using (
    published and verified_at <= now()
    and exists (select 1 from public.private_companies where id = company_id and published)
  );

insert into public.private_company_financials
  (id, company_id, period_end_on, period_kind, assurance, currency, revenue, annual_recurring_revenue,
   net_profit_loss, operating_cash_flow, cash_and_equivalents, published_on, source_url, verified_at, published)
values
  ('a21a931d-2af3-42e8-89ca-812684ba4301', 'd72c4060-1ae7-4a2f-8f2e-9f4bf1577e01', '2026-04-01',
   'month_snapshot', 'issuer_reported', 'USD', null, 50000000, null, null, null, '2026-09-22',
   'https://www.heidihealth.com/en-gb/blog/heidi-secures-us340m-to-scale-agents-across-health-systems-globally',
   '2026-11-14 13:30:00+11', true),
  ('a21a931d-2af3-42e8-89ca-812684ba4302', 'a581f4af-a8d0-41fd-a9be-0e4e1607f102', '2026-06-30',
   'financial_year', 'audited', 'AUD', 1057652, null, -3171479, -2086708, 1046924, '2026-11-10',
   'https://cdn-api.markitdigital.com/apiman-gateway/ASX/asx-research/1.0/file/2924-03160163-6A1354399',
   '2026-11-14 13:30:00+11', true),
  ('a21a931d-2af3-42e8-89ca-812684ba4303', 'a581f4af-a8d0-41fd-a9be-0e4e1607f102', '2025-06-30',
   'financial_year', 'audited', 'AUD', 1705901, null, -274547, null, null, '2026-11-10',
   'https://cdn-api.markitdigital.com/apiman-gateway/ASX/asx-research/1.0/file/2924-03160163-6A1354399',
   '2026-11-14 13:30:00+11', true);
