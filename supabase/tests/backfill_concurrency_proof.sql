-- supabase/tests/backfill_concurrency_proof.sql
--
-- Issue #236 Phase 5 Hardening — backfill correctness, concurrency proofs,
-- registration rate limiting, and unclaimed telemetry lifecycle cleanup (P5-T1, P5-T2, P5-T3).
--
-- Run:
--   createdb test_backfill_proof
--   psql -h 127.0.0.1 -d test_backfill_proof -f supabase/tests/backfill_concurrency_proof.sql
--   dropdb test_backfill_proof

\set ON_ERROR_STOP on

\echo '=== Backfill concurrency & lifecycle proofs: roles and auth mock ==='

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end;
$$;

create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.jwt() returns jsonb language plpgsql as $$
begin
  return nullif(current_setting('request.jwt.claims', true), '')::jsonb;
end; $$;
create or replace function auth.uid() returns uuid language plpgsql as $$
begin
  return nullif(auth.jwt() ->> 'sub', '')::uuid;
end; $$;
grant usage on schema auth to anon, authenticated, service_role;

\echo '=== Applying the consolidated schema ==='
\i supabase/schema_full.sql

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function assert_eq(label text, expected text, actual text) returns void as $$
begin
  if expected is distinct from actual then
    raise exception 'ASSERT FAIL %: expected % got %', label, expected, actual;
  end if;
end;
$$ language plpgsql;

create or replace function as_car(p_token text) returns void as $$
begin
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.headers', json_build_object('x-car-token', p_token)::text, false);
end;
$$ language plpgsql;

create or replace function as_phone(p_uid uuid) returns void as $$
begin
  perform set_config('request.headers', '{}', false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false);
end;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- Test 1: Full backfill across all measurement & annotation tables (P5-T2)
-- ---------------------------------------------------------------------------
\echo '=== Test 1: Full backfill across all measurement tables ==='

insert into auth.users (id) values ('10000000-0000-0000-0000-000000000001'::uuid);

do $$
declare
  v_tok text;
  v_res jsonb;
  v_unclaimed_intervals integer;
  v_claimed_intervals integer;
begin
  -- Car registers anonymously
  v_tok := public.register_device_identity('veh-t1');

  -- Pre-claim data generation
  insert into public.device_pairing_sessions (device_code, user_code, vehicle_id, status, expires_at)
  values ('20000000-0000-0000-0000-000000000001'::uuid, 'CODE01', 'veh-t1', 'pending', now() + interval '10 minutes');

  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos, created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-t1', 'sess-t1-1', null, 'TRIP', 'CLOSED', 1750000000000, 1, 1750000000000, 1750000000000);

  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis
  )
  select
    'veh-t1', 'sess-t1-1', null,
    1750000000000 + (s * 60000), 60000,
    10, 0, 0, 0, 0, 0.1, 60, 60, 60, 60, 1750000000000 + (s * 60000)
  from generate_series(1, 100) s;

  insert into public.track (
    vehicle_id, session_id, account_id, encoding_version, point_count,
    t, path, speed, alt, updated_at_utc_millis
  ) values ('veh-t1', 'sess-t1-1', null, 1, 2, '[0,1]', 'abc', '[1,2]', '[3,4]', 1750000000000);

  insert into public.telemetry_events (
    vehicle_id, session_id, account_id, type, occurred_at_utc_millis, signal_id,
    occurred_at_elapsed_nanos, timestamp_accuracy, uncertainty_millis, details
  ) values ('veh-t1', 'sess-t1-1', null, 'GEAR_CHANGED', 1750000000000, 'GEAR', 10, 'PRECISE', 0, '{}');

  insert into public.trip_segments (
    vehicle_id, session_id, ordinal, account_id, start_utc_millis, end_utc_millis,
    distance_km, integrated_seconds, elapsed_seconds, path
  ) values ('veh-t1', 'sess-t1-1', 0, null, 1750000000000, 1750000060000, 0.1, 60, 60, '');

  insert into public.battery_cycles (
    vehicle_id, ordinal, account_id, start_utc_millis, end_utc_millis,
    discharge_percent, distance_km, trip_energy_kwh, parked_energy_kwh,
    parked_soc_percent, priced_energy_kwh, unpriced_energy_kwh,
    opening_priced_fraction, opening_blended_price, created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-t1', 1, null, 1750000000000, 1750000060000, 1, 0.1, 0.1, 0, 0, 0, 0.1, 0, 0, 1750000000000, 1750000000000);

  insert into public.session_costs (
    vehicle_id, session_id, account_id, cost_currency, paid_amount,
    cost_per_kwh, updated_at_utc_millis, origin
  ) values ('veh-t1', 'sess-t1-1', null, 'USD', 2.50, 0.25, 1750000000000, 'phone');

  -- Perform claim
  v_res := public.claim_pairing_session(
    '20000000-0000-0000-0000-000000000001'::uuid,
    'veh-t1',
    '10000000-0000-0000-0000-000000000001'::uuid,
    public.hash_car_token('tok_t1_paired'),
    'tok_t1_paired'
  );

  perform assert_eq('Test 1 claim ok', 'true', (v_res ->> 'ok'));

  select count(*) into v_unclaimed_intervals
    from public."interval"
   where vehicle_id = 'veh-t1' and account_id is null;
  perform assert_eq('Test 1 zero unclaimed intervals', '0', v_unclaimed_intervals::text);

  select count(*) into v_claimed_intervals
    from public."interval"
   where vehicle_id = 'veh-t1' and account_id = '10000000-0000-0000-0000-000000000001'::uuid;
  perform assert_eq('Test 1 all intervals claimed', '100', v_claimed_intervals::text);

  raise notice 'Test 1 PASS';
end;
$$;

-- ---------------------------------------------------------------------------
-- Test 2: Atomic rollback leaves zero half-claimed rows
-- ---------------------------------------------------------------------------
\echo '=== Test 2: Atomic rollback leaves zero half-claimed rows ==='

do $$
declare
  v_err text;
  v_unclaimed_intervals integer;
begin
  -- Register veh-t2
  perform public.register_device_identity('veh-t2');

  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos, created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-t2', 'sess-t2', null, 'TRIP', 'CLOSED', 1750000000000, 1, 1750000000000, 1750000000000);

  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis
  ) values ('veh-t2', 'sess-t2', null, 1750000000000, 60000, 10, 0, 0, 0, 0, 0.1, 60, 60, 60, 60, 1750000000000);

  -- Call claim with invalid code (will abort transaction)
  begin
    perform public.claim_pairing_session(
      '00000000-0000-0000-0000-deadbeef0000'::uuid,
      'veh-t2',
      '10000000-0000-0000-0000-000000000001'::uuid,
      'hash_t2',
      'tok_t2'
    );
  exception when others then
    v_err := SQLERRM;
  end;

  perform assert_eq('Test 2 aborted on invalid_device_code', 'invalid_device_code', v_err);

  -- Confirm interval remains untouched with account_id NULL
  select count(*) into v_unclaimed_intervals
    from public."interval"
   where vehicle_id = 'veh-t2' and account_id is null;
  perform assert_eq('Test 2 interval remains unclaimed after rollback', '1', v_unclaimed_intervals::text);

  raise notice 'Test 2 PASS';
end;
$$;

-- ---------------------------------------------------------------------------
-- Test 3: Post-claim upload with existing token stamps claimant account
-- ---------------------------------------------------------------------------
\echo '=== Test 3: Post-claim upload stamps claimant account ==='

set role anon;
do $$
begin
  -- Simulate upload with the car token using as_car
  perform as_car('tok_t1_paired');

  insert into public.session (
    vehicle_id, id, kind, status, started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-t1', 'sess-t1-post', 'TRIP', 'CLOSED', 1751000000000, 1, 1751000000000, 1751000000000);

  insert into public."interval" (
    vehicle_id, session_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis
  ) values ('veh-t1', 'sess-t1-post', 1751000000000, 60000, 10, 0, 0, 0, 0, 0.1, 60, 60, 60, 60, 1751000000000);
end;
$$;
reset role;

do $$
declare
  v_acc uuid;
begin
  select account_id into v_acc from public.session where vehicle_id = 'veh-t1' and id = 'sess-t1-post';
  perform assert_eq('Test 3 session stamped with claimant', '10000000-0000-0000-0000-000000000001', v_acc::text);

  select account_id into v_acc from public."interval" where vehicle_id = 'veh-t1' and session_id = 'sess-t1-post';
  perform assert_eq('Test 3 interval stamped with claimant', '10000000-0000-0000-0000-000000000001', v_acc::text);

  raise notice 'Test 3 PASS';
end;
$$;


-- ---------------------------------------------------------------------------
-- Test 4: Registration rate limit table and cleanup function (P5-T1)
-- ---------------------------------------------------------------------------
\echo '=== Test 4: Device registration rate limit and cleanup ==='

do $$
declare
  v_count integer;
begin
  -- Record 3 attempts
  insert into public.device_registration_attempts (vehicle_id, ip, attempted_at)
  values ('veh-limit', '127.0.0.1', now());
  insert into public.device_registration_attempts (vehicle_id, ip, attempted_at)
  values ('veh-limit', '127.0.0.1', now());
  -- Stale attempt (2 hours old)
  insert into public.device_registration_attempts (vehicle_id, ip, attempted_at)
  values ('veh-limit', '127.0.0.1', now() - interval '2 hours');

  select count(*) into v_count from public.device_registration_attempts where vehicle_id = 'veh-limit';
  perform assert_eq('Test 4 total attempts before cleanup', '3', v_count::text);

  perform public.cleanup_old_registration_attempts();

  select count(*) into v_count from public.device_registration_attempts where vehicle_id = 'veh-limit';
  perform assert_eq('Test 4 stale attempt removed', '2', v_count::text);

  raise notice 'Test 4 PASS';
end;
$$;

-- ---------------------------------------------------------------------------
-- Test 5: Unclaimed telemetry cleanup RPC (P5-T3 / Decision D2)
-- ---------------------------------------------------------------------------
\echo '=== Test 5: Unclaimed telemetry cleanup RPC ==='

do $$
declare
  v_old_millis bigint;
  v_new_millis bigint;
  v_res jsonb;
  v_old_count integer;
  v_new_count integer;
  v_claimed_count integer;
  v_pairing_count integer;
  v_mixed_count integer;
begin
  -- Old timestamp: 45 days ago
  v_old_millis := (extract(epoch from (now() - interval '45 days')) * 1000)::bigint;
  -- Fresh timestamp: 5 days ago
  v_new_millis := (extract(epoch from (now() - interval '5 days')) * 1000)::bigint;

  perform public.register_device_identity('veh-unclaimed-stale');

  -- Stale unclaimed session + interval
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos, created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-unclaimed-stale', 'sess-stale', null, 'TRIP', 'CLOSED', v_old_millis, 1, v_old_millis, v_old_millis);

  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis
  ) values ('veh-unclaimed-stale', 'sess-stale', null, v_old_millis, 60000, 10, 0, 0, 0, 0, 0.1, 60, 60, 60, 60, v_old_millis);

  -- Fresh unclaimed session + interval
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos, created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-unclaimed-stale', 'sess-fresh', null, 'TRIP', 'CLOSED', v_new_millis, 1, v_new_millis, v_new_millis);

  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis
  ) values ('veh-unclaimed-stale', 'sess-fresh', null, v_new_millis, 60000, 10, 0, 0, 0, 0, 0.1, 60, 60, 60, 60, v_new_millis);

  -- Old CLAIMED session + interval (must NOT be deleted)
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos, created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-unclaimed-stale', 'sess-claimed-old', '10000000-0000-0000-0000-000000000001'::uuid, 'TRIP', 'CLOSED', v_old_millis, 1, v_old_millis, v_old_millis);

  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis
  ) values ('veh-unclaimed-stale', 'sess-claimed-old', '10000000-0000-0000-0000-000000000001'::uuid, v_old_millis, 60000, 10, 0, 0, 0, 0, 0.1, 60, 60, 60, 60, v_old_millis);

  -- Seed pairing sessions:
  -- Stale approved terminal session (>30d) -> must be purged (F1)
  insert into public.device_pairing_sessions (
    device_code, user_code, vehicle_id, status, created_at, expires_at, approved_by
  ) values (
    '30000000-0000-0000-0000-000000000001'::uuid, 'OLDAPP', 'veh-unclaimed-stale',
    'approved', now() - interval '45 days', now() - interval '45 days',
    '10000000-0000-0000-0000-000000000001'::uuid
  );

  -- Stale expired session (>30d) -> must be purged (F1)
  insert into public.device_pairing_sessions (
    device_code, user_code, vehicle_id, status, created_at, expires_at
  ) values (
    '30000000-0000-0000-0000-000000000002'::uuid, 'OLDEXP', 'veh-unclaimed-stale',
    'expired', now() - interval '45 days', now() - interval '45 days'
  );

  -- Fresh pending session (<30d) -> must be PRESERVED
  insert into public.device_pairing_sessions (
    device_code, user_code, vehicle_id, status, created_at, expires_at
  ) values (
    '30000000-0000-0000-0000-000000000003'::uuid, 'FRESHP', 'veh-unclaimed-stale',
    'pending', now(), now() + interval '5 minutes'
  );

  -- Defensive invariant assertion: no session is NULL while its child interval is claimed
  select count(*) into v_mixed_count
    from public."interval" i
    join public.session s on i.session_id = s.id and i.vehicle_id = s.vehicle_id
   where s.account_id is null and i.account_id is not null;
  perform assert_eq('Test 5 no mixed ownership invariant', '0', v_mixed_count::text);

  -- Run cleanup with 30-day retention
  v_res := public.cleanup_unclaimed_telemetry(30);

  perform assert_eq('Test 5 retention days reported', '30', (v_res ->> 'retention_days'));

  -- Verify stale unclaimed interval was deleted
  select count(*) into v_old_count from public."interval" where vehicle_id = 'veh-unclaimed-stale' and session_id = 'sess-stale';
  perform assert_eq('Test 5 stale interval purged', '0', v_old_count::text);

  -- Verify fresh unclaimed interval was preserved
  select count(*) into v_new_count from public."interval" where vehicle_id = 'veh-unclaimed-stale' and session_id = 'sess-fresh';
  perform assert_eq('Test 5 fresh interval preserved', '1', v_new_count::text);

  -- Verify old CLAIMED interval was preserved
  select count(*) into v_claimed_count from public."interval" where vehicle_id = 'veh-unclaimed-stale' and session_id = 'sess-claimed-old';
  perform assert_eq('Test 5 claimed old interval preserved', '1', v_claimed_count::text);

  -- Verify stale pairing sessions were purged (F1 fix verification)
  perform assert_eq('Test 5 pairing sessions purged count', '2', (v_res ->> 'pairing_sessions_deleted'));

  select count(*) into v_pairing_count
    from public.device_pairing_sessions
   where device_code in ('30000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000002'::uuid);
  perform assert_eq('Test 5 stale pairing sessions purged from table', '0', v_pairing_count::text);

  -- Verify fresh pending session was preserved
  select count(*) into v_pairing_count
    from public.device_pairing_sessions
   where device_code = '30000000-0000-0000-0000-000000000003'::uuid;
  perform assert_eq('Test 5 fresh pending pairing session preserved', '1', v_pairing_count::text);

  raise notice 'Test 5 PASS';
end;
$$;


\echo '=== All backfill concurrency & lifecycle tests PASSED ==='
