-- supabase/tests/annotation_convergence.sql
--
-- Phase 2 Lane B Step 3 — convergence property tests run via psql.
--
-- Run:  psql -h 127.0.0.1 -U postgres -d test_convergence -f supabase/tests/annotation_convergence.sql
-- Or with supabase local:  psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/annotation_convergence.sql
--
-- This file is the SQL counterpart to the Kotlin property test
-- `android/app/src/test/kotlin/.../AnnotationConvergencePropertyTest.kt`.
-- Both execute the real trigger; the Kotlin suite is the CI-integrated runner
-- (via JDBC + Assume). This file is for manual `psql -f` verification and
-- documents the four required tests in pure SQL.

\set ON_ERROR_STOP on

\echo '=== Annotation convergence: setting up minimal schema ==='
DROP TABLE IF EXISTS public.insight_places CASCADE;
DROP TABLE IF EXISTS public.journeys CASCADE;
DROP TABLE IF EXISTS public.preferences CASCADE;
DROP TABLE IF EXISTS public.session_costs CASCADE;

CREATE TABLE public.insight_places (
  id text not null,
  account_id uuid not null,
  name text not null,
  latitude double precision not null,
  longitude double precision not null,
  radius_m double precision not null,
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  origin text not null,
  deleted_at_utc_millis bigint,
  auto_name text default null,
  auto_name_updated_at_utc_millis bigint default null,
  auto_name_source text default null,
  name_hlc_millis bigint not null default 0,
  name_hlc_counter integer not null default 0,
  name_hlc_device_id text not null default '',
  geofence_hlc_millis bigint not null default 0,
  geofence_hlc_counter integer not null default 0,
  geofence_hlc_device_id text not null default '',
  auto_name_hlc_millis bigint not null default 0,
  auto_name_hlc_counter integer not null default 0,
  auto_name_hlc_device_id text not null default '',
  primary key (account_id, id)
);
CREATE TABLE public.journeys (
  id text not null,
  account_id uuid not null,
  name text not null,
  started_at_utc_millis bigint not null,
  ended_at_utc_millis bigint not null,
  note text,
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  origin text not null,
  deleted_at_utc_millis bigint,
  name_hlc_millis bigint not null default 0,
  name_hlc_counter integer not null default 0,
  name_hlc_device_id text not null default '',
  note_hlc_millis bigint not null default 0,
  note_hlc_counter integer not null default 0,
  note_hlc_device_id text not null default '',
  time_range_hlc_millis bigint not null default 0,
  time_range_hlc_counter integer not null default 0,
  time_range_hlc_device_id text not null default '',
  primary key (account_id, id)
);
CREATE TABLE public.preferences (
  account_id uuid not null,
  scope text not null,
  key text not null,
  value text,
  updated_at_utc_millis bigint not null,
  origin text not null,
  deleted_at_utc_millis bigint,
  hlc_millis bigint not null default 0,
  hlc_counter integer not null default 0,
  hlc_device_id text not null default '',
  primary key (account_id, scope, key)
);
CREATE TABLE public.session_costs (
  vehicle_id text not null,
  session_id text not null,
  account_id uuid not null,
  cost_per_kwh double precision,
  paid_amount double precision,
  cost_currency text,
  updated_at_utc_millis bigint not null,
  origin text not null,
  cost_hlc_millis bigint not null default 0,
  cost_hlc_counter integer not null default 0,
  cost_hlc_device_id text not null default '',
  primary key (vehicle_id, session_id)
);

\echo '=== Applying merge trigger migration ==='
\i supabase/migrations/20260902130000_annotation_merge_trigger.sql
\i supabase/migrations/20260902140000_annotation_tiebreak_and_autoname_fix.sql

-- Helper to assert equality
CREATE OR REPLACE FUNCTION assert_eq(label text, expected text, actual text) RETURNS void AS $$
BEGIN
  IF expected IS DISTINCT FROM actual THEN
    RAISE EXCEPTION 'ASSERT FAIL %: expected % got %', label, expected, actual;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Helper to reset place/journey
CREATE OR REPLACE FUNCTION reset_place() RETURNS void AS $$
BEGIN
  DELETE FROM public.insight_places WHERE account_id = '00000000-0000-0000-0000-000000000001' AND id = 'convergence-place-1';
  INSERT INTO public.insight_places
  (id, account_id, name, latitude, longitude, radius_m, created_at_utc_millis, updated_at_utc_millis, origin, deleted_at_utc_millis,
   auto_name, auto_name_updated_at_utc_millis, auto_name_source,
   name_hlc_millis, name_hlc_counter, name_hlc_device_id, geofence_hlc_millis, geofence_hlc_counter, geofence_hlc_device_id, auto_name_hlc_millis, auto_name_hlc_counter, auto_name_hlc_device_id)
  VALUES ('convergence-place-1', '00000000-0000-0000-0000-000000000001', 'Init', 0, 0, 10, 1000, 1000, 'car', null, null, null, null, 1000, 0, 'car-1', 1000, 0, 'car-1', 1000, 0, 'car-1');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION reset_journey() RETURNS void AS $$
BEGIN
  DELETE FROM public.journeys WHERE account_id = '00000000-0000-0000-0000-000000000001' AND id = 'convergence-journey-1';
  INSERT INTO public.journeys
  (id, account_id, name, started_at_utc_millis, ended_at_utc_millis, note, created_at_utc_millis, updated_at_utc_millis, origin, deleted_at_utc_millis,
   name_hlc_millis, name_hlc_counter, name_hlc_device_id, note_hlc_millis, note_hlc_counter, note_hlc_device_id, time_range_hlc_millis, time_range_hlc_counter, time_range_hlc_device_id)
  VALUES ('convergence-journey-1', '00000000-0000-0000-0000-000000000001', 'JourneyInit', 1000, 2000, 'Initial note', 1000, 1000, 'car', null, 1000, 0, 'car-1', 1000, 0, 'car-1', 1000, 0, 'car-1');
END;
$$ LANGUAGE plpgsql;

-- ===================================================================
-- 1. Permutation property: 6 writes in different orders converge
-- ===================================================================
\echo '=== Test 1: permutation property (6 writes, multiple orders) ==='
DO $$
DECLARE
  v_name text;
  v_lat double precision;
  v_jname text;
  v_jnote text;
  v_jstart bigint;
BEGIN
  -- Order A
  PERFORM reset_place(); PERFORM reset_journey();
  UPDATE public.insight_places SET name='Alpha', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET latitude=10, longitude=10, radius_m=100, geofence_hlc_millis=1000, geofence_hlc_counter=1, geofence_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.journeys SET name='Holiday', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  UPDATE public.journeys SET note='NoteA', note_hlc_millis=1200, note_hlc_counter=0, note_hlc_device_id='car-2', origin='car', updated_at_utc_millis=1200 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  UPDATE public.insight_places SET name='Beta', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='car-2', origin='car', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.journeys SET started_at_utc_millis=5000, ended_at_utc_millis=6000, time_range_hlc_millis=1500, time_range_hlc_counter=2, time_range_hlc_device_id='phone-2', origin='phone', updated_at_utc_millis=1500 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  SELECT name, latitude INTO v_name, v_lat FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, note, started_at_utc_millis INTO v_jname, v_jnote, v_jstart FROM public.journeys WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  PERFORM assert_eq('perm-A place name', 'Beta', v_name);
  PERFORM assert_eq('perm-A place lat', '10', v_lat::text);
  PERFORM assert_eq('perm-A journey name', 'Holiday', v_jname);
  PERFORM assert_eq('perm-A journey note', 'NoteA', v_jnote);
  PERFORM assert_eq('perm-A journey start', '5000', v_jstart::text);

  -- Order B (reverse)
  PERFORM reset_place(); PERFORM reset_journey();
  UPDATE public.journeys SET started_at_utc_millis=5000, ended_at_utc_millis=6000, time_range_hlc_millis=1500, time_range_hlc_counter=2, time_range_hlc_device_id='phone-2', origin='phone', updated_at_utc_millis=1500 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  UPDATE public.insight_places SET name='Beta', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='car-2', origin='car', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.journeys SET note='NoteA', note_hlc_millis=1200, note_hlc_counter=0, note_hlc_device_id='car-2', origin='car', updated_at_utc_millis=1200 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  UPDATE public.journeys SET name='Holiday', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  UPDATE public.insight_places SET latitude=10, longitude=10, radius_m=100, geofence_hlc_millis=1000, geofence_hlc_counter=1, geofence_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='Alpha', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, latitude INTO v_name, v_lat FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, note, started_at_utc_millis INTO v_jname, v_jnote, v_jstart FROM public.journeys WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  PERFORM assert_eq('perm-B place name', 'Beta', v_name);
  PERFORM assert_eq('perm-B place lat', '10', v_lat::text);
  PERFORM assert_eq('perm-B journey name', 'Holiday', v_jname);
  PERFORM assert_eq('perm-B journey note', 'NoteA', v_jnote);
  PERFORM assert_eq('perm-B journey start', '5000', v_jstart::text);

  -- Idempotence
  PERFORM reset_place();
  UPDATE public.insight_places SET name='Alpha', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name INTO v_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='Alpha', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('idempotence', v_name, (SELECT name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1'));

  RAISE NOTICE 'Test 1 PASS';
END;
$$;

-- ===================================================================
-- 2. Clock test
-- ===================================================================
\echo '=== Test 2: clock skew ==='
DO $$
DECLARE v_name text;
BEGIN
  PERFORM reset_place();
  UPDATE public.insight_places SET name='B_name', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='phone-B', origin='phone', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='A_name', name_hlc_millis=1000, name_hlc_counter=5, name_hlc_device_id='car-A', origin='car', updated_at_utc_millis=900 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name INTO v_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('clock A (counter 5) wins over B', 'A_name', v_name);

  -- reverse order still A
  PERFORM reset_place();
  UPDATE public.insight_places SET name='A_name', name_hlc_millis=1000, name_hlc_counter=5, name_hlc_device_id='car-A', origin='car', updated_at_utc_millis=900 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='B_name', name_hlc_millis=1000, name_hlc_counter=0, name_hlc_device_id='phone-B', origin='phone', updated_at_utc_millis=1000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name INTO v_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('clock reverse still A', 'A_name', v_name);
  RAISE NOTICE 'Test 2 PASS';
END;
$$;

-- ===================================================================
-- 3. Late arrival (3 weeks offline)
-- ===================================================================
\echo '=== Test 3: late arrival ==='
DO $$
DECLARE v_name text; v_millis bigint;
BEGIN
  PERFORM reset_place();
  UPDATE public.insight_places SET name='New3', name_hlc_millis=1700000002000, name_hlc_counter=0, name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=1700000002000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  -- old write 3 weeks earlier
  UPDATE public.insight_places SET name='StaleOld', name_hlc_millis=1698185602000, name_hlc_counter=0, name_hlc_device_id='car-offline', origin='car', updated_at_utc_millis=1698185602000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, name_hlc_millis INTO v_name, v_millis FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('late arrival rejected', 'New3', v_name);
  PERFORM assert_eq('late arrival HLC not regressed', '1700000002000', v_millis::text);
  RAISE NOTICE 'Test 3 PASS';
END;
$$;

-- ===================================================================
-- 4. Field-level merge
-- ===================================================================
\echo '=== Test 4: field-level merge (name vs geofence) ==='
DO $$
DECLARE v_name text; v_lat double precision; v_lon double precision;
BEGIN
  PERFORM reset_place();
  UPDATE public.insight_places SET name='Renamed', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET latitude=51.5, longitude=-0.1, radius_m=250, geofence_hlc_millis=2000, geofence_hlc_counter=1, geofence_hlc_device_id='car-1', origin='car', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, latitude, longitude INTO v_name, v_lat, v_lon FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('field merge name', 'Renamed', v_name);
  PERFORM assert_eq('field merge lat', '51.5', v_lat::text);
  PERFORM assert_eq('field merge lon', '-0.1', v_lon::text);
  -- reverse order same result
  PERFORM reset_place();
  UPDATE public.insight_places SET latitude=51.5, longitude=-0.1, radius_m=250, geofence_hlc_millis=2000, geofence_hlc_counter=1, geofence_hlc_device_id='car-1', origin='car', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='Renamed', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, latitude INTO v_name, v_lat FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('field merge reverse name', 'Renamed', v_name);
  PERFORM assert_eq('field merge reverse lat', '51.5', v_lat::text);
  RAISE NOTICE 'Test 4 PASS';
END;
$$;

-- ===================================================================
-- 5. Exact-tie permutation with interleaved other-group write (H-1)
-- ===================================================================
\echo '=== Test 5: exact-tie permutation (H-1) ==='
DO $$
DECLARE v_name text;
BEGIN
  -- Orders A and B: two name writes at same HLC (2000,0) with different deviceIds (aaa vs zzz), plus geofence 2001 interleaved
  -- Order A: aaa, zzz, geofence
  PERFORM reset_place();
  UPDATE public.insight_places SET name='fromA', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='aaa', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='fromB', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='zzz', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET latitude=10, longitude=0, radius_m=10, geofence_hlc_millis=2001, geofence_hlc_counter=0, geofence_hlc_device_id='ccc', origin='car', updated_at_utc_millis=2001 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name INTO v_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('H-1 order A name should be fromB (zzz > aaa)', 'fromB', v_name);

  -- Order B: aaa, geofence, zzz — should still be fromB after H-1 fix (before fix it was fromA)
  PERFORM reset_place();
  UPDATE public.insight_places SET name='fromA', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='aaa', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET latitude=10, longitude=0, radius_m=10, geofence_hlc_millis=2001, geofence_hlc_counter=0, geofence_hlc_device_id='ccc', origin='car', updated_at_utc_millis=2001 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='fromB', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='zzz', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name INTO v_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('H-1 order B name should still be fromB (convergence)', 'fromB', v_name);

  -- Order C: geofence, aaa, zzz
  PERFORM reset_place();
  UPDATE public.insight_places SET latitude=10, longitude=0, radius_m=10, geofence_hlc_millis=2001, geofence_hlc_counter=0, geofence_hlc_device_id='ccc', origin='car', updated_at_utc_millis=2001 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='fromA', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='aaa', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='fromB', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='zzz', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name INTO v_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('H-1 order C', 'fromB', v_name);

  RAISE NOTICE 'Test 5 PASS';
END;
$$;

-- ===================================================================
-- 6. Tombstone permutations
-- ===================================================================
\echo '=== Test 6: tombstone permutations ==='
DO $$
DECLARE v_name text; v_deleted bigint;
BEGIN
  -- 6a: stale delete rejected (field 3000 > delete 2000)
  PERFORM reset_place();
  UPDATE public.insight_places SET name='Fresh3000', name_hlc_millis=3000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=3000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET deleted_at_utc_millis=2000, updated_at_utc_millis=2000, origin='car' WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, deleted_at_utc_millis INTO v_name, v_deleted FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('tombstone stale delete rejected name', 'Fresh3000', v_name);
  IF v_deleted IS NOT NULL THEN RAISE EXCEPTION 'stale delete should be rejected, deleted should be null got %', v_deleted; END IF;

  -- 6b: valid delete (field 1500, delete 2000)
  PERFORM reset_place();
  UPDATE public.insight_places SET name='Field1500', name_hlc_millis=1500, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1500 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET deleted_at_utc_millis=2000, updated_at_utc_millis=2000, origin='car' WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT deleted_at_utc_millis INTO v_deleted FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('valid delete accepted', '2000', v_deleted::text);

  -- 6c: resurrection accepted (field 2500 > tombstone 2000)
  UPDATE public.insight_places SET name='Resurrect2500', name_hlc_millis=2500, name_hlc_counter=0, name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=2500, deleted_at_utc_millis=null WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, deleted_at_utc_millis INTO v_name, v_deleted FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('resurrection accepted', 'Resurrect2500', v_name);
  IF v_deleted IS NOT NULL THEN RAISE EXCEPTION 'resurrection should clear deleted, got %', v_deleted; END IF;

  -- 6d: resurrection rejected (field 1800 < tombstone 2000)
  PERFORM reset_place();
  UPDATE public.insight_places SET name='Field1500', name_hlc_millis=1500, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=1500 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET deleted_at_utc_millis=2000, updated_at_utc_millis=2000, origin='car' WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET name='StaleResurrect', name_hlc_millis=1800, name_hlc_counter=0, name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=1800, deleted_at_utc_millis=null WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, deleted_at_utc_millis INTO v_name, v_deleted FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('stale resurrection rejected name stays', 'Field1500', v_name);
  PERFORM assert_eq('stale resurrection stays deleted', '2000', v_deleted::text);

  RAISE NOTICE 'Test 6 PASS';
END;
$$;

-- ===================================================================
-- 7. Both-deleted branch (M-2) — all three tombstoned tables
-- ===================================================================
\echo '=== Test 7: both-deleted tombstone gate (M-2) — insight_places, journeys, preferences ==='
DO $$
DECLARE v_name text; v_hlc bigint; v_upd bigint; v_val text;
BEGIN
  -- insight_places: both-deleted with older HLC should not overwrite, metadata must not churn
  PERFORM reset_place();
  DELETE FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  INSERT INTO public.insight_places (id, account_id, name, latitude, longitude, radius_m, created_at_utc_millis, updated_at_utc_millis, origin, deleted_at_utc_millis, name_hlc_millis, name_hlc_counter, name_hlc_device_id, geofence_hlc_millis, geofence_hlc_counter, geofence_hlc_device_id, auto_name_hlc_millis, auto_name_hlc_counter, auto_name_hlc_device_id)
  VALUES ('convergence-place-1', '00000000-0000-0000-0000-000000000001', 'Original', 0, 0, 10, 2500, 2500, 'car', 2500, 2000, 0, 'car-1', 1000, 0, 'init', 1000, 0, 'init');
  UPDATE public.insight_places SET name='Backdoor', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='attacker', origin='phone', updated_at_utc_millis=3000, deleted_at_utc_millis=2500 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name, name_hlc_millis, updated_at_utc_millis INTO v_name, v_hlc, v_upd FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('M-2 insight_places both-deleted older HLC should not overwrite', 'Original', v_name);
  PERFORM assert_eq('M-2 insight_places HLC should stay 2000', '2000', v_hlc::text);
  PERFORM assert_eq('M-2 insight_places updated_at should stay 2500', '2500', v_upd::text);
  UPDATE public.insight_places SET name='NewerBehindTombstone', name_hlc_millis=3000, name_hlc_counter=0, name_hlc_device_id='zzz', origin='phone', updated_at_utc_millis=3000, deleted_at_utc_millis=2600 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT name INTO v_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('M-2 insight_places newer HLC behind tombstone should win', 'NewerBehindTombstone', v_name);

  -- journeys: same gate must protect retained fields behind tombstone
  PERFORM reset_journey();
  DELETE FROM public.journeys WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  INSERT INTO public.journeys (id, account_id, name, started_at_utc_millis, ended_at_utc_millis, note, created_at_utc_millis, updated_at_utc_millis, origin, deleted_at_utc_millis, name_hlc_millis, name_hlc_counter, name_hlc_device_id, note_hlc_millis, note_hlc_counter, note_hlc_device_id, time_range_hlc_millis, time_range_hlc_counter, time_range_hlc_device_id)
  VALUES ('convergence-journey-1', '00000000-0000-0000-0000-000000000001', 'OriginalJourney', 1000, 2000, 'OriginalNote', 2500, 2500, 'car', 2500, 2000, 0, 'car-1', 1000, 0, 'init', 1000, 0, 'init');
  UPDATE public.journeys SET name='BackdoorJourney', name_hlc_millis=2000, name_hlc_counter=0, name_hlc_device_id='attacker', origin='phone', updated_at_utc_millis=3000, deleted_at_utc_millis=2500 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  SELECT name, name_hlc_millis, updated_at_utc_millis INTO v_name, v_hlc, v_upd FROM public.journeys WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  PERFORM assert_eq('M-2 journeys both-deleted older HLC should not overwrite', 'OriginalJourney', v_name);
  PERFORM assert_eq('M-2 journeys HLC should stay 2000', '2000', v_hlc::text);
  PERFORM assert_eq('M-2 journeys updated_at should stay 2500', '2500', v_upd::text);
  UPDATE public.journeys SET name='NewerBehindTombstoneJ', name_hlc_millis=3000, name_hlc_counter=0, name_hlc_device_id='zzz', origin='phone', updated_at_utc_millis=3000, deleted_at_utc_millis=2600 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  SELECT name INTO v_name FROM public.journeys WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-journey-1';
  PERFORM assert_eq('M-2 journeys newer HLC behind tombstone should win', 'NewerBehindTombstoneJ', v_name);

  -- preferences: row-level HLC gate + metadata-churn suppression (O-2)
  DELETE FROM public.preferences WHERE account_id='00000000-0000-0000-0000-000000000001' AND scope='account' AND key='test-both-deleted';
  INSERT INTO public.preferences (account_id, scope, key, value, updated_at_utc_millis, origin, deleted_at_utc_millis, hlc_millis, hlc_counter, hlc_device_id)
  VALUES ('00000000-0000-0000-0000-000000000001', 'account', 'test-both-deleted', 'OriginalPref', 2500, 'car', 2500, 2000, 0, 'car-1');
  UPDATE public.preferences SET value='BackdoorPref', hlc_millis=2000, hlc_counter=0, hlc_device_id='attacker', origin='phone', updated_at_utc_millis=3000, deleted_at_utc_millis=2500 WHERE account_id='00000000-0000-0000-0000-000000000001' AND scope='account' AND key='test-both-deleted';
  SELECT value, hlc_millis, updated_at_utc_millis INTO v_val, v_hlc, v_upd FROM public.preferences WHERE account_id='00000000-0000-0000-0000-000000000001' AND scope='account' AND key='test-both-deleted';
  PERFORM assert_eq('M-2 preferences both-deleted older HLC should not overwrite', 'OriginalPref', v_val);
  PERFORM assert_eq('M-2 preferences HLC should stay 2000', '2000', v_hlc::text);
  PERFORM assert_eq('M-2 preferences updated_at should stay 2500 (O-2)', '2500', v_upd::text);
  UPDATE public.preferences SET value='NewerBehindTombstonePref', hlc_millis=3000, hlc_counter=0, hlc_device_id='zzz', origin='phone', updated_at_utc_millis=3000, deleted_at_utc_millis=2600 WHERE account_id='00000000-0000-0000-0000-000000000001' AND scope='account' AND key='test-both-deleted';
  SELECT value INTO v_val FROM public.preferences WHERE account_id='00000000-0000-0000-0000-000000000001' AND scope='account' AND key='test-both-deleted';
  PERFORM assert_eq('M-2 preferences newer HLC behind tombstone should win', 'NewerBehindTombstonePref', v_val);

  RAISE NOTICE 'Test 7 PASS';
END;
$$;

-- ===================================================================
-- 8. Auto_name merge (M-3) — ADR 0009 car > phone > cloud
-- ===================================================================
\echo '=== Test 8: auto_name merge (M-3) ==='
DO $$
DECLARE v_auto text;
BEGIN
  PERFORM reset_place();
  -- Car vs phone at same HLC: car should win for auto_name
  UPDATE public.insight_places SET auto_name='PhoneSuggestion', auto_name_updated_at_utc_millis=2000, auto_name_source='nominatim', auto_name_hlc_millis=2000, auto_name_hlc_counter=0, auto_name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET auto_name='CarSuggestion', auto_name_updated_at_utc_millis=2000, auto_name_source='nominatim', auto_name_hlc_millis=2000, auto_name_hlc_counter=0, auto_name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT auto_name INTO v_auto FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('M-3 car beats phone', 'CarSuggestion', v_auto);

  -- Reverse order still car
  PERFORM reset_place();
  UPDATE public.insight_places SET auto_name='CarSuggestion', auto_name_updated_at_utc_millis=2000, auto_name_source='nominatim', auto_name_hlc_millis=2000, auto_name_hlc_counter=0, auto_name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET auto_name='PhoneSuggestion', auto_name_updated_at_utc_millis=2000, auto_name_source='nominatim', auto_name_hlc_millis=2000, auto_name_hlc_counter=0, auto_name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=2000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT auto_name INTO v_auto FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('M-3 reverse still car', 'CarSuggestion', v_auto);

  -- Phone vs cloud: phone wins
  PERFORM reset_place();
  UPDATE public.insight_places SET auto_name='CloudSuggestion', auto_name_updated_at_utc_millis=4000, auto_name_source='nominatim', auto_name_hlc_millis=4000, auto_name_hlc_counter=0, auto_name_hlc_device_id='cloud-1', origin='cloud', updated_at_utc_millis=4000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET auto_name='PhoneSuggestion2', auto_name_updated_at_utc_millis=4000, auto_name_source='nominatim', auto_name_hlc_millis=4000, auto_name_hlc_counter=0, auto_name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=4000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  SELECT auto_name INTO v_auto FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('M-3 phone beats cloud', 'PhoneSuggestion2', v_auto);

  -- Field independence: auto_name edit does not affect name
  PERFORM reset_place();
  UPDATE public.insight_places SET name='Renamed', name_hlc_millis=5000, name_hlc_counter=0, name_hlc_device_id='car-1', origin='car', updated_at_utc_millis=5000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  UPDATE public.insight_places SET auto_name='Auto5000', auto_name_updated_at_utc_millis=5000, auto_name_source='nominatim', auto_name_hlc_millis=5000, auto_name_hlc_counter=0, auto_name_hlc_device_id='phone-1', origin='phone', updated_at_utc_millis=5000 WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1';
  PERFORM assert_eq('M-3 name survives auto_name edit', 'Renamed', (SELECT name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1'));
  PERFORM assert_eq('M-3 auto_name survives', 'Auto5000', (SELECT auto_name FROM public.insight_places WHERE account_id='00000000-0000-0000-0000-000000000001' AND id='convergence-place-1'));

  RAISE NOTICE 'Test 8 PASS';
END;
$$;

\echo '=== All 8 convergence tests PASSED ==='
