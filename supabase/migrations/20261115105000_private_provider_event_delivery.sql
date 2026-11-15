-- Keep replay receipts and the ledger update in the same transaction.
create table provider_operations.private_event_deliveries (
  provider text not null check (provider in ('birchal','onmarket','angellist','syndex')),
  event_id text not null check (event_id ~ '^[a-zA-Z0-9_.:-]{1,160}$'),
  body_sha256 text not null check (body_sha256 ~ '^[a-f0-9]{64}$'),
  user_id uuid not null references auth.users(id) on delete cascade,
  received_at timestamptz not null default now(),
  primary key (provider, event_id)
);
alter table provider_operations.private_event_deliveries enable row level security;
revoke all on provider_operations.private_event_deliveries from public, anon, authenticated, service_role;
grant select, insert on provider_operations.private_event_deliveries to service_role;
create index private_event_deliveries_owner on provider_operations.private_event_deliveries (user_id);

create function public.accept_private_provider_delivery(
  p_provider text, p_event_id text, p_body_sha256 text, p_kind text,
  p_subject text, p_event_at timestamptz, p_details jsonb
) returns text language plpgsql set search_path = '' as $$
declare
  owner_id uuid;
  target_id uuid;
  stored_hash text;
  affected integer;
begin
  if p_kind is null or p_kind not in ('verification','application','holding_activity','holding_disposition')
    or p_event_at is null or not isfinite(p_event_at) or p_event_at > now()
    or nullif(trim(p_subject), '') is null or length(p_subject) > 300
    or p_details is null or jsonb_typeof(p_details) <> 'object' then
    raise exception 'Invalid provider event' using errcode = '22023';
  end if;

  select user_id into owner_id from public.provider_connections
    where provider = p_provider and external_subject = p_subject;
  if not found then
    raise exception 'Provider account is unavailable' using errcode = '42501';
  end if;

  insert into provider_operations.private_event_deliveries (provider,event_id,body_sha256,user_id)
    values (p_provider,p_event_id,p_body_sha256,owner_id)
    on conflict (provider,event_id) do nothing;
  get diagnostics affected = row_count;
  if affected = 0 then
    select body_sha256 into stored_hash from provider_operations.private_event_deliveries
      where provider = p_provider and event_id = p_event_id and user_id = owner_id;
    if stored_hash is distinct from p_body_sha256 then
      raise exception 'Provider delivery ID was already used' using errcode = '23505';
    end if;
    return 'duplicate';
  end if;

  case p_kind
  when 'verification' then
    -- The adapter can update an established binding. A delivery cannot claim a
    -- Stock Tracker user ID or establish a new provider link.
    perform public.record_private_provider_verification(
      owner_id, p_provider, p_subject, p_details->>'jurisdiction', p_details->>'verified_class',
      p_event_at, p_details->>'evidence_reference', (p_details->>'expires_at')::timestamptz,
      (p_details->>'accountant_reviewed_at')::timestamptz);
  when 'application' then
    target_id := (p_details->>'commitment_id')::uuid;
    perform public.record_private_provider_event(
      p_provider, p_subject, target_id, p_details->>'reference', p_details->>'status',
      p_event_at, (p_details->>'cooling_off_ends_at')::timestamptz, (p_details->>'units')::numeric,
      (p_details->>'invested_amount')::numeric, (p_details->>'application_amount')::numeric, p_details->>'application_currency',
      (p_details->>'supplementary_deadline')::timestamptz, p_details->>'supplementary_document_url');
  when 'holding_activity' then
    target_id := (p_details->>'holding_id')::uuid;
    perform public.record_private_holding_activity(
      p_provider, p_subject, target_id, p_details->>'activity', p_details->>'reference', p_event_at,
      (p_details->>'amount')::numeric, p_details->>'currency', (p_details->>'record_date')::date,
      p_details->>'source', p_details->>'method', (p_details->>'settled_on')::date);
  when 'holding_disposition' then
    target_id := (p_details->>'holding_id')::uuid;
    perform public.record_private_holding_disposition(
      p_provider, p_subject, target_id, p_details->>'reference', p_event_at, p_details->>'currency',
      p_details->>'source', (p_details->>'reversed')::boolean, (p_details->>'settled_on')::date,
      (p_details->>'sold_units')::numeric, (p_details->>'net_proceeds')::numeric, (p_details->>'disposed_cost')::numeric);
  end case;
  return 'accepted';
end $$;

revoke all on function public.accept_private_provider_delivery(text,text,text,text,text,timestamptz,jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.accept_private_provider_delivery(text,text,text,text,text,timestamptz,jsonb)
  to service_role;
notify pgrst, 'reload schema';
