alter table public.agent_analysis_runs add column if not exists failure_code text;
alter table public.agent_analysis_runs add column if not exists failure_message text;
