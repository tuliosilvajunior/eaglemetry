-- Migration: 20260911120000_claim_history_backfill.sql
--
-- Issue #236, Phase 3 Wave 1 — claim backfill + transfer semantics.
--
-- Extends `public.claim_pairing_session` (created in
-- 20260901120000_device_pairing_and_vehicle_ownership.sql) with the history
-- backfill, inside its existing transaction: after the ownership row and the
-- new device credential exist, every row still holding `account_id IS NULL`
-- for that vehicle moves to the claimant, on all nine tables.
--
-- Decision D1 (transfer semantics): history stays with whichever account it
-- was already stamped to. The backfill only ever touches still-NULL rows —
-- never migrates rows already claimed by a previous owner. Consequences:
--   * first claim: every NULL row moves to the claimant, zero NULLs left;
--   * transfer (old owner revoked, new owner claims): only the still-NULL
--     rows move; the old owner's rows keep the old id forever (including
--     the `vehicle` singleton row, which is already claimed and stays so);
--   * re-claim by the same account: the `IS NULL` predicate finds nothing,
--     so the backfill is a natural no-op.
--
-- The single-owner check and its revoked-owner handling are untouched: they
-- already let a re-claim past a revoked prior owner, which is the transfer
-- path. The stamp trigger (`stamp_measurement_account_id`) leaves
-- privileged writers alone, so the backfill's writes survive; the function
-- is SECURITY DEFINER, so RLS is bypassed as before.

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
  update public.vehicle set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public.vehicle_devices set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public.session set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public."interval" set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public.track set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public.telemetry_events set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public.trip_segments set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public.battery_cycles set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  update public.battery_cycle_sessions set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;

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

  return jsonb_build_object('ok', true);
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
