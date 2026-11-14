create table public.private_account_holdings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision uuid not null,
  sealed jsonb check (sealed is null or (jsonb_typeof(sealed) = 'object' and octet_length(sealed::text) <= 170000)),
  updated_at timestamptz not null default now()
);

alter table public.private_account_holdings enable row level security;
revoke all on public.private_account_holdings from public, anon, authenticated, service_role;
grant select, insert, update on public.private_account_holdings to service_role;

-- Compare the account revision on each edit so concurrent browser sessions cannot lose an entry.
create function public.write_private_account_holdings(p_user uuid, p_expected uuid, p_revision uuid, p_sealed jsonb)
returns table (revision uuid, updated_at timestamptz)
language sql security invoker set search_path = '' as $$
  with inserted as (
    insert into public.private_account_holdings as target (user_id, revision, sealed)
    select p_user, p_revision, p_sealed where p_expected is null
    on conflict (user_id) do nothing
    returning target.revision, target.updated_at
  ), updated as (
    update public.private_account_holdings as target
    set revision = p_revision, sealed = p_sealed, updated_at = now()
    where target.user_id = p_user and target.revision = p_expected
    returning target.revision, target.updated_at
  )
  select * from inserted union all select * from updated;
$$;

revoke all on function public.write_private_account_holdings(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.write_private_account_holdings(uuid, uuid, uuid, jsonb) to service_role;
notify pgrst, 'reload schema';
