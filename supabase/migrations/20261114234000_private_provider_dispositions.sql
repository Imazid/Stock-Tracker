-- Read-only reporting of settled sales that happened at an authorised provider.
alter table public.private_provider_approvals add column disposition_activity_enabled boolean not null default false;
alter table public.private_holdings
  add column remaining_units numeric(25,8) check (remaining_units >= 0 and remaining_units <= units),
  add column last_disposition_on date,
  add column disposition_revision_at timestamptz,
  add column exit_source text;

create table public.private_holding_dispositions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  holding_id uuid not null,
  provider_reference text not null check (length(provider_reference) between 1 and 200),
  provider_event_at timestamptz not null,
  sold_units numeric(25,8) not null check (sold_units > 0),
  net_proceeds numeric(20,4) not null check (net_proceeds >= 0),
  disposed_cost numeric(20,4) check (disposed_cost >= 0),
  settled_on date not null,
  source text not null check (length(source) between 1 and 400),
  reversed boolean not null default false,
  unique (holding_id, provider_reference),
  foreign key (holding_id,user_id) references public.private_holdings(id,user_id) on delete cascade
);
create index private_holding_dispositions_sale_order on public.private_holding_dispositions
  (holding_id, settled_on desc, provider_event_at desc, id) where not reversed;
alter table public.private_holding_dispositions enable row level security;
revoke all on public.private_holding_dispositions from public, anon, authenticated, service_role;
grant select on public.private_holding_dispositions to service_role;
grant select on public.private_holding_dispositions to authenticated;
create policy owner_read on public.private_holding_dispositions for select to authenticated
  using ((select auth.uid()) = user_id);

create function public.record_private_holding_disposition(
  p_provider text, p_subject text, p_holding uuid, p_reference text,
  p_event_at timestamptz, p_currency text, p_source text, p_reversed boolean,
  p_settled_on date default null, p_sold_units numeric default null,
  p_net_proceeds numeric default null, p_disposed_cost numeric default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  holding public.private_holdings%rowtype;
  prior public.private_holding_dispositions%rowtype;
  sold numeric;
  latest date;
  latest_source text;
begin
  if nullif(trim(p_reference), '') is null or length(p_reference) > 200 or
     nullif(trim(p_source), '') is null or length(p_source) > 400 or
     p_event_at is null or not isfinite(p_event_at) or p_event_at > now() or p_reversed is null then
    raise exception 'Invalid provider disposition' using errcode = '22023';
  end if;

  -- Serialise revisions across all references for this position.
  select h.* into holding from public.private_holdings h
    join public.investment_commitments c on (c.id,c.user_id) = (h.commitment_id,h.user_id)
    join public.provider_connections pc on pc.id = c.provider_connection_id and pc.user_id = h.user_id
      and pc.provider = c.provider and pc.revoked_at is null
    join public.private_provider_approvals a on a.provider = c.provider and a.jurisdiction = c.jurisdiction
    where h.id = p_holding and h.confirmed_at is not null and h.units is not null and c.status = 'confirmed'
      and c.provider = p_provider and pc.external_subject = p_subject
      and a.holding_activity_enabled and a.disposition_activity_enabled and a.expires_at > now()
    for update of h for share of c, pc, a;
  if not found then
    raise exception 'Disposition unavailable for this provider account' using errcode = '42501';
  end if;
  if p_currency is distinct from holding.currency or p_event_at < holding.confirmed_at then
    raise exception 'Disposition currency or event date does not match the position' using errcode = '22023';
  end if;
  select * into prior from public.private_holding_dispositions
    where holding_id = p_holding and provider_reference = trim(p_reference);
  if found and prior.provider_event_at >= p_event_at then return false; end if;

  if p_reversed then
    if prior.id is null or p_settled_on is not null or p_sold_units is not null or
       p_net_proceeds is not null or p_disposed_cost is not null then
      raise exception 'Reversal must identify a recorded sale without new settlement amounts' using errcode = '22023';
    end if;
    update public.private_holding_dispositions set reversed = true, source = trim(p_source), provider_event_at = p_event_at
      where id = prior.id;
  else
    if p_settled_on is null or not isfinite(p_settled_on) or
       p_settled_on < (holding.confirmed_at at time zone 'UTC')::date - 1 or
       p_settled_on > (p_event_at at time zone 'UTC')::date + 1 or
       p_sold_units is null or p_sold_units::text in ('NaN','Infinity','-Infinity') or
       p_sold_units <= 0 or p_sold_units > holding.units or p_sold_units <> round(p_sold_units, 8) or
       p_net_proceeds is null or p_net_proceeds::text in ('NaN','Infinity','-Infinity') or
       p_net_proceeds < 0 or p_net_proceeds >= 10000000000000000 or p_net_proceeds <> round(p_net_proceeds, 4) or
       (p_disposed_cost is not null and (p_disposed_cost::text in ('NaN','Infinity','-Infinity') or
         p_disposed_cost < 0 or p_disposed_cost >= 10000000000000000 or p_disposed_cost <> round(p_disposed_cost, 4))) then
      raise exception 'Invalid settled sale' using errcode = '22023';
    end if;
    insert into public.private_holding_dispositions
      (holding_id, user_id, provider_reference, provider_event_at, sold_units, net_proceeds, disposed_cost, settled_on, source)
    values (holding.id, holding.user_id, trim(p_reference), p_event_at, p_sold_units, p_net_proceeds, p_disposed_cost,
            p_settled_on, trim(p_source))
    on conflict (holding_id, provider_reference) do update
      set provider_event_at = excluded.provider_event_at, sold_units = excluded.sold_units,
          net_proceeds = excluded.net_proceeds, disposed_cost = excluded.disposed_cost,
          settled_on = excluded.settled_on, source = excluded.source, reversed = false;
  end if;

  select coalesce(sum(sold_units), 0) into sold from public.private_holding_dispositions
    where holding_id = holding.id and not reversed;
  if sold > holding.units then
    raise exception 'Reported sales exceed the original confirmed units' using errcode = '22023';
  end if;
  select settled_on, source into latest, latest_source from public.private_holding_dispositions
    where holding_id = holding.id and not reversed
    order by settled_on desc, provider_event_at desc, id limit 1;
  update public.private_holdings set
    remaining_units = holding.units - sold, last_disposition_on = latest,
    disposition_revision_at = greatest(holding.disposition_revision_at, p_event_at),
    exit_source = case when sold = holding.units then latest_source end
    where id = holding.id;
  insert into public.investment_audit_logs (user_id, action, subject_id)
    values (holding.user_id, case when p_reversed then 'provider_disposition_reversed' else 'provider_disposition' end, holding.id);
  return true;
end $$;

revoke all on function public.record_private_holding_disposition(text,text,uuid,text,timestamptz,text,text,boolean,date,numeric,numeric,numeric)
  from public, anon, authenticated, service_role;
grant execute on function public.record_private_holding_disposition(text,text,uuid,text,timestamptz,text,text,boolean,date,numeric,numeric,numeric)
  to service_role;
