-- Migration: 20260901130000_car_device_token_identity.sql
--
-- Phase 3 (Lane C) Step 1a — car device-token identity for RLS.
--
-- Problem: the car has no Supabase Auth session (and must not get one; issue
-- #227 resolved decision (b): a device identity of its own, enforced by
-- Postgres rather than by client good manners). Every RLS policy written so
-- far scopes to `account_id = auth.uid()` — the phone's own Auth session.
-- Postgres therefore cannot tell "the car wrote this" from "the phone wrote
-- this". Lane C's whole guarantee — "car writes `reported`, phone writes
-- `desired`, this must never auto-merge" — depends on Postgres being able to
-- tell the two apart.
--
-- This migration gives the car a Postgres-visible identity. It adds:
--
--   * hash_car_token(text) -> text — SHA-256 hex, matching the device
--     pairing Edge Function's `hashToken()`
--     (`functions/device-pairing/pairing.ts`).
--   * car_device_identity_from_header() -> jsonb — a SECURITY DEFINER helper
--     that reads a raw device token from the `x-car-token` request header,
--     hashes it with `hash_car_token`, looks up the unrevoked
--     `vehicle_devices` row, and returns
--     `{"vehicle_id": ..., "account_id": ...}` or `null` for an
--     absent/invalid/revoked token.
--
-- Both are SECURITY DEFINER so a device request — which runs as the `anon`
-- role with no Auth session — can resolve its own identity without needing
-- SELECT or RLS access to `vehicle_devices` (the SECURITY DEFINER body runs
-- as the function definer, which bypasses RLS).
--
-- Transport contract (the car and the phone must both know this):
--
--   * The car sends its long-lived car_token on EVERY request it makes as an
--     authenticated device, in the request header
--         x-car-token: <raw base64url car_token>
--     (the raw token, never the hash). PostgREST lowercases header names, so
--     the helper reads `x-car-token` via
--     `current_setting('request.headers', true)::jsonb ->> 'x-car-token'`.
--   * As on any Supabase request, `apikey` must also be set (the public anon
--     key). Without a Supabase user JWT the request runs as the `anon` role —
--     the empty/mock role in `auth.uid()` (`null`).
--   * A device (car) request therefore runs as role `anon`. RLS policies that
--     let the car write or read must be `for ... to anon` and scope identity
--     to `car_device_identity_from_header()->>'vehicle_id'`. Policies for the
--     phone stay `for ... to authenticated` on `auth.uid()`. This is the
--     boundary: the phone never runs as `anon`, so it cannot use a device
--     token, and the car never holds a user JWT, so it cannot use `auth.uid()`.
--
-- Step 1b (built next) adds the Lane C tables (`preference_desired`,
-- `preference_reported`) and uses these functions to scope car writes to
-- `vehicle_id = car_device_identity_from_header()->>'vehicle_id'`.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. hash_car_token — SHA-256 hex, matching the pairing Edge Function
-- ---------------------------------------------------------------------------

create or replace function public.hash_car_token(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  -- digest(convert_to(p_token, 'UTF8'), 'sha256') hashes the UTF-8 bytes of
  -- the token; encode(..., 'hex') gives the same lowercase hex string as
  -- `crypto.subtle.digest('SHA-256', new TextEncoder().encode(token))` in
  -- `functions/device-pairing/pairing.ts` (`hashToken`).
  return encode(digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. car_device_identity_from_header — resolve the token in x-car-token
-- ---------------------------------------------------------------------------

create or replace function public.car_device_identity_from_header()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
  v_vehicle_id text;
  v_account_id uuid;
begin
  -- current_setting returns '' after a transaction / when unset; nullif guards
  -- the cast so an absent header resolves to null, not a cast error.
  v_token := nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-car-token';
  if v_token is null or v_token = '' then
    return null;
  end if;

  select vd.vehicle_id, vd.account_id
    into v_vehicle_id, v_account_id
    from public.vehicle_devices vd
   where vd.token_hash = public.hash_car_token(v_token)
     and vd.revoked_at is null
   limit 1;

  if v_vehicle_id is null then
    return null;
  end if;

  return jsonb_build_object('vehicle_id', v_vehicle_id, 'account_id', v_account_id);
end;
$$;

-- Executable by anon (the device), authenticated and service_role. Safe: a
-- caller must present a valid unrevoked token to learn anything, and it only
-- learns the vehicle_id/account_id that token already maps to.
grant execute on function public.hash_car_token(text) to anon, authenticated, service_role;
grant execute on function public.car_device_identity_from_header() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. RLS on vehicle_devices: the car may read its own device row.
--
-- Legitimate car-readable field: when the car boots (or just after a revoke)
-- it can GET /vehicle_devices with its x-car-token header to confirm its link
-- is still unrevoked and which account it belongs to. Scoped by the device
-- token, so `anon` sees only the row whose vehicle_id the presented token
-- resolves to — without a valid token it sees nothing.
-- ---------------------------------------------------------------------------

drop policy if exists vehicle_devices_device_reads on public.vehicle_devices;
create policy vehicle_devices_device_reads on public.vehicle_devices
  for select to anon
  using (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

grant select on public.vehicle_devices to anon;

-- ---------------------------------------------------------------------------
-- 4. Tell PostgREST
-- ---------------------------------------------------------------------------

notify pgrst, 'reload schema';