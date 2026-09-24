-- Migration: 20260912231000_vehicle_singleton_transfer_fix.sql
--
-- Issue #236: Vehicle singleton row transfer fix.
--
-- When a vehicle transfers ownership (old owner revoked, new owner claims),
-- the singleton row in public.vehicle was left with the old owner because
-- the update had an `and account_id is null` predicate designed for history
-- tables under Decision D1.
--
-- Consequently, the new owner could not read or rename the vehicle row,
-- the car could not read its own vehicle row via anon device reads, and
-- account deletion of the old owner would cascade and destroy the vehicle
-- and all its telemetry.
--
-- Fix:
-- 1. Ensure the vehicle singleton exists before inserting device credentials.
-- 2. Backfill only still-unclaimed (NULL) vehicle rows into `v_backfilled`.
-- 3. Always update the vehicle singleton's account_id to the new owner.

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

  -- Ensure vehicle singleton exists
  insert into public.vehicle (vehicle_id, account_id)
  values (p_vehicle_id, p_account_id)
  on conflict (vehicle_id) do nothing;

  -- Create device credential
  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values (p_vehicle_id, p_account_id, p_token_hash);

  -- Backfill history: only still-unclaimed rows move to the claimant.
  -- ROW_COUNT after each UPDATE is exactly the rows this claim adopted.
  update public.vehicle set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_backfilled = row_count;

  -- On transfer, the vehicle singleton row moves to the active claimant.
  -- This does not increment v_backfilled because it was not an unclaimed row.
  update public.vehicle set account_id = p_account_id
   where vehicle_id = p_vehicle_id;

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
