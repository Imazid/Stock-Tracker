\pset tuples_only on
\pset format unaligned
begin;

insert into auth.users (id) values ('13dea9fb-37ab-4dbd-ac04-b6228d2a0011'), ('13dea9fb-37ab-4dbd-ac04-b6228d2a0012');
insert into public.secure_credentials (id,user_id,purpose,provider,external_ref,sealed,kek_id) values
('13dea9fb-37ab-4dbd-ac04-b6228d2a0013','13dea9fb-37ab-4dbd-ac04-b6228d2a0011','snaptrade_user','snaptrade','activity-fixture',
 '{"v":1,"alg":"A256GCM","kid":"test","wrappedDek":"fixture","dekIv":"fixture","iv":"fixture","ciphertext":"fixture"}','test');

set local role service_role;
do $$
declare
  j record;
  account uuid := '13dea9fb-37ab-4dbd-ac04-b6228d2a0014';
  credential uuid := '13dea9fb-37ab-4dbd-ac04-b6228d2a0013';
  owner_id uuid := '13dea9fb-37ab-4dbd-ac04-b6228d2a0011';
  other_id uuid := '13dea9fb-37ab-4dbd-ac04-b6228d2a0012';
  day date := (now() at time zone 'UTC')::date;
  payload jsonb;
  initial_snapshot uuid;
  old_lease uuid;
begin
  select * into strict j from public.claim_snaptrade_activity_jobs() where credential_id = credential;
  old_lease := j.lease_id;
  if exists (select 1 from public.claim_snaptrade_activity_jobs() where credential_id = credential) then
    raise exception 'Active lease was reclaimed';
  end if;
  if not public.advance_snaptrade_activity_job(credential,j.lease_id,array[account]) then raise exception 'Could not start snapshot'; end if;
  select * into strict j from public.claim_snaptrade_activity_jobs() where credential_id = credential;
  if j.account_id <> account or j.page_offset <> 0 or j.end_date <> day then raise exception 'Invalid staged account'; end if;
  if public.advance_snaptrade_activity_job(credential,old_lease,p_rows := '[]') then raise exception 'Expired lease wrote data'; end if;

  if not public.advance_snaptrade_activity_job(credential,j.lease_id,
    p_rows := (select jsonb_agg(jsonb_build_object('id',lpad(n::text,64,'0'),'date',day,'label','Dividend')) from generate_series(1,50) n),
    p_omitted := 1, p_next_offset := 50) then raise exception 'First page was lost'; end if;
  if public.read_snaptrade_activity_cache(owner_id,account,day - 1,day,0) is not null then
    raise exception 'Partial activity was visible';
  end if;
  select * into strict j from public.claim_snaptrade_activity_jobs() where credential_id = credential;
  if j.page_offset <> 50 then raise exception 'Second page lost its cursor'; end if;
  if not public.advance_snaptrade_activity_job(credential,j.lease_id,
    p_rows := jsonb_build_array(jsonb_build_object('id',lpad('51',64,'0'),'date',day,'label','Stock split'))) then
    raise exception 'Second page was lost';
  end if;
  payload := public.read_snaptrade_activity_cache(owner_id,account,day - 1,day,0);
  initial_snapshot := (payload->>'snapshot')::uuid;
  if initial_snapshot is null or (payload->>'nextOffset')::int <> 50 or (payload->>'omitted')::int <> 1
    or jsonb_array_length(payload->'activities') <> 50 then raise exception 'First cache page mismatch'; end if;
  payload := public.read_snaptrade_activity_cache(owner_id,account,day - 1,day,50,initial_snapshot);
  if jsonb_array_length(payload->'activities') <> 1 or payload->>'nextOffset' is not null or (payload->>'omitted')::int <> 0 then
    raise exception 'Second cache page mismatch';
  end if;
  if public.read_snaptrade_activity_cache(other_id,account,day - 1,day,0) is not null
    or public.read_snaptrade_activity_cache(owner_id,account,day - 100,day,0) is not null
    or public.read_snaptrade_activity_cache(owner_id,account,day - 1,day,0,gen_random_uuid()) is not null then
    raise exception 'Cache returned records for the wrong owner, range or snapshot';
  end if;

  update portfolio_metrics.snaptrade_activity_jobs set due_at = now() where credential_id = credential;
  select * into strict j from public.claim_snaptrade_activity_jobs() where credential_id = credential;
  if not public.advance_snaptrade_activity_job(credential,j.lease_id,array[account]) then raise exception 'Refresh did not start'; end if;
  select * into strict j from public.claim_snaptrade_activity_jobs() where credential_id = credential;
  perform public.defer_snaptrade_activity_job(credential,j.lease_id,true);
  if (public.read_snaptrade_activity_cache(owner_id,account,day - 1,day,0)->>'snapshot')::uuid is distinct from initial_snapshot then
    raise exception 'Failed refresh removed the completed snapshot';
  end if;
  update portfolio_metrics.snaptrade_activity_jobs set due_at = now() where credential_id = credential;
  select * into strict j from public.claim_snaptrade_activity_jobs() where credential_id = credential;
  if not public.advance_snaptrade_activity_job(credential,j.lease_id,array[account]) then raise exception 'Retry did not start'; end if;
  select * into strict j from public.claim_snaptrade_activity_jobs() where credential_id = credential;
  if not public.advance_snaptrade_activity_job(credential,j.lease_id,p_rows := '[]') then raise exception 'Retry did not publish'; end if;
  if public.read_snaptrade_activity_cache(owner_id,account,day - 1,day,50,initial_snapshot) is not null then
    raise exception 'Obsolete snapshot page returned';
  end if;

  update public.secure_credentials set revoked_at = now() where id = credential;
  if public.read_snaptrade_activity_cache(owner_id,account,day - 1,day,0) is not null
    or exists (select 1 from portfolio_metrics.snaptrade_activity_jobs where credential_id = credential) then
    raise exception 'Revoked identity retained activity';
  end if;
end $$;
reset role;
select case when not has_function_privilege('authenticated','public.read_snaptrade_activity_cache(uuid,uuid,date,date,integer,uuid)','execute')
  and not has_table_privilege('authenticated','portfolio_metrics.snaptrade_activities','select')
  then 'ok activity leases, atomic paging, ownership, retries, snapshot replacement and revocation'
  else 'FAIL activity cache exposed' end;
rollback;
