begin;

-- Set only for an offer covered by a documented partner receipt interface.
alter table public.investment_opportunities add column provider_offer_reference text
  check (provider_offer_reference = btrim(provider_offer_reference)
    and provider_offer_reference ~ '^[^[:cntrl:]]{1,200}$');
create unique index private_provider_offer_reference
  on public.investment_opportunities (provider, provider_offer_reference)
  where provider_offer_reference is not null;

create function public.accept_private_provider_reference_delivery(
  p_provider text, p_event_id text, p_body_sha256 text, p_kind text, p_subject text,
  p_event_at timestamptz, p_details jsonb
) returns text language plpgsql set search_path = '' as $$
declare
  connection public.provider_connections%rowtype;
  receipt provider_operations.private_event_deliveries%rowtype;
  commitment uuid;
  holding uuid;
  offer_reference text := p_details->>'offer_reference';
  application_reference text := case when p_kind='application' then p_details->>'reference'
    else p_details->>'application_reference' end;
begin
  if p_kind is null or p_kind not in ('application','holding_activity','holding_disposition')
    or p_event_at is null or not isfinite(p_event_at) or p_event_at > now()
    or p_details is null or jsonb_typeof(p_details) <> 'object' or p_details ?| array['commitment_id','holding_id']
    or offer_reference is null or offer_reference <> btrim(offer_reference)
    or offer_reference !~ '^[^[:cntrl:]]{1,200}$'
    or application_reference is null or application_reference <> btrim(application_reference)
    or application_reference !~ '^[^[:cntrl:]]{1,200}$' then
    raise exception 'Invalid provider references' using errcode = '22023';
  end if;

  select * into connection from public.provider_connections
    where provider = p_provider and external_subject = p_subject;
  if not found then raise exception 'Provider account is unavailable' using errcode = '42501'; end if;

  -- An accepted retry remains acknowledgeable after the application is closed.
  select * into receipt from provider_operations.private_event_deliveries
    where provider = p_provider and event_id = p_event_id;
  if found then
    if receipt.user_id is distinct from connection.user_id or receipt.body_sha256 is distinct from p_body_sha256 then
      raise exception 'Provider delivery ID was already used' using errcode = '23505';
    end if;
    return 'duplicate';
  end if;

  -- Resolve the established reference and the first receipt in one snapshot.
  select c.id into commitment from public.investment_commitments c
  join public.investment_opportunities o on (o.id, o.provider) = (c.opportunity_id, c.provider)
  where c.provider = p_provider and c.user_id = connection.user_id and c.provider_connection_id = connection.id
    and o.provider_offer_reference = offer_reference and (
      c.provider_reference = application_reference or (
        p_kind = 'application' and p_details->>'status' = 'application_received'
        and c.status = 'handoff' and c.provider_reference is null and c.acknowledged_at <= p_event_at
        and not exists (select 1 from public.investment_commitments
          where provider = p_provider and provider_reference = application_reference)
      )
    )
  for share of o;
  if commitment is null then
    raise exception 'Provider receipt has no matching application' using errcode = '42501';
  end if;

  -- Resolve the owner’s confirmed position before applying the existing ledger checks.
  if p_kind = 'application' then
    p_details := (p_details - 'offer_reference') || jsonb_build_object('commitment_id',commitment);
  else
    select id into holding from public.private_holdings
      where commitment_id = commitment and user_id = connection.user_id;
    if not found then raise exception 'Provider receipt has no confirmed position' using errcode = '42501'; end if;
    p_details := (p_details - array['offer_reference','application_reference']) || jsonb_build_object('holding_id',holding);
  end if;
  return public.accept_private_provider_delivery(
    p_provider,p_event_id,p_body_sha256,p_kind,p_subject,p_event_at,p_details
  );
end $$;

revoke all on function public.accept_private_provider_reference_delivery(text,text,text,text,text,timestamptz,jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.accept_private_provider_reference_delivery(text,text,text,text,text,timestamptz,jsonb)
  to service_role;
notify pgrst, 'reload schema';
commit;
