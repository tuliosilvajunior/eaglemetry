-- Migration: 20260904120000_device_register_rpc.sql
--
-- Issue #236, Phase 2 Step 1 — pre-claim device registration.
--
-- Before any account claims the vehicle, the car must be able to register
-- itself and get a device credential: `register_device_identity` mints an
-- account-less (`account_id = null`) token for a vehicle, revoking any
-- previous unclaimed credential for that vehicle so only one pre-claim
-- token is ever live (second call rotates). The Phase 3 claim later binds
-- the vehicle to an account and replaces this credential.
--
-- The function is `security definer` and executable by `service_role` only
-- (called from the registration Edge Function). The car itself never calls
-- it; the car only presents the minted token in `x-car-token`, resolved by
-- `car_device_identity_from_header()` (20260901130000).
--
-- NOTE on search_path: the brief pins `set search_path = public`, but the
-- body calls `gen_random_bytes`, which lives in the `extensions` schema on
-- this project (see 20260902190100_fix_hash_car_token.sql for the same
-- `digest` failure). `public, extensions, pg_catalog` keeps the fix while
-- staying locked down — no `pg_temp`, no bare `public`-only lookup miss.

create extension if not exists pgcrypto with schema extensions;

create or replace function public.register_device_identity(p_vehicle_id text)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_token text;
begin
  if p_vehicle_id is null or p_vehicle_id = '' then
    raise exception 'vehicle_id must not be empty' using errcode = 'P0001';
  end if;

  -- Rotate: revoke any existing unclaimed active credential for this vehicle.
  update public.vehicle_devices
     set revoked_at = now()
   where vehicle_id = p_vehicle_id
     and account_id is null
     and revoked_at is null;

  -- Register the vehicle itself, account-less until the claim (idempotent).
  insert into public.vehicle (vehicle_id, account_id)
  values (p_vehicle_id, null)
  on conflict (vehicle_id) do nothing;

  -- Mint a 32-byte base64url unpadded token.
  v_token := rtrim(
    replace(replace(encode(gen_random_bytes(32), 'base64'), '+', '-'), '/', '_'),
    '='
  );

  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values (p_vehicle_id, null, public.hash_car_token(v_token));

  return v_token;
end;
$$;

revoke all on function public.register_device_identity(text) from public, anon, authenticated;
grant execute on function public.register_device_identity(text) to service_role;

notify pgrst, 'reload schema';
