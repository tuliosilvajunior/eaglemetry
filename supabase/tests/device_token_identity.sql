-- supabase/tests/device_token_identity.sql
--
-- Phase 3 (Lane C) Step 1a — car device-token identity for RLS. Tests run
-- via psql against a real Postgres.
--
-- Run:  psql -h 127.0.0.1 -U <user> -d test_device_token_identity -f supabase/tests/device_token_identity.sql
--
-- This is the SQL counterpart to the mechanism in
-- `supabase/migrations/20260901130000_car_device_token_identity.sql`. It
-- exercises RLS itself (the events run under `anon`/`authenticated`, with a
-- simulated `request.headers` / `request.jwt.claims` GUC), so the negative
-- cases are proven rejected by Postgres RLS, not by application logic.

\set ON_ERROR_STOP on

\echo '=== Device-token identity: setting up auth mock and minimal schema ==='
DROP TABLE IF EXISTS public.__device_auth_proof CASCADE;

-- auth schema mock mirroring Supabase's real `auth.uid()` semantics: read the
-- `sub` claim from the `request.jwt.claims` GUC (set by PostgREST per request).
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id uuid primary key);
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  RETURN nullif(current_setting('request.jwt.claims', true), '')::jsonb;
END; $$;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  RETURN nullif(auth.jwt() ->> 'sub', '')::uuid;
END; $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

\echo '=== Applying pairing + device-token-identity migrations ==='
\i supabase/migrations/20260901120000_device_pairing_and_vehicle_ownership.sql
\i supabase/migrations/20260901130000_car_device_token_identity.sql

-- Helper to assert equality
CREATE OR REPLACE FUNCTION assert_eq(label text, expected text, actual text) RETURNS void AS $$
BEGIN
  IF expected IS DISTINCT FROM actual THEN
    RAISE EXCEPTION 'ASSERT FAIL %: expected % got %', label, expected, actual;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Clean any prior run's seed, then reseed: one phone account, three devices
-- (two for vehicle A, one for B; one of vehicle A's is revoked).
DELETE FROM public.vehicle_devices;
DELETE FROM public.vehicle_ownership;
DELETE FROM public.device_pairing_sessions;
DELETE FROM auth.users;
INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-000000000001');
INSERT INTO public.vehicle_ownership (vehicle_id, account_id)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001');
INSERT INTO public.vehicle_devices (vehicle_id, account_id, token_hash)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', public.hash_car_token('tok-A'));
INSERT INTO public.vehicle_devices (vehicle_id, account_id, token_hash, revoked_at)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', public.hash_car_token('tok-A-revoked'), now());
INSERT INTO public.vehicle_devices (vehicle_id, account_id, token_hash)
VALUES ('veh-B', '00000000-0000-0000-0000-000000000001', public.hash_car_token('tok-B'));

-- ===================================================================
-- 1. hash_car_token matches the pairing Edge Function's SHA-256 hex
-- ===================================================================
\echo '=== Test 1: hash_car_token ==='
DO $$
DECLARE v_hash text;
BEGIN
  SELECT public.hash_car_token('tok-A') INTO v_hash;
  PERFORM assert_eq('hash_car_token matches digest', encode(digest(convert_to('tok-A','UTF8'),'sha256'),'hex'), v_hash);
  PERFORM assert_eq('hash_car_token is 64 lowercase hex chars', '64', length(v_hash)::text);
  PERFORM assert_eq('hash_car_token lowercase', 'true', (v_hash = lower(v_hash))::text);
  RAISE NOTICE 'Test 1 PASS';
END;
$$;

-- ===================================================================
-- 2. car_device_identity_from_header resolves valid / rejects invalid
-- ===================================================================
\echo '=== Test 2: car_device_identity_from_header ==='
DO $$
DECLARE v_ident jsonb;
BEGIN
  -- No header => null
  PERFORM set_config('request.headers', '{}', false);
  SELECT public.car_device_identity_from_header() INTO v_ident;
  IF v_ident IS NOT NULL THEN RAISE EXCEPTION 'no-header should resolve to null, got %', v_ident; END IF;

  -- Valid unrevoked token => vehicle_id + account_id
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  SELECT public.car_device_identity_from_header() INTO v_ident;
  PERFORM assert_eq('valid token vehicle_id', 'veh-A', v_ident->>'vehicle_id');
  PERFORM assert_eq('valid token account_id', '00000000-0000-0000-0000-000000000001', v_ident->>'account_id');

  -- Revoked token => null
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A-revoked"}', false);
  SELECT public.car_device_identity_from_header() INTO v_ident;
  IF v_ident IS NOT NULL THEN RAISE EXCEPTION 'revoked token should resolve to null, got %', v_ident; END IF;

  -- Unknown token => null
  PERFORM set_config('request.headers', '{"x-car-token": "tok-unknown"}', false);
  SELECT public.car_device_identity_from_header() INTO v_ident;
  IF v_ident IS NOT NULL THEN RAISE EXCEPTION 'unknown token should resolve to null, got %', v_ident; END IF;

  RAISE NOTICE 'Test 2 PASS';
END;
$$;

-- ===================================================================
-- 3. RLS write-scoping proof on a throwaway table (the pattern Lane C
--    Step 1b will use): car writes scoped to its own vehicle_id
-- ===================================================================
\echo '=== Test 3: RLS write-scoping (throwaway table) ==='
-- Throwaway example table; the same `for insert to anon` + identity check is
-- the template for the real Lane C `preference_reported`-type tables in Step 1b.
CREATE TABLE public.__device_auth_proof (
  vehicle_id text not null,
  account_id uuid not null,
  note text
);
ALTER TABLE public.__device_auth_proof ENABLE ROW LEVEL SECURITY;
CREATE POLICY device_auth_proof_car_insert ON public.__device_auth_proof
  FOR INSERT TO anon
  WITH CHECK (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);
GRANT ALL ON public.__device_auth_proof TO anon, authenticated;

-- Helper: simulate a device request (set the header GUC) and expect RLS to
-- reject the insert.
CREATE OR REPLACE FUNCTION expect_rls_rejected(label text, p_header text, p_vehicle_id text) RETURNS void AS $$
DECLARE
  v_insert_error boolean := false;
  v_msg text;
BEGIN
  PERFORM set_config('request.headers', p_header, false);
  BEGIN
    INSERT INTO public.__device_auth_proof (vehicle_id, account_id, note)
    VALUES (p_vehicle_id, '00000000-0000-0000-0000-000000000001', 'should-reject');
  EXCEPTION WHEN others THEN
    v_insert_error := true;
    GET STACKED DIAGNOSTICS v_msg = message_text;
  END;
  IF NOT v_insert_error THEN
    RAISE EXCEPTION 'ASSERT FAIL %: expected RLS rejection, insert succeeded', label;
  END IF;
  IF v_msg !~* 'row-level security policy' THEN
    RAISE EXCEPTION 'ASSERT FAIL %: rejected, but not by RLS (got: %)', label, v_msg;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 3a. Valid unrevoked token may insert a row for its own vehicle.
SET ROLE anon;
DO $$
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  INSERT INTO public.__device_auth_proof (vehicle_id, account_id, note)
  VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'ok');
  RAISE NOTICE 'Test 3a PASS (valid token insert accepted)';
END;
$$;
SET ROLE postgres;
-- Verify persisted (as superuser; anon has no select policy on this table).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.__device_auth_proof WHERE vehicle_id='veh-A' AND note='ok') THEN
    RAISE EXCEPTION 'ASSERT FAIL: valid token insert not persisted';
  END IF;
  RAISE NOTICE 'Test 3a verified persisted';
END;
$$;

-- 3b. A token for vehicle A cannot write a row scoped to vehicle B.
SET ROLE anon;
DO $$
BEGIN
  PERFORM expect_rls_rejected('token-A cannot write veh-B', '{"x-car-token": "tok-A"}', 'veh-B');
  RAISE NOTICE 'Test 3b PASS (different vehicle rejected)';
END;
$$;
SET ROLE postgres;

-- 3c. No token header => rejected.
SET ROLE anon;
DO $$
BEGIN
  PERFORM expect_rls_rejected('no token rejected', '{}', 'veh-A');
  RAISE NOTICE 'Test 3c PASS (no token rejected)';
END;
$$;
SET ROLE postgres;

-- 3d. Revoked token => rejected.
SET ROLE anon;
DO $$
BEGIN
  PERFORM expect_rls_rejected('revoked token rejected', '{"x-car-token": "tok-A-revoked"}', 'veh-A');
  RAISE NOTICE 'Test 3d PASS (revoked token rejected)';
END;
$$;
SET ROLE postgres;

-- 3e. Unknown token => rejected.
SET ROLE anon;
DO $$
BEGIN
  PERFORM expect_rls_rejected('unknown token rejected', '{"x-car-token": "tok-unknown"}', 'veh-A');
  RAISE NOTICE 'Test 3e PASS (unknown token rejected)';
END;
$$;
SET ROLE postgres;

-- 3f. The phone (authenticated) cannot use a device token to write the
--     car-scoped table: it runs as `authenticated`, and the policy is `to anon`.
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-000000000001"}', false);
  PERFORM expect_rls_rejected('phone cannot write car-scoped table', '{"x-car-token": "tok-A"}', 'veh-A');
  RAISE NOTICE 'Test 3f PASS (phone authenticated cannot write car-scoped table)';
END;
$$;
SET ROLE postgres;

\echo '=== Test 4: vehicle_devices device-select policy (car self-check) ==='
-- 4a. Valid token-A sees only vehicle A's own device rows (not vehicle B's).
SET ROLE anon;
DO $$
DECLARE v_n_a integer; v_n_b integer; v_n_total integer;
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  SELECT count(*) INTO v_n_a FROM public.vehicle_devices WHERE vehicle_id='veh-A';
  SELECT count(*) INTO v_n_b FROM public.vehicle_devices WHERE vehicle_id='veh-B';
  SELECT count(*) INTO v_n_total FROM public.vehicle_devices;
  PERFORM assert_eq('device-reads sees own vehicle rows', '2', v_n_a::text);
  PERFORM assert_eq('device-reads never sees other vehicle rows', '0', v_n_b::text);
  ASSERT v_n_total = v_n_a;
  RAISE NOTICE 'Test 4a PASS (device reads only its own vehicle)';
END;
$$;
SET ROLE postgres;

-- 4b. Revoked / unknown / absent token sees no device rows.
SET ROLE anon;
DO $$
DECLARE v_n integer;
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A-revoked"}', false);
  SELECT count(*) INTO v_n FROM public.vehicle_devices;
  PERFORM assert_eq('revoked device-reads sees nothing', '0', v_n::text);
  PERFORM set_config('request.headers', '{}', false);
  SELECT count(*) INTO v_n FROM public.vehicle_devices;
  PERFORM assert_eq('no-token device-reads sees nothing', '0', v_n::text);
  RAISE NOTICE 'Test 4b PASS (revoked/absent token sees no rows)';
END;
$$;
SET ROLE postgres;

\echo '=== All device-token-identity tests PASSED ==='