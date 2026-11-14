-- Compare each source with the latest completed digest that used it. The
-- source fingerprints remain in the internal jobs table and share its retention.
alter table public.private_market_digest_jobs add column source_revisions jsonb;

create or replace function public.private_market_digest_sources(p_user uuid, p_day date)
returns jsonb language sql stable set search_path = '' as $$
  with followed as materialized (
    select distinct unnest(d.company_ids) as company_id
    from public.private_monitor_devices d
    where d.user_id = p_user and d.digest_enabled and d.refreshed_at >= now() - interval '90 days'
  ), recent as (
    select a.id, a.company_name, a.title, a.significance, a.source_url, a.published_at,
           alert.revised_at,
           encode(sha256(convert_to(jsonb_build_array(a.company_name, a.title, a.significance,
             a.source_url, extract(epoch from a.published_at))::text, 'UTF8')), 'hex') as revision
    from followed f
    join public.published_private_company_updates a on a.company_id = f.company_id
    left join public.private_market_alerts alert
      on (alert.user_id, alert.kind, alert.subject_id) = (p_user, 'announcement', a.id)
    where a.published_at >= now() - interval '7 days' or alert.revised_at >= now() - interval '7 days'
  ), eligible as (
    select a.*, previous.finished_at is not null as is_revision
    from recent a
    left join lateral (
      select j.finished_at, j.source_revisions ->> a.id::text as revision
      from public.private_market_digest_jobs j
      where j.user_id = p_user and j.digest_day between p_day - 7 and p_day
        and j.finished_at is not null and a.id = any(j.source_ids)
      order by j.digest_day desc limit 1
    ) previous on true
    where previous.finished_at is null or case when previous.revision is null
      then coalesce(a.revised_at > previous.finished_at, false)
      else a.revision <> previous.revision end
    order by greatest(a.revised_at, a.published_at) desc, a.id
    limit 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'company', s.company_name, 'title', s.title, 'summary', s.significance,
    'url', s.source_url, 'published_at', s.published_at, 'is_revision', s.is_revision, 'revision', s.revision
  ) order by greatest(s.revised_at, s.published_at) desc, s.id), '[]'::jsonb)
  from eligible s;
$$;

create or replace function public.finish_private_market_digest(p_job uuid, p_lease uuid, p_sources jsonb, p_sealed jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  job public.private_market_digest_jobs;
begin
  select * into job from public.private_market_digest_jobs
    where id = p_job and lease_token = p_lease and finished_at is null and next_attempt_at > now()
    for update;
  if not found then return false; end if;

  perform pg_catalog.pg_advisory_xact_lock_shared(412345, 41);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(job.user_id::text, 41));
  if p_sources is null or p_sealed is null or jsonb_array_length(p_sources) = 0
    or job.source_ids <> array(select (s->>'id')::uuid from jsonb_array_elements(p_sources) s)
    or p_sources <> public.private_market_digest_sources(job.user_id, job.digest_day) then
    return false;
  end if;

  insert into public.research_reports (id, user_id, kind, title, sealed)
    values (job.id, job.user_id, 'monitor_digest', case when p_sources @> '[{"is_revision":true}]'::jsonb
      then 'Private Markets disclosure updates' else 'Private Markets monitoring summary' end, p_sealed);
  update public.private_market_digest_jobs
    set finished_at = now(), source_revisions = (
      select jsonb_object_agg(s->>'id', s->>'revision') from jsonb_array_elements(p_sources) s
    ) where id = job.id;
  insert into public.investment_audit_logs (user_id, action, subject_id)
    values (job.user_id, 'scheduled_research_complete', job.id);
  return true;
end $$;
