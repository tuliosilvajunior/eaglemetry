-- Migration: 20260912223000_session_costs_claim_backfill.sql
--
-- Issue #236: session_costs claim backfill and pre-claim upload support.
--
-- Nine tables received account_id backfill during claim_pairing_session,
-- but session_costs was omitted because earlier migrations assumed it was
-- an authenticated-only annotation. In reality, the car records charge
-- sessions before pairing and computes cost annotations locally
-- (SessionCostEntity).
--
-- This migration:
--   1. Makes public.session_costs.account_id nullable so unclaimed charges
--      can exist before pairing.
--   2. Attaches the server-side measurement_account_stamp trigger to
--      session_costs so car token / auth.uid() stamps the account_id.
--   3. Updates anon RLS policies on session_costs to use
--      `account_id is not distinct from ...` matching the other measurement
--      and telemetry tables.
--   4. Replaces public.claim_pairing_session to adopt unowned session_costs
--      rows on claim, adding adopted rows to the backfilled count.

-- 1. Make account_id nullable on session_costs
alter table public.session_costs
  alter column account_id drop not null;

-- 2. Server-side account stamping trigger
drop trigger if exists measurement_account_stamp on public.session_costs;
create trigger measurement_account_stamp
  before insert or update on public.session_costs
  for each row execute function public.stamp_measurement_account_id();

-- 3. Anonymous device RLS policies
drop policy if exists session_costs_device_reads on public.session_costs;
create policy session_costs_device_reads on public.session_costs
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists session_costs_device_writes on public.session_costs;
create policy session_costs_device_writes on public.session_costs
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists session_costs_device_updates on public.session_costs;
create policy session_costs_device_updates on public.session_costs
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists session_costs_device_deletes on public.session_costs;
create policy session_costs_device_deletes on public.session_costs
  for delete to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

-- 4. Extended claim_pairing_session RPC with session_costs backfill
create or replace function public.claim_pairing_session(
  p_device_code uuid,
  p_vehicle_id text,
  p_account_id uuid,
  p_token_hash text,
  p_car_token text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_existing_owner uuid;
  v_backfilled integer := 0;
  v_rows integer;
begin
  -- Serialize concurrent claims on the same vehicle.
  perform 1 from public.vehicle_ownership
   where vehicle_id = p_vehicle_id and revoked_at is null
   for update;

  select account_id into v_existing_owner
    from public.vehicle_ownership
   where vehicle_id = p_vehicle_id and revoked_at is null
   limit 1;

  if v_existing_owner is not null and v_existing_owner <> p_account_id then
    return jsonb_build_object('error', 'vehicle_already_claimed');
  end if;

  -- Ensure ownership row exists for claimant (idempotent)
  insert into public.vehicle_ownership (vehicle_id, account_id)
  values (p_vehicle_id, p_account_id)
  on conflict (vehicle_id, account_id) do nothing;

  -- Create device credential
  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values (p_vehicle_id, p_account_id, p_token_hash);

  -- Backfill history: only still-unclaimed rows move to the claimant.
  -- ROW_COUNT after each UPDATE is exactly the rows this claim adopted.
  update public.vehicle set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_backfilled = row_count;
  update public.vehicle_devices set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public.session set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public."interval" set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public.track set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public.telemetry_events set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public.trip_segments set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public.battery_cycles set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public.battery_cycle_sessions set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;
  update public.session_costs set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_rows = row_count;
  v_backfilled := v_backfilled + v_rows;

  -- Approve session only if still pending and not expired
  update public.device_pairing_sessions
     set status = 'approved',
         approved_by = p_account_id,
         car_token = p_car_token
   where device_code = p_device_code
     and status = 'pending'
     and expires_at > now();

  if not found then
    select status into v_status from public.device_pairing_sessions where device_code = p_device_code;
    if v_status is null then
      raise exception 'invalid_device_code' using errcode = 'P0001';
    elsif v_status <> 'pending' then
      raise exception 'already_claimed' using errcode = 'P0002';
    else
      raise exception 'expired' using errcode = 'P0003';
    end if;
  end if;

  return jsonb_build_object('ok', true, 'backfilled', v_backfilled);
exception
  when unique_violation then
    -- Catches partial unique index violation when race slipped past SELECT FOR UPDATE
    select account_id into v_existing_owner
      from public.vehicle_ownership
     where vehicle_id = p_vehicle_id and revoked_at is null and account_id <> p_account_id
     limit 1;
    if v_existing_owner is not null then
      return jsonb_build_object('error', 'vehicle_already_claimed');
    end if;
    return jsonb_build_object('error', 'conflict');
end;
$$;

revoke all on function public.claim_pairing_session(uuid, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_pairing_session(uuid, text, uuid, text, text) to service_role;

notify pgrst, 'reload schema';
