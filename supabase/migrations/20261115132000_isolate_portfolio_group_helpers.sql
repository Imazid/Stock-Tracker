-- Keep privileged implementations outside the schemas exposed by PostgREST.
create schema portfolio_sync;
revoke all on schema portfolio_sync from public, anon, authenticated;
grant usage on schema portfolio_sync to authenticated;

alter function public.apply_portfolio_group_change(uuid,uuid,uuid,text,text,text,uuid[])
  set schema portfolio_sync;
alter function public.save_portfolio_group_value(uuid,uuid,date,double precision,timestamptz)
  set schema portfolio_sync;

create function public.apply_portfolio_group_change(p_user_id uuid, p_id uuid, p_group_id uuid,
  p_action text, p_name text default null, p_emoji text default null, p_holdings uuid[] default '{}')
returns void language sql security invoker set search_path = '' as $$
  select portfolio_sync.apply_portfolio_group_change(p_user_id, p_id, p_group_id, p_action, p_name, p_emoji, p_holdings);
$$;

create function public.save_portfolio_group_value(p_user_id uuid, p_group_id uuid, p_snapshot_date date,
  p_total_value double precision, p_observed_at timestamptz)
returns void language sql security invoker set search_path = '' as $$
  select portfolio_sync.save_portfolio_group_value(p_user_id, p_group_id, p_snapshot_date, p_total_value, p_observed_at);
$$;

revoke all on function public.apply_portfolio_group_change(uuid,uuid,uuid,text,text,text,uuid[]) from public, anon;
revoke all on function public.save_portfolio_group_value(uuid,uuid,date,double precision,timestamptz) from public, anon;
grant execute on function public.apply_portfolio_group_change(uuid,uuid,uuid,text,text,text,uuid[]) to authenticated;
grant execute on function public.save_portfolio_group_value(uuid,uuid,date,double precision,timestamptz) to authenticated;

alter policy "owners can read portfolios" on public.portfolio_groups using (user_id = (select auth.uid()));
alter policy "owners can read portfolio group values" on public.portfolio_group_snapshots using (user_id = (select auth.uid()));
