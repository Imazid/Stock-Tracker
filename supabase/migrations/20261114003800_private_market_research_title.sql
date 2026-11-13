-- Some hosted projects applied the initial private-markets schema while report
-- titles were still encrypted only. Store a generic label for those old rows.
alter table public.research_reports add column if not exists title text;
update public.research_reports set title = 'Research report' where title is null;
alter table public.research_reports alter column title set not null;
do $$
begin
  if not exists (
    select 1 from pg_constraint where conrelid = 'public.research_reports'::regclass
      and conname = 'research_reports_title_check'
  ) then
    alter table public.research_reports add constraint research_reports_title_check
      check (length(title) between 1 and 160);
  end if;
end $$;
