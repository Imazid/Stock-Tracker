do $$
begin
  if to_regclass('cron.job') is not null then
    if exists (select from cron.job where jobname = 'company-alerts') then
      perform cron.unschedule('company-alerts');
    end if;
  end if;
end;
$$;

drop function company_alert_operations.invoke_due();
drop schema company_alert_operations;
