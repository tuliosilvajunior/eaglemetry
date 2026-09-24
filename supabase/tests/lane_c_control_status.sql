-- supabase/tests/lane_c_control_status.sql
--
-- Phase 3 (Lane C — control) Step 1b — SQL tests for the control-plane
-- tables and the join view. Runs via psql against a real Postgres.
--
-- Run:  psql -h 127.0.0.1 -U <user> -d <scratch_db> -f supabase/tests/lane_c_control_status.sql
--
-- This is the SQL counterpart to
-- `supabase/migrations/20260902150000_preference_control_lane_c.sql`. It
-- exercises RLS itself (the events run under `anon` / `authenticated`, with
-- a simulated `request.headers` / `request.jwt.claims` GUC), so the negative
-- cases are proven rejected by Postgres RLS, not by application logic. The
-- view's per-role scoping is tested through the view itself, proving the
-- `security_invoker` choice leaks nothing across vehicles or accounts.

\set ON_ERROR_STOP on

\echo '=== Lane C control: setting up auth mock and minimal schema ==='
DROP TABLE IF EXISTS public.preference_desired CASCADE;
DROP TABLE IF EXISTS public.preference_reported CASCADE;

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

\echo '=== Applying pairing + device-token-identity + lane-c migrations ==='
\i supabase/migrations/20260901120000_device_pairing_and_vehicle_ownership.sql
\i supabase/migrations/20260901130000_car_device_token_identity.sql
\i supabase/migrations/20260902150000_preference_control_lane_c.sql
\i supabase/migrations/20260902160000_lane_c_tiebreak_fix.sql

-- Helper to assert equality
CREATE OR REPLACE FUNCTION assert_eq(label text, expected text, actual text) RETURNS void AS $$
BEGIN
  IF expected IS DISTINCT FROM actual THEN
    RAISE EXCEPTION 'ASSERT FAIL %: expected % got %', label, expected, actual;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Helper: run a statement and demand that PostgreSQL refuse it via RLS. The
-- statement runs under the current role, so `SET ROLE anon` / `SET ROLE
-- authenticated` before calling it determines which road the write takes.
CREATE OR REPLACE FUNCTION expect_rls_rejected(label text, p_sql text) RETURNS void AS $$
DECLARE
  v_error boolean := false;
  v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN others THEN
    v_error := true;
    GET STACKED DIAGNOSTICS v_msg = message_text;
  END;
  IF NOT v_error THEN
    RAISE EXCEPTION 'ASSERT FAIL %: expected RLS rejection, statement succeeded', label;
  END IF;
  IF v_msg !~* 'row-level security policy' THEN
    RAISE EXCEPTION 'ASSERT FAIL %: rejected, but not by RLS (got: %)', label, v_msg;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Helper: assert a derived status in the join view, read as the current role.
CREATE OR REPLACE FUNCTION assert_view_status(label text, p_vehicle text, p_key text, p_expected text) RETURNS void AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status
    FROM public.preference_control_status
   WHERE vehicle_id = p_vehicle AND key = p_key;
  IF v_status IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'ASSERT FAIL %: expected %, got %', label, p_expected, v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Clean any prior run and reseed: two phone accounts, three vehicles.
--   * account a1 owns veh-A (tokens tok-A and tok-A-revoked) and veh-B (tok-B)
--   * account a2 owns veh-C (tok-C)
DELETE FROM public.preference_desired;
DELETE FROM public.preference_reported;
DELETE FROM public.vehicle_devices;
DELETE FROM public.vehicle_ownership;
DELETE FROM public.device_pairing_sessions;
DELETE FROM auth.users;
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002');
INSERT INTO public.vehicle_ownership (vehicle_id, account_id) VALUES
  ('veh-A', '00000000-0000-0000-0000-000000000001'),
  ('veh-B', '00000000-0000-0000-0000-000000000001'),
  ('veh-C', '00000000-0000-0000-0000-000000000002');
INSERT INTO public.vehicle_devices (vehicle_id, account_id, token_hash) VALUES
  ('veh-A', '00000000-0000-0000-0000-000000000001', public.hash_car_token('tok-A')),
  ('veh-A', '00000000-0000-0000-0000-000000000001', public.hash_car_token('tok-A-revoked')),
  ('veh-B', '00000000-0000-0000-0000-000000000001', public.hash_car_token('tok-B')),
  ('veh-C', '00000000-0000-0000-0000-000000000002', public.hash_car_token('tok-C'));
UPDATE public.vehicle_devices SET revoked_at = now()
 WHERE token_hash = public.hash_car_token('tok-A-revoked');

-- ===================================================================
-- 1. The phone writes desired for its own account, upsert-by-key
-- ===================================================================
\echo '=== Test 1: phone writes + upserts desired (Lane C writer boundary) ==='
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-000000000001"}', false);
  INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
  VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'pack_capacity_wh', '100000', 111000, 'phone');
  -- Upsert-by-key: the phone re-proposes the same (account, vehicle, key),
  -- and the row is updated in place, never duplicated.
  INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
  VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'pack_capacity_wh', '120000', 222000, 'phone')
  ON CONFLICT (account_id, vehicle_id, key) DO UPDATE
    SET value = EXCLUDED.value,
        proposed_at_utc_millis = EXCLUDED.proposed_at_utc_millis,
        origin = EXCLUDED.origin;
  RAISE NOTICE 'Test 1 PASS (phone write + upsert accepted)';
END;
$$;
SET ROLE postgres;
DO $$
DECLARE v_n int; v_val text; v_prop bigint; v_origin text;
BEGIN
  SELECT count(*), max(value), max(proposed_at_utc_millis), max(origin) INTO v_n, v_val, v_prop, v_origin
    FROM public.preference_desired
   WHERE account_id='00000000-0000-0000-0000-000000000001' AND vehicle_id='veh-A' AND key='pack_capacity_wh';
  PERFORM assert_eq('upsert keeps one row', '1', v_n::text);
  PERFORM assert_eq('upsert updated value', '120000', v_val);
  PERFORM assert_eq('upsert updated proposed_at', '222000', v_prop::text);
  PERFORM assert_eq('upsert keeps origin', 'phone', v_origin);
  RAISE NOTICE 'Test 1 verified persisted';
END;
$$;

-- ===================================================================
-- 2. The phone may not reach into a vehicle it does not own, and may
--    not forge another account's row
-- ===================================================================
\echo '=== Test 2: phone write-scoping on desired ==='
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-000000000001"}', false);
  -- veh-C is owned by account a2, not by a1.
  PERFORM expect_rls_rejected(
    'a1 cannot desire a vehicle it does not own (veh-C)',
    $stmt$INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
           VALUES ('00000000-0000-0000-0000-000000000001', 'veh-C', 'pack_capacity_wh', '99999', 111000, 'phone')$stmt$);
  -- The phone's own row must carry its own account id.
  PERFORM expect_rls_rejected(
    'a1 cannot write a desired row under a2 account id',
    $stmt$INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
           VALUES ('00000000-0000-0000-0000-000000000002', 'veh-A', 'pack_capacity_wh', '1', 111000, 'phone')$stmt$);
  RAISE NOTICE 'Test 2 PASS (desired write-scoping)';
END;
$$;
SET ROLE postgres;

-- ===================================================================
-- 3. The car writes reported, scoped to the vehicle its token resolves
--    to, write-once-per-decision, idempotent re-send
-- ===================================================================
\echo '=== Test 3: car writes reported (Lane C writer boundary) ==='
SET ROLE anon;
DO $$
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
  VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'pack_capacity_wh', '120000', 'accepted', 333000, 333000);
  -- Idempotent re-send of the same decision: same (vehicle, key, decided_at)
  -- is sent with Prefer: resolution=ignore-duplicates (DO NOTHING), so the
  -- stored row and its reported_at are left untouched — never a second row.
  INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
  VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'pack_capacity_wh', '120000', 'accepted', 333000, 333001)
  ON CONFLICT (vehicle_id, key, decided_at_utc_millis) DO NOTHING;
  RAISE NOTICE 'Test 3a PASS (car write + idempotent resend accepted)';
END;
$$;
SET ROLE postgres;
DO $$
DECLARE v_n int; v_reported bigint;
BEGIN
  SELECT count(*) INTO v_n FROM public.preference_reported
   WHERE vehicle_id='veh-A' AND key='pack_capacity_wh' AND decided_at_utc_millis=333000;
  SELECT max(reported_at_utc_millis) INTO v_reported FROM public.preference_reported
   WHERE vehicle_id='veh-A' AND key='pack_capacity_wh' AND decided_at_utc_millis=333000;
  PERFORM assert_eq('resend keeps one row per decision', '1', v_n::text);
  PERFORM assert_eq('resend leaves reported_at unchanged (ignore-duplicates)', '333000', v_reported::text);
  RAISE NOTICE 'Test 3a verified persisted';
END;
$$;

-- 3b. A vehicle token may only relate to its own vehicle and its own account.
SET ROLE anon;
DO $$
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  PERFORM expect_rls_rejected(
    'tok-A cannot report for veh-B',
    $stmt$INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
           VALUES ('veh-B', '00000000-0000-0000-0000-000000000001', 'pack_capacity_wh', '1', 'accepted', 1, 1)$stmt$);
  PERFORM expect_rls_rejected(
    'tok-A cannot report under another account id',
    $stmt$INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
           VALUES ('veh-A', '00000000-0000-0000-0000-000000000002', 'pack_capacity_wh', '1', 'accepted', 1, 1)$stmt$);
  RAISE NOTICE 'Test 3b PASS (reported vehicle/account scoping)';
END;
$$;
SET ROLE postgres;

-- 3c. No token, a revoked token and an unknown token all fail to write.
SET ROLE anon;
DO $$
BEGIN
  PERFORM set_config('request.headers', '{}', false);
  PERFORM expect_rls_rejected(
    'no token cannot report',
    $stmt$INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
           VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'pack_capacity_wh', '1', 'accepted', 1, 1)$stmt$);
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A-revoked"}', false);
  PERFORM expect_rls_rejected(
    'revoked token cannot report',
    $stmt$INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
           VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'pack_capacity_wh', '1', 'accepted', 1, 1)$stmt$);
  PERFORM set_config('request.headers', '{"x-car-token": "tok-unknown"}', false);
  PERFORM expect_rls_rejected(
    'unknown token cannot report',
    $stmt$INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
           VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'pack_capacity_wh', '1', 'accepted', 1, 1)$stmt$);
  RAISE NOTICE 'Test 3c PASS (absent/revoked/unknown token cannot report)';
END;
$$;
SET ROLE postgres;

-- ===================================================================
-- 4. The car cannot write desired
-- ===================================================================
\echo '=== Test 4: car cannot write desired ==='
SET ROLE anon;
DO $$
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  PERFORM expect_rls_rejected(
    'car cannot write desired',
    $stmt$INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
           VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'pack_capacity_wh', '1', 111000, 'car')$stmt$);
  RAISE NOTICE 'Test 4 PASS (car cannot write desired)';
END;
$$;
SET ROLE postgres;

-- ===================================================================
-- 5. The phone cannot write reported
-- ===================================================================
\echo '=== Test 5: phone cannot write reported ==='
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-000000000001"}', false);
  -- Even a valid car token in the headers does not help: an authenticated
  -- session runs the phone lane, and reported has no authenticated INSERT policy.
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  PERFORM expect_rls_rejected(
    'phone cannot write reported',
    $stmt$INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
           VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'pack_capacity_wh', '1', 'accepted', 1, 1)$stmt$);
  RAISE NOTICE 'Test 5 PASS (phone cannot write reported)';
END;
$$;
SET ROLE postgres;

-- ===================================================================
-- 6. Read scoping — through the tables AND through the join view
-- ===================================================================
\echo '=== Test 6: read scoping on tables and view ==='
-- Seed a pair of rows for veh-B (a1) and veh-C (a2) so cross-vehicle reads
-- have something to leak across.
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-B', 'scen_vehB', 'B1', 1000, 'phone');
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-B', '00000000-0000-0000-0000-000000000001', 'scen_vehB', 'B1', 'accepted', 2000, 2000);
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000002', 'veh-C', 'scen_vehC', 'C1', 1000, 'phone');
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-C', '00000000-0000-0000-0000-000000000002', 'scen_vehC', 'C1', 'accepted', 2000, 2000);

-- 6a. The car reads only its own vehicle's rows, on the base tables.
SET ROLE anon;
DO $$
DECLARE v_n int;
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  SELECT count(*) INTO v_n FROM public.preference_desired;
  PERFORM assert_eq('car reads only its own desired rows', '1', v_n::text);
  SELECT count(*) INTO v_n FROM public.preference_reported;
  PERFORM assert_eq('car reads only its own reported rows', '1', v_n::text);
  SELECT count(*) INTO v_n FROM public.preference_reported WHERE vehicle_id='veh-B';
  PERFORM assert_eq('car never sees veh-B reported', '0', v_n::text);
  RAISE NOTICE 'Test 6a PASS (table read scoping for the car)';
END;
$$;
SET ROLE postgres;

-- 6b. The phone reads only its own account's rows (not account a2's veh-C).
SET ROLE authenticated;
DO $$
DECLARE v_n_own int; v_n_foreign int;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-000000000001"}', false);
  SELECT count(*) INTO v_n_own FROM public.preference_reported;
  SELECT count(*) INTO v_n_foreign FROM public.preference_reported WHERE account_id='00000000-0000-0000-0000-000000000002';
  PERFORM assert_eq('phone reads its own account reports', '2', v_n_own::text);
  PERFORM assert_eq('phone never reads a2 reports', '0', v_n_foreign::text);
  RAISE NOTICE 'Test 6b PASS (table read scoping for the phone)';
END;
$$;
SET ROLE postgres;

-- 6c. The view itself is scoped: tok-A sees only veh-A through it. This is
--     the proof the `security_invoker` choice holds — a plain (definer) view
--     would leak every vehicle's rows to any token.
SET ROLE anon;
DO $$
DECLARE v_vehicles text;
BEGIN
  PERFORM set_config('request.headers', '{"x-car-token": "tok-A"}', false);
  SELECT string_agg(distinct vehicle_id, ',' order by vehicle_id) INTO v_vehicles
    FROM public.preference_control_status;
  PERFORM assert_eq('tok-A view sees only veh-A', 'veh-A', v_vehicles);
  RAISE NOTICE 'Test 6c PASS (view scoping for the car)';
END;
$$;
SET ROLE postgres;

SET ROLE authenticated;
DO $$
DECLARE v_vehicles text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-000000000001"}', false);
  SELECT string_agg(distinct vehicle_id, ',' order by vehicle_id) INTO v_vehicles
    FROM public.preference_control_status;
  PERFORM assert_eq('a1 view sees veh-A and veh-B, never veh-C', 'veh-A,veh-B', v_vehicles);
  RAISE NOTICE 'Test 6c PASS (view scoping for the phone)';
END;
$$;
SET ROLE postgres;

SET ROLE anon;
DO $$
DECLARE v_n int; v_vehicles text;
BEGIN
  -- No token: nothing resolves, and the view returns nothing at all.
  PERFORM set_config('request.headers', '{}', false);
  SELECT count(*) INTO v_n FROM public.preference_control_status;
  PERFORM assert_eq('no-token view sees nothing', '0', v_n::text);
  PERFORM set_config('request.headers', '{"x-car-token": "tok-C"}', false);
  SELECT count(*), string_agg(distinct vehicle_id, '') INTO v_n, v_vehicles
    FROM public.preference_control_status;
  PERFORM assert_eq('tok-C view sees one vehicle', '1', v_n::text);
  PERFORM assert_eq('tok-C view sees only veh-C', 'veh-C', v_vehicles);
  RAISE NOTICE 'Test 6c PASS (view scoping negative cases)';
END;
$$;
SET ROLE postgres;

-- ===================================================================
-- 7. Derived status semantics on the join view
-- ===================================================================
\echo '=== Test 7: join view derives pending/confirmed/stale/refused ==='
TRUNCATE public.preference_desired;
TRUNCATE public.preference_reported;

-- Scenario rows, all for veh-A / account a1. The phone proposes and the car
-- decides; report timestamps are the car's decision time.
-- desired proposed 1000, value A; car accepts A at 2000  -> confirmed
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'scen_confirmed', 'A', 1000, 'phone');
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_confirmed', 'A', 'accepted', 2000, 2000);

-- desired only, no report  -> pending (never applied)
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'scen_pending', 'P', 1500, 'phone');

-- desired changed to B at 3000 AFTER the car accepted A at 2000 -> stale
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_stale', 'A', 'accepted', 2000, 2000);
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'scen_stale', 'B', 3000, 'phone');

-- the car refused -> refused
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_refused', 'D', 'refused', 2500, 2500);
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'scen_refused', 'C', 1000, 'phone');

-- the car accepted a different value than desired -> not confirmed -> refused
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_accepted_other', 'F', 'accepted', 2000, 2000);
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'scen_accepted_other', 'E', 1000, 'phone');

-- reported only, no desire -> reported_only
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_reported_only', 'G', 'accepted', 2000, 2000);

-- two decisions for the same key: the LATEST report governs the view
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'scen_latest_wins', 'H', 1000, 'phone');
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_latest_wins', 'H', 'accepted', 2000, 2000);
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_latest_wins', 'H', 'accepted', 3000, 3000);

-- a later refusal must override an earlier acceptance: never auto-merge
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'scen_refuse_overrides', 'I', 1000, 'phone');
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_refuse_overrides', 'I', 'accepted', 2000, 2000);
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'scen_refuse_overrides', 'I', 'refused', 3000, 3000);

DO $$
DECLARE
  v_status text;
  v_desired text;
  v_reported text;
  v_reported_status text;
BEGIN
  PERFORM assert_view_status('confirmed', 'veh-A', 'scen_confirmed', 'confirmed');
  PERFORM assert_view_status('pending', 'veh-A', 'scen_pending', 'pending');
  PERFORM assert_view_status('stale', 'veh-A', 'scen_stale', 'stale');
  PERFORM assert_view_status('refused', 'veh-A', 'scen_refused', 'refused');
  PERFORM assert_view_status('accepted-other is refused', 'veh-A', 'scen_accepted_other', 'refused');
  PERFORM assert_view_status('reported-only', 'veh-A', 'scen_reported_only', 'reported_only');
  PERFORM assert_view_status('latest report wins', 'veh-A', 'scen_latest_wins', 'confirmed');
  PERFORM assert_view_status('later refusal overrides', 'veh-A', 'scen_refuse_overrides', 'refused');

  -- "A desired value with no matching reported row shows as pending, never
  -- as applied" (issue #227 testing decision, Lane C).
  SELECT status INTO v_status
    FROM public.preference_control_status
   WHERE vehicle_id='veh-A' AND key='scen_pending';
  IF v_status IN ('confirmed', 'stale', 'refused') THEN
    RAISE EXCEPTION 'ASSERT FAIL: pending desire shown as applied (%)', v_status;
  END IF;

  -- Spot-check the raw columns the read path relies on: the view exposes the
  -- phone's proposal AND the car's decision side by side.
  SELECT desired_value, reported_value, reported_status
    INTO v_desired, v_reported, v_reported_status
    FROM public.preference_control_status
   WHERE vehicle_id='veh-A' AND key='scen_refuse_overrides';
  PERFORM assert_eq('decided row desired side', 'I', v_desired);
  PERFORM assert_eq('decided row reported value', 'I', v_reported);
  PERFORM assert_eq('decided row raw status', 'refused', v_reported_status);

  SELECT desired_value, reported_value INTO v_desired, v_reported
    FROM public.preference_control_status
   WHERE vehicle_id='veh-A' AND key='scen_confirmed';
  PERFORM assert_eq('confirmed desired value', 'A', v_desired);
  PERFORM assert_eq('confirmed reported value', 'A', v_reported);

  RAISE NOTICE 'Test 7 PASS (derived status semantics)';
END;
$$;

-- -------------------------------------------------------------------
-- 7c. M-1 regression: same reported_at tie is broken on decided_at
-- -------------------------------------------------------------------
\echo '=== Test 7c: same reported_at tiebreak on decided_at (M-1 regression) ==='
-- Two decisions for the same key uploaded in one batch share reported_at
-- (the car stamps one now() per sync pass — PreferenceControlSync.kt:103).
-- The view must govern by the newer decided_at, not an arbitrary row.
INSERT INTO public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
VALUES ('00000000-0000-0000-0000-000000000001', 'veh-A', 'p2_batch', 'Z', 1000, 'phone');
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'p2_batch', 'Y', 'accepted', 2000, 9999);
INSERT INTO public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
VALUES ('veh-A', '00000000-0000-0000-0000-000000000001', 'p2_batch', 'Z', 'refused', 8000, 9999);
DO $$
DECLARE v_status text; v_reported text; v_decided bigint;
BEGIN
  SELECT status, reported_value, decided_at_utc_millis
    INTO v_status, v_reported, v_decided
    FROM public.preference_control_status
   WHERE vehicle_id='veh-A' AND key='p2_batch';
  -- The newer decided_at (8000) must govern, not the older (2000).
  PERFORM assert_eq('tiebreak picks newer decided_at', '8000', v_decided::text);
  PERFORM assert_eq('tiebreak reported_value is from newer decision', 'Z', v_reported);
  -- Desired Z with reported Z refused => refused (not confirmed). Verifies
  -- the view did not pick the older Y row (which would also be refused but
  -- with a different value/decided_at).
  PERFORM assert_eq('tiebreak status from newer decision', 'refused', v_status);
  RAISE NOTICE 'Test 7c PASS (same reported_at tiebreak on decided_at)';
END;
$$;

-- The view is read-only everywhere: there is no path that merges desired and
-- reported back into a write. Attempting one is refused by the view itself.
DO $$
DECLARE v_err boolean := false; v_msg text;
BEGIN
  BEGIN
    INSERT INTO public.preference_control_status (vehicle_id, key, status) VALUES ('veh-A', 'x', 'pending');
  EXCEPTION WHEN others THEN
    v_err := true;
    GET STACKED DIAGNOSTICS v_msg = message_text;
  END;
  IF NOT v_err THEN
    RAISE EXCEPTION 'ASSERT FAIL: view accepts an insert';
  END IF;
  IF v_msg !~* 'cannot insert into view' THEN
    RAISE EXCEPTION 'ASSERT FAIL: view refused a write for the wrong reason (got: %)', v_msg;
  END IF;
  RAISE NOTICE 'Test 7b PASS (view is read-only; no auto-merge write path)';
END;
$$;

\echo '=== All Lane C control-status tests PASSED ==='