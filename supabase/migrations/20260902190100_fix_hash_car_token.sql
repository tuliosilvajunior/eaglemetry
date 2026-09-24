-- Migration: 20260902190100_fix_hash_car_token.sql
--
-- Fix hash_car_token digest lookup (issue #227 verification).
--
-- The helper `public.hash_car_token(text)` was created with
-- `SET search_path = public` and calls `digest(..., 'sha256')`. On this
-- Supabase project `pgcrypto` lives in the `extensions` schema, not `public`,
-- so `digest` resolves only when `extensions` is on the search path. Without
-- it PostgREST inserts via the `anon` device policies fail with
--   function digest(bytea, unknown) does not exist
-- even with a valid x-car-token.
--
-- Also cast the algorithm literal to text so the overload resolves as
-- digest(bytea, text).

create extension if not exists pgcrypto with schema extensions;

create or replace function public.hash_car_token(p_token text)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
begin
  return encode(digest(convert_to(p_token, 'UTF8'), 'sha256'::text), 'hex');
end;
$$;

grant execute on function public.hash_car_token(text) to anon, authenticated, service_role;

-- Recreate dependent helper with same search_path fix (it calls hash_car_token
-- and reads request.headers, no digest itself, but keep paths consistent).
create or replace function public.car_device_identity_from_header()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_token text;
  v_vehicle_id text;
  v_account_id uuid;
begin
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

grant execute on function public.car_device_identity_from_header() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
