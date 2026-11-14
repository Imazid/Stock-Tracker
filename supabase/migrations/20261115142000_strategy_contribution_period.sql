alter table public.trading_agents add column last_monthly_investment_period text
  check (last_monthly_investment_period is null or last_monthly_investment_period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$');
