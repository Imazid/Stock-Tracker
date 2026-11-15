create table public.private_manual_portfolio_snapshots (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision uuid not null,
  sealed jsonb check (sealed is null or (jsonb_typeof(sealed) = 'object' and octet_length(sealed::text) <= 170000)),
  updated_at timestamptz not null default now()
);

alter table public.private_manual_portfolio_snapshots enable row level security;
revoke all on public.private_manual_portfolio_snapshots from public, anon, authenticated, service_role;
grant select, insert, update on public.private_manual_portfolio_snapshots to service_role;

-- Keep a revision after removal so a delayed save cannot recreate a removed snapshot.
create function public.write_private_manual_portfolio_snapshot(p_user uuid, p_expected uuid, p_revision uuid, p_sealed jsonb)
returns table (revision uuid, updated_at timestamptz)
language sql security invoker set search_path = '' as $$
  with inserted as (
    insert into public.private_manual_portfolio_snapshots as target (user_id, revision, sealed)
    select p_user, p_revision, p_sealed where p_expected is null
    on conflict (user_id) do nothing
    returning target.revision, target.updated_at
  ), updated as (
    update public.private_manual_portfolio_snapshots as target
    set revision = p_revision, sealed = p_sealed, updated_at = now()
    where target.user_id = p_user and target.revision = p_expected
    returning target.revision, target.updated_at
  )
  select * from inserted union all select * from updated;
$$;

revoke all on function public.write_private_manual_portfolio_snapshot(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.write_private_manual_portfolio_snapshot(uuid, uuid, uuid, jsonb) to service_role;
notify pgrst, 'reload schema';
