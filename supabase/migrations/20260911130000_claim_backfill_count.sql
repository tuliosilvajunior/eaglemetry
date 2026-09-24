-- Migration: 20260911130000_claim_backfill_count.sql
--
-- Issue #236, Phase 3 Wave 2 — report the adopted-row count.
--
-- Claim backfill (Phase 3 Wave 1, `20260911120000_claim_history_backfill.sql`)
-- moves every still-NULL row for the vehicle to the claimant, but the RPC's
-- success object only said `{ok: true}`. The `/claim` edge route already
-- passes a `backfilled` field through; without a count inside the RPC result
-- the client could never show "N earlier trips picked up". This migration
-- makes the RPC itself report the real number.
--
-- The count is captured from the backfill UPDATEs themselves via
-- `GET DIAGNOSTICS v_backfilled = ROW_COUNT` after each statement, summed
-- across all nine tables. It is not recomputed from a separate SELECT: the
-- ROW_COUNT is exactly what was written in this transaction, so it can never
-- disagree with the rows the updates actually moved. The `vehicle`
-- singleton row (claimed by the ownership upsert before the backfill) is not
-- counted — the nine tables are the history labels.
--
-- The single number means "rows adopted by this claim, summed over the nine
-- history tables". A transfer keeps the old owner's rows, so the count for a
-- transfer is only the still-NULL rows moved. A re-claim by the same account
-- reports 0.

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