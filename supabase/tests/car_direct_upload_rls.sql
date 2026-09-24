-- supabase/tests/car_direct_upload_rls.sql
--
-- Issue #236 Phase 1 — proofs P1..P17 for direct car upload: nullable
-- `account_id`, the server-side stamp trigger, and the `anon` device policies
-- added by `supabase/migrations/20260903120000_car_direct_upload_schema.sql`.
--
-- Run (from the repository root, against a scratch database):
--   createdb test_car_direct_upload
--   psql -h 127.0.0.1 -d test_car_direct_upload -f supabase/tests/car_direct_upload_rls.sql
--
-- The whole schema is applied from `supabase/schema_full.sql`, which the
-- Kotlin schema tests hold in parity with the migrations. Every negative case
-- runs under `SET ROLE anon` / `SET ROLE authenticated` with the real
-- `request.headers` / `request.jwt.claims` GUCs, so a refusal is proven by
-- Postgres RLS, not by application logic.
--
-- The invariant under test:
--
--   A measurement row's `account_id` is always the value the server derives
--   from the request identity at write time. An unclaimed row holds NULL; a
--   claimed row holds the claimer's id. The phone's RLS reads the column; the
--   car's RLS reads the token's vehicle on every clause, and the token's
--   account as well on the clauses that see a row already in the table, so a
--   vehicle carrying two live credentials keeps the two accounts apart
--   (P16, P17). The phone road and the car road never overlap, because the
--   phone never runs as `anon` and the car never holds a user JWT.

\set ON_ERROR_STOP on

\echo '=== Car direct upload: auth mock ==='

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

-- auth schema mock mirroring Supabase's real `auth.uid()` semantics: read the
-- `sub` claim from the `request.jwt.claims` GUC (set by PostgREST per request).
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

-- Run a statement under the current role and demand that Postgres refuse it
-- through RLS. `SET ROLE` before calling decides which road the write takes.
create or replace function expect_rls_rejected(label text, p_sql text) returns void as $$
declare
  v_error boolean := false;
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    v_error := true;
    get stacked diagnostics v_msg = message_text;
  end;
  if not v_error then
    raise exception 'ASSERT FAIL %: expected RLS rejection, statement succeeded', label;
  end if;
  if v_msg !~* 'row-level security policy' then
    raise exception 'ASSERT FAIL %: rejected, but not by RLS (got: %)', label, v_msg;
  end if;
end;
$$ language plpgsql;

create or replace function as_car(p_token text) returns void as $$
begin
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.headers', json_build_object('x-car-token', p_token)::text, false);
end;
$$ language plpgsql;

create or replace function as_nobody() returns void as $$
begin
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.headers', '{}', false);
end;
$$ language plpgsql;

create or replace function as_phone(p_uid uuid) returns void as $$
begin
  perform set_config('request.headers', '{}', false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false);
end;
$$ language plpgsql;

-- A phone that also presents a car token (the P12 spoof attempt).
create or replace function as_phone_with_token(p_uid uuid, p_token text) returns void as $$
begin
  perform set_config('request.headers', json_build_object('x-car-token', p_token)::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false);
end;
$$ language plpgsql;

-- One session row, written with whatever `account_id` the caller claims. The
-- point of most proofs is that the claimed value never survives.
create or replace function session_insert_sql(
  p_vehicle text, p_id text, p_account text, p_started bigint
) returns text as $$
begin
  return format(
    'insert into public.session (vehicle_id, id, account_id, kind, status, '
    || 'started_at_utc_millis, started_at_elapsed_nanos, '
    || 'created_at_utc_millis, updated_at_utc_millis) '
    || 'values (%L, %L, %s, ''TRIP'', ''CLOSED'', %s, 1, %s, %s)',
    p_vehicle, p_id,
    case when p_account is null then 'null' else quote_literal(p_account) || '::uuid' end,
    p_started, p_started, p_started
  );
end;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- Seed (as superuser; the stamp trigger leaves privileged writers alone)
-- ---------------------------------------------------------------------------

\echo '=== Seeding: accounts A and B, vehicle X (unclaimed), vehicle Y (claimed by A) ==='

select as_nobody();

delete from public.session_costs;
delete from public.battery_cycle_sessions;
delete from public.battery_cycles;
delete from public.trip_segments;
delete from public.track;
delete from public."interval";
delete from public.telemetry_events;
delete from public.session;
delete from public.vehicle;
delete from public.vehicle_devices;
delete from public.vehicle_ownership;
delete from auth.users;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b');

-- veh-X: registered but never claimed. Vehicle row and device credential both
-- carry a NULL account_id — the shape Phase 2 registration will create.
insert into public.vehicle (vehicle_id, account_id, display_name)
values ('veh-X', null, 'unclaimed car');
insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
values ('veh-X', null, public.hash_car_token('tok-X'));

-- veh-Y: claimed by account A.
insert into public.vehicle (vehicle_id, account_id, display_name)
values ('veh-Y', '00000000-0000-0000-0000-00000000000a', 'claimed car');
insert into public.vehicle_ownership (vehicle_id, account_id)
values ('veh-Y', '00000000-0000-0000-0000-00000000000a');
insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
values ('veh-Y', '00000000-0000-0000-0000-00000000000a', public.hash_car_token('tok-Y'));

-- A revoked credential for veh-Y (P4).
insert into public.vehicle_devices (vehicle_id, account_id, token_hash, revoked_at)
values ('veh-Y', '00000000-0000-0000-0000-00000000000a', public.hash_car_token('tok-Y-revoked'), now());

-- ===========================================================================
-- P1 — Unclaimed upload: every measurement table accepts a car write for its
--      own vehicle, and stores account_id NULL.
-- ===========================================================================
\echo '=== P1: unclaimed upload stores NULL account_id ==='
set role anon;
do $$
begin
  perform as_car('tok-X');

  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-X', 'sess-x1', null, 'TRIP', 'CLOSED', 1750000000000, 1, 1750000000000, 1750000000000);

  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis
  ) values ('veh-X', 'sess-x1', null, 1750000000000, 60000,
            1, 0, 0, 0, 0, 0.1, 60, 60, 60, 60, 1750000000000);

  insert into public.track (
    vehicle_id, session_id, account_id, encoding_version, point_count,
    t, path, speed, alt, updated_at_utc_millis
  ) values ('veh-X', 'sess-x1', null, 1, 2, '[0,1]', 'abc', '[1,2]', '[3,4]', 1750000000000);

  insert into public.telemetry_events (
    vehicle_id, session_id, account_id, type, occurred_at_utc_millis, signal_id,
    occurred_at_elapsed_nanos, timestamp_accuracy, uncertainty_millis, details
  ) values ('veh-X', 'sess-x1', null, 'GEAR_CHANGED', 1750000000000, 'GEAR',
            10, 'PRECISE', 0, '{}');

  insert into public.trip_segments (
    vehicle_id, session_id, ordinal, account_id, start_utc_millis, end_utc_millis,
    distance_km, integrated_seconds, elapsed_seconds, path
  ) values ('veh-X', 'sess-x1', 0, null, 1750000000000, 1750000060000,
            0.1, 60, 60, '');

  insert into public.battery_cycles (
    vehicle_id, ordinal, account_id, start_utc_millis, end_utc_millis,
    discharge_percent, distance_km, trip_energy_kwh, parked_energy_kwh,
    parked_soc_percent, priced_energy_kwh, unpriced_energy_kwh,
    opening_priced_fraction, opening_blended_price,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-X', 1, null, 1750000000000, 1750000060000,
            1, 0.1, 0.1, 0, 0, 0, 0.1, 0, 0, 1750000000000, 1750000000000);

  insert into public.battery_cycle_sessions (
    vehicle_id, cycle_ordinal, session_kind, session_id, account_id, share,
    start_utc_millis, end_utc_millis, cycle_start_utc_millis
  ) values ('veh-X', 1, 'TRIP', 'sess-x1', null, 1.0,
            1750000000000, 1750000060000, 1750000000000);

  insert into public.session_costs (
    vehicle_id, session_id, cost_per_kwh, paid_amount, cost_currency,
    updated_at_utc_millis, origin
  ) values ('veh-X', 'sess-x1', 0.50, 10.0, 'BRL', 1750000000000, 'car');

  raise notice 'P1: eight car writes accepted';
end;
$$;
reset role;

do $$
declare v_nulls integer;
begin
  select
    (select count(*) from public.session where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public."interval" where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.track where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.telemetry_events where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.trip_segments where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.battery_cycles where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.battery_cycle_sessions where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.session_costs where vehicle_id='veh-X' and account_id is null)
  into v_nulls;
  perform assert_eq('P1 all eight rows stored with NULL account_id', '8', v_nulls::text);
  raise notice 'P1 PASS';
end;
$$;

-- ===========================================================================
-- P2 — No token: the car has no identity, so no policy matches.
-- ===========================================================================
\echo '=== P2: write with no token is refused ==='
set role anon;
do $$
begin
  perform as_nobody();
  perform expect_rls_rejected(
    'P2 no token cannot insert',
    session_insert_sql('veh-X', 'sess-p2', null, 1750000100000));
  raise notice 'P2 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P3 — Cross-vehicle write: a token for veh-X cannot write veh-Y.
-- ===========================================================================
\echo '=== P3: cross-vehicle write is refused ==='
set role anon;
do $$
begin
  perform as_car('tok-X');
  perform expect_rls_rejected(
    'P3 token-X cannot insert for veh-Y',
    session_insert_sql('veh-Y', 'sess-p3', null, 1750000100000));
  raise notice 'P3 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P4 — Revoked token: identity resolves to null, so both read and write fail.
-- ===========================================================================
\echo '=== P4: revoked token cannot read or write ==='
set role anon;
do $$
declare v_n integer;
begin
  perform as_car('tok-Y-revoked');
  perform expect_rls_rejected(
    'P4 revoked token cannot insert',
    session_insert_sql('veh-Y', 'sess-p4', null, 1750000100000));
  select count(*) into v_n from public.session;
  perform assert_eq('P4 revoked token reads nothing', '0', v_n::text);
  raise notice 'P4 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P5 — Unknown token: same as no token.
-- ===========================================================================
\echo '=== P5: unknown token cannot read or write ==='
set role anon;
do $$
declare v_n integer;
begin
  perform as_car('tok-garbage');
  perform expect_rls_rejected(
    'P5 unknown token cannot insert',
    session_insert_sql('veh-X', 'sess-p5', null, 1750000100000));
  select count(*) into v_n from public.session;
  perform assert_eq('P5 unknown token reads nothing', '0', v_n::text);
  raise notice 'P5 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P6 — The phone before the claim: an unclaimed row carries NULL, and NULL is
--      never equal to an account id, so the phone sees nothing.
-- ===========================================================================
\echo '=== P6: phone sees no unclaimed rows ==='
set role authenticated;
do $$
declare v_n integer;
begin
  perform as_phone('00000000-0000-0000-0000-00000000000a');
  select count(*) into v_n from public.session where vehicle_id = 'veh-X';
  perform assert_eq('P6 account A sees no unclaimed session', '0', v_n::text);
  select count(*) into v_n from public."interval" where vehicle_id = 'veh-X';
  perform assert_eq('P6 account A sees no unclaimed interval', '0', v_n::text);
  select count(*) into v_n from public.telemetry_events where vehicle_id = 'veh-X';
  perform assert_eq('P6 account A sees no unclaimed event', '0', v_n::text);
  select count(*) into v_n from public.session_costs where vehicle_id = 'veh-X';
  perform assert_eq('P6 account A sees no unclaimed session cost', '0', v_n::text);
  raise notice 'P6 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P7 — The phone after the claim. The claim runs through the real
--      `public.claim_pairing_session` RPC (Phase 3 backfill): a privileged
--      backfill of the NULL rows inside the claim transaction. What is
--      proved here is the part Phase 1 owns — that the phone's read policy
--      then returns every backfilled row, on every table, with no window.
-- ===========================================================================
\echo '=== P7: phone sees every row after the claim backfill ==='
do $$
declare
  v_a uuid := '00000000-0000-0000-0000-00000000000a';
  v_code uuid := gen_random_uuid();
  v_res jsonb;
  v_seed_nulls integer;
begin
  -- Count exactly the rows the backfill will adopt: the NULL rows the
  -- P1 block wrote for veh-X. The RPC's `backfilled` must equal this —
  -- the count comes from the writes themselves (ROW_COUNT), not a
  -- separate recompute that could disagree with what was moved.
  select
    (select count(*) from public.vehicle where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.vehicle_devices where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.session where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public."interval" where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.track where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.telemetry_events where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.trip_segments where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.battery_cycles where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.battery_cycle_sessions where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.session_costs where vehicle_id='veh-X' and account_id is null)
   into v_seed_nulls;

  insert into public.device_pairing_sessions (device_code, user_code, vehicle_id)
  values (v_code, '11111111', 'veh-X');

  v_res := public.claim_pairing_session(
    v_code, 'veh-X', v_a,
    public.hash_car_token('tok-X-claim'), 'car-token-x1');
  -- Exact success shape: {ok: true, backfilled: N}. Nothing else.
  perform assert_eq('P7 claim RPC success shape',
    ('{"ok": true, "backfilled": ' || v_seed_nulls::text || '}')::jsonb::text, v_res::text);
  -- The reported count equals the rows actually adopted — not merely that
  -- a key exists.
  perform assert_eq('P7 claim reports exact adopted-row count',
                    v_seed_nulls::text, (v_res->>'backfilled')::text);
  raise notice 'P7 claim count PASS';
end;
$$;

do $$
declare v_nulls integer;
begin
  select
    (select count(*) from public.session where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public."interval" where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.track where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.telemetry_events where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.trip_segments where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.battery_cycles where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.battery_cycle_sessions where vehicle_id='veh-X' and account_id is null)
  + (select count(*) from public.session_costs where vehicle_id='veh-X' and account_id is null)
  into v_nulls;
  perform assert_eq('P7 backfill leaves no NULL account_id', '0', v_nulls::text);
end;
$$;

set role authenticated;
do $$
declare v_n integer;
begin
  perform as_phone('00000000-0000-0000-0000-00000000000a');
  select
    (select count(*) from public.session where vehicle_id='veh-X')
  + (select count(*) from public."interval" where vehicle_id='veh-X')
  + (select count(*) from public.track where vehicle_id='veh-X')
  + (select count(*) from public.telemetry_events where vehicle_id='veh-X')
  + (select count(*) from public.trip_segments where vehicle_id='veh-X')
  + (select count(*) from public.battery_cycles where vehicle_id='veh-X')
  + (select count(*) from public.battery_cycle_sessions where vehicle_id='veh-X')
  + (select count(*) from public.session_costs where vehicle_id='veh-X')
  into v_n;
  perform assert_eq('P7 account A now reads all eight rows', '8', v_n::text);
  raise notice 'P7 PASS';
end;
$$;
reset role;

-- A post-claim car write must land with the claimer's id, not NULL.
\echo '=== P7b: a post-claim car write is stamped with the claimer id ==='
set role anon;
do $$
begin
  perform as_car('tok-X');
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-X', 'sess-x2', null, 'TRIP', 'CLOSED', 1750000200000, 1, 1750000200000, 1750000200000);
end;
$$;
reset role;
do $$
declare v_acc text;
begin
  select account_id::text into v_acc from public.session where id='sess-x2';
  perform assert_eq('P7b post-claim write stamped with claimer',
                    '00000000-0000-0000-0000-00000000000a', v_acc);
  raise notice 'P7b PASS';
end;
$$;

-- ===========================================================================
-- P8 / P9 — The car reads its own vehicle and only its own vehicle.
-- ===========================================================================
\echo '=== P8/P9: the car reads only its own vehicle ==='
-- Give veh-Y one row of its own to read (written by its own token).
set role anon;
do $$
begin
  perform as_car('tok-Y');
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-Y', 'sess-y1', null, 'TRIP', 'CLOSED', 1750000300000, 1, 1750000300000, 1750000300000);
end;
$$;

do $$
declare v_own integer; v_other integer; v_total integer;
begin
  perform as_car('tok-X');
  select count(*) into v_own from public.session where vehicle_id = 'veh-X';
  select count(*) into v_other from public.session where vehicle_id = 'veh-Y';
  select count(*) into v_total from public.session;
  perform assert_eq('P8 car X reads its own two sessions', '2', v_own::text);
  perform assert_eq('P9 car X reads none of veh-Y', '0', v_other::text);
  perform assert_eq('P8 car X sees nothing else at all', v_own::text, v_total::text);
  raise notice 'P8/P9 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P10 — The car cannot forge account_id. A payload naming account B is stamped
--       with the token's own account instead.
-- ===========================================================================
\echo '=== P10: a forged account_id in the payload is overwritten ==='
set role anon;
do $$
begin
  perform as_car('tok-Y');
  -- INSERT carrying account B
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-Y', 'sess-y-forge', '00000000-0000-0000-0000-00000000000b',
            'TRIP', 'CLOSED', 1750000400000, 1, 1750000400000, 1750000400000);
  -- UPDATE carrying account B
  update public.session
     set account_id = '00000000-0000-0000-0000-00000000000b',
         status = 'CLOSED'
   where vehicle_id = 'veh-Y' and id = 'sess-y1';
end;
$$;
reset role;

do $$
declare v_forged text; v_updated text;
begin
  select account_id::text into v_forged from public.session where id = 'sess-y-forge';
  perform assert_eq('P10 forged INSERT stamped with the token account',
                    '00000000-0000-0000-0000-00000000000a', v_forged);
  select account_id::text into v_updated from public.session where id = 'sess-y1';
  perform assert_eq('P10 forged UPDATE stamped with the token account',
                    '00000000-0000-0000-0000-00000000000a', v_updated);
  raise notice 'P10 PASS';
end;
$$;

-- ===========================================================================
-- P11 — The car cannot null a claimed row back out.
-- ===========================================================================
\echo '=== P11: an UPDATE to NULL is re-stamped, not accepted ==='
set role anon;
do $$
begin
  perform as_car('tok-Y');
  update public.session
     set account_id = null
   where vehicle_id = 'veh-Y' and id = 'sess-y1';
end;
$$;
reset role;

do $$
declare v_acc text;
begin
  select account_id::text into v_acc from public.session where id = 'sess-y1';
  perform assert_eq('P11 row stays claimed after an attempted null-out',
                    '00000000-0000-0000-0000-00000000000a', v_acc);
  raise notice 'P11 PASS';
end;
$$;

-- ===========================================================================
-- P12 — The phone cannot spoof a device token. It runs as `authenticated`, so
--       the device policies (which are `to anon`) never apply; and presenting a
--       token makes the trigger stamp the token's account, which then fails the
--       phone's own `account_id = auth.uid()` WITH CHECK.
-- ===========================================================================
\echo '=== P12: an authenticated caller carrying a car token is refused ==='
set role authenticated;
do $$
begin
  -- Account B presents vehicle Y's token (vehicle Y belongs to account A).
  perform as_phone_with_token('00000000-0000-0000-0000-00000000000b', 'tok-Y');
  perform expect_rls_rejected(
    'P12 account B cannot write veh-Y with a stolen token',
    session_insert_sql('veh-Y', 'sess-p12', '00000000-0000-0000-0000-00000000000b', 1750000500000));

  -- And the same with the unclaimed vehicle's token: the stamp is NULL, which
  -- is not equal to auth.uid() either.
  perform as_phone_with_token('00000000-0000-0000-0000-00000000000b', 'tok-X');
  perform expect_rls_rejected(
    'P12 account B cannot write veh-X with an unclaimed token',
    session_insert_sql('veh-X', 'sess-p12b', '00000000-0000-0000-0000-00000000000b', 1750000500000));
  raise notice 'P12 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P13 — An identity-less `anon` caller reads nothing, anywhere.
-- ===========================================================================
\echo '=== P13: anon with no token reads nothing ==='
set role anon;
do $$
declare v_n integer;
begin
  perform as_nobody();
  select
    (select count(*) from public.session)
  + (select count(*) from public."interval")
  + (select count(*) from public.track)
  + (select count(*) from public.telemetry_events)
  + (select count(*) from public.trip_segments)
  + (select count(*) from public.battery_cycles)
  + (select count(*) from public.battery_cycle_sessions)
  + (select count(*) from public.session_costs)
  + (select count(*) from public.vehicle_devices)
  into v_n;
  perform assert_eq('P13 identity-less anon reads nothing at all', '0', v_n::text);
  raise notice 'P13 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P14 — Second owner. The old owner is revoked and account B claims veh-Y
--       through the real `public.claim_pairing_session` RPC. Only the rows
--       still holding NULL are backfilled: the history written under
--       account A keeps A's id and stays readable by A alone.
-- ===========================================================================
\echo '=== P14: a transfer moves the token, not the old history ==='
do $$
declare
  v_b uuid := '00000000-0000-0000-0000-00000000000b';
  v_code uuid := gen_random_uuid();
  v_res jsonb;
begin
  -- Revoke the old owner and the old credential (what the unpair RPC will do).
  update public.vehicle_ownership
     set revoked_at = now()
   where vehicle_id = 'veh-Y' and revoked_at is null;
  update public.vehicle_devices
     set revoked_at = now()
   where vehicle_id = 'veh-Y' and revoked_at is null;

  -- The new owner claims through the real claim RPC, and gets a
  -- credential of its own. The backfill only ever touches unclaimed rows.
  insert into public.device_pairing_sessions (device_code, user_code, vehicle_id)
  values (v_code, '22222222', 'veh-Y');

  v_res := public.claim_pairing_session(
    v_code, 'veh-Y', v_b,
    public.hash_car_token('tok-Y2'), 'car-token-y2');
  -- Transfer adopts only still-NULL rows: the old owner's history keeps
  -- its id, so the reported count is 0 and the shape carries it.
  perform assert_eq('P14 claim RPC success shape', '{"ok": true, "backfilled": 0}', v_res::text);
end;
$$;

set role anon;
do $$
declare v_acc text;
begin
  perform as_car('tok-Y2');
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-Y', 'sess-y-new', null, 'TRIP', 'CLOSED', 1750000600000, 1, 1750000600000, 1750000600000);
end;
$$;
reset role;

do $$
declare v_new text; v_old integer; v_veh_acc text;
begin
  select account_id::text into v_new from public.session where id = 'sess-y-new';
  perform assert_eq('P14 a post-transfer write belongs to the new owner',
                    '00000000-0000-0000-0000-00000000000b', v_new);
  select count(*) into v_old from public.session
   where vehicle_id = 'veh-Y' and account_id = '00000000-0000-0000-0000-00000000000a';
  perform assert_eq('P14 the old owner keeps its own history', '2', v_old::text);

  select account_id::text into v_veh_acc from public.vehicle where vehicle_id = 'veh-Y';
  perform assert_eq('P14 vehicle singleton row moves to new owner',
                    '00000000-0000-0000-0000-00000000000b', v_veh_acc);
end;
$$;

set role authenticated;
do $$
declare v_n integer;
begin
  -- The old owner still reads exactly its own two rows on veh-Y.
  perform as_phone('00000000-0000-0000-0000-00000000000a');
  select count(*) into v_n from public.session where vehicle_id = 'veh-Y';
  perform assert_eq('P14 old owner reads only its own veh-Y history', '2', v_n::text);
  select count(*) into v_n from public.vehicle where vehicle_id = 'veh-Y';
  perform assert_eq('P14 old owner no longer reads veh-Y singleton', '0', v_n::text);

  -- The new owner reads only the row written since the transfer.
  perform as_phone('00000000-0000-0000-0000-00000000000b');
  select count(*) into v_n from public.session where vehicle_id = 'veh-Y';
  perform assert_eq('P14 new owner reads only post-transfer rows', '1', v_n::text);
  select count(*) into v_n from public.vehicle where vehicle_id = 'veh-Y';
  perform assert_eq('P14 new owner reads veh-Y singleton', '1', v_n::text);
  raise notice 'P14 PASS';
end;
$$;
reset role;

-- The new car token reads its own vehicle singleton row
set role anon;
do $$
declare v_n integer;
begin
  perform as_car('tok-Y2');
  select count(*) into v_n from public.vehicle where vehicle_id = 'veh-Y';
  perform assert_eq('P14 new car token reads veh-Y singleton', '1', v_n::text);
end;
$$;
reset role;

-- The revoked credential is dead on arrival.
set role anon;
do $$
begin
  perform as_car('tok-Y');
  perform expect_rls_rejected(
    'P14 the revoked credential can no longer write',
    session_insert_sql('veh-Y', 'sess-p14', null, 1750000700000));
end;
$$;
reset role;

-- ===========================================================================
-- P15 — Re-claim by the same account is a no-op: the ownership upsert changes
--       nothing, a second credential is added, and the backfill finds no rows.
--       The whole re-claim runs through the real `claim_pairing_session` RPC.
-- ===========================================================================
\echo '=== P15: re-claiming changes nothing ==='
do $$
declare
  v_b uuid := '00000000-0000-0000-0000-00000000000b';
  v_code uuid := gen_random_uuid();
  v_res jsonb;
  v_owners_before integer;
  v_owners_after integer;
  v_devices_before integer;
  v_devices_after integer;
  v_a_rows_before integer;
  v_a_rows_after integer;
  v_backfilled integer;
  v_veh_acc text;
begin
  select count(*) into v_owners_before from public.vehicle_ownership
   where vehicle_id = 'veh-Y' and account_id = v_b;
  -- A's rows on veh-Y must survive the re-claim untouched: a backfill
  -- that lost its IS NULL predicate would steal them for B.
  select count(*) into v_a_rows_before from public.session
   where vehicle_id = 'veh-Y' and account_id = '00000000-0000-0000-0000-00000000000a';
  select count(*) into v_devices_before from public.vehicle_devices
   where vehicle_id = 'veh-Y' and revoked_at is null;

  insert into public.device_pairing_sessions (device_code, user_code, vehicle_id)
  values (v_code, '33333333', 'veh-Y');

  v_res := public.claim_pairing_session(
    v_code, 'veh-Y', v_b,
    public.hash_car_token('tok-Y3'), 'car-token-y3');
  -- Re-claim by the same account finds no NULL rows: backfilled is a
  -- genuine 0, distinguished from an absent count by the key presence.
  perform assert_eq('P15 claim RPC success shape', '{"ok": true, "backfilled": 0}', v_res::text);

  -- The backfill must have found nothing to move: no NULL rows remain now
  -- that the first claim already moved them, and P14's rows all carry B.
  select (select count(*) from public.session where vehicle_id='veh-Y' and account_id is null)
       + (select count(*) from public."interval" where vehicle_id='veh-Y' and account_id is null)
       + (select count(*) from public.track where vehicle_id='veh-Y' and account_id is null)
       + (select count(*) from public.telemetry_events where vehicle_id='veh-Y' and account_id is null)
       + (select count(*) from public.trip_segments where vehicle_id='veh-Y' and account_id is null)
       + (select count(*) from public.battery_cycles where vehicle_id='veh-Y' and account_id is null)
       + (select count(*) from public.battery_cycle_sessions where vehicle_id='veh-Y' and account_id is null)
       + (select count(*) from public.session_costs where vehicle_id='veh-Y' and account_id is null)
    into v_backfilled;

  select count(*) into v_owners_after from public.vehicle_ownership
   where vehicle_id = 'veh-Y' and account_id = v_b;
  select count(*) into v_devices_after from public.vehicle_devices
   where vehicle_id = 'veh-Y' and revoked_at is null;
  select count(*) into v_a_rows_after from public.session
   where vehicle_id = 'veh-Y' and account_id = '00000000-0000-0000-0000-00000000000a';

  select account_id::text into v_veh_acc from public.vehicle where vehicle_id = 'veh-Y';
  perform assert_eq('P15 vehicle singleton row stays with owner B',
                    '00000000-0000-0000-0000-00000000000b', v_veh_acc);

  perform assert_eq('P15 the ownership upsert is a no-op',
                    v_owners_before::text, v_owners_after::text);
  perform assert_eq('P15 the re-claim adds one device credential',
                    (v_devices_before + 1)::text, v_devices_after::text);
  perform assert_eq('P15 the second backfill moves nothing', '0', v_backfilled::text);
  perform assert_eq('P15 the re-claim steals none of A history',
                    v_a_rows_before::text, v_a_rows_after::text);
  raise notice 'P15 PASS';
end;
$$;

-- Both credentials of the same owner resolve to the same account, so a write
-- through either one is stamped identically.
set role anon;
do $$
begin
  perform as_car('tok-Y3');
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-Y', 'sess-y-reclaim', null, 'TRIP', 'CLOSED', 1750000800000, 1, 1750000800000, 1750000800000);
end;
$$;
reset role;
do $$
declare v_acc text;
begin
  select account_id::text into v_acc from public.session where id = 'sess-y-reclaim';
  perform assert_eq('P15 the second credential stamps the same account',
                    '00000000-0000-0000-0000-00000000000b', v_acc);
  raise notice 'P15b PASS';
end;
$$;

-- ===========================================================================
-- P16 — Cross-account isolation on ONE vehicle. Nothing in the codebase yet
--       revokes a `vehicle_devices` row on transfer, so a vehicle can carry
--       two live credentials belonging to different accounts. The vehicle
--       scope alone would let the older one read and rewrite the newer
--       owner's rows; the `using` clauses of the device SELECT and UPDATE
--       policies are what stop it.
-- ===========================================================================
\echo '=== P16: a credential for account A cannot see or move account B rows on the same vehicle ==='
do $$
declare
  v_a uuid := '00000000-0000-0000-0000-00000000000a';
  v_b uuid := '00000000-0000-0000-0000-00000000000b';
begin
  insert into public.vehicle (vehicle_id, account_id, display_name)
  values ('veh-Z', v_b, 'transferred car');
  insert into public.vehicle_ownership (vehicle_id, account_id) values ('veh-Z', v_b);
  -- The seller's credential is deliberately NOT revoked: that is the state a
  -- transfer leaves behind today, and the attack surface under test.
  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values ('veh-Z', v_a, public.hash_car_token('tok-Z-a'));
  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values ('veh-Z', v_b, public.hash_car_token('tok-Z-b'));
  -- And a pre-claim credential that never got an account (P17 uses it).
  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values ('veh-Z', null, public.hash_car_token('tok-Z-null'));

  -- One row on veh-Z, already owned by the buyer B.
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-Z', 'sess-z-b', v_b, 'TRIP', 'CLOSED', 1750001000000, 1, 1750001000000, 1750001000000);
end;
$$;

set role anon;
do $$
declare v_n integer;
begin
  perform as_car('tok-Z-a');

  -- Read: the seller sees nothing of the buyer's history.
  select count(*) into v_n from public.session where vehicle_id = 'veh-Z';
  perform assert_eq('P16 the seller credential reads none of the buyer rows', '0', v_n::text);

  -- Write: the UPDATE matches no row, so it cannot re-stamp one to A.
  update public.session set status = 'OPEN' where vehicle_id = 'veh-Z' and id = 'sess-z-b';
  get diagnostics v_n = row_count;
  perform assert_eq('P16 the seller credential updates none of the buyer rows', '0', v_n::text);

  -- The buyer's own credential still reads and writes its row normally.
  perform as_car('tok-Z-b');
  select count(*) into v_n from public.session where vehicle_id = 'veh-Z';
  perform assert_eq('P16 the buyer credential still reads its own row', '1', v_n::text);
  update public.session set status = 'OPEN' where vehicle_id = 'veh-Z' and id = 'sess-z-b';
  get diagnostics v_n = row_count;
  perform assert_eq('P16 the buyer credential still updates its own row', '1', v_n::text);
end;
$$;
reset role;

do $$
declare v_acc text;
begin
  select account_id::text into v_acc from public.session where id = 'sess-z-b';
  perform assert_eq('P16 the row still belongs to the buyer',
                    '00000000-0000-0000-0000-00000000000b', v_acc);
  raise notice 'P16 PASS';
end;
$$;

-- ===========================================================================
-- P17 — An account-less (pre-claim) credential cannot de-claim a row a claim
--       has already backfilled. This is the car's ORDINARY upload path:
--       `Prefer: resolution=merge-duplicates` is `insert ... on conflict do
--       update`, and the stamp trigger writes NULL for an account-less token.
--       The refusal has to come from the UPDATE `using` clause, because the
--       `with check` sees only the value the trigger just derived.
-- ===========================================================================
\echo '=== P17: an account-less token cannot de-claim a claimed row ==='
set role anon;
do $$
declare v_n integer;
begin
  perform as_car('tok-Z-null');

  -- A plain UPDATE matches no row at all.
  update public.session set account_id = null where vehicle_id = 'veh-Z' and id = 'sess-z-b';
  get diagnostics v_n = row_count;
  perform assert_eq('P17 an account-less UPDATE matches no claimed row', '0', v_n::text);

  -- The upsert path is refused outright rather than silently nulling the row.
  perform expect_rls_rejected(
    'P17 the merge-duplicates upsert cannot de-claim the row',
    'insert into public.session (vehicle_id, id, account_id, kind, status, '
    || 'started_at_utc_millis, started_at_elapsed_nanos, '
    || 'created_at_utc_millis, updated_at_utc_millis) '
    || 'values (''veh-Z'', ''sess-z-b'', null, ''TRIP'', ''OPEN'', 1750001000000, 1, '
    || '1750001000000, 1750001100000) '
    || 'on conflict (vehicle_id, id) do update set status = excluded.status, '
    || 'account_id = excluded.account_id, updated_at_utc_millis = excluded.updated_at_utc_millis');

  -- The same token still uploads a genuinely unclaimed row: NULL matches NULL,
  -- so the Phase 1 pre-claim road is untouched.
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-Z', 'sess-z-pre', null, 'TRIP', 'CLOSED', 1750001200000, 1, 1750001200000, 1750001200000);
  update public.session set status = 'OPEN' where vehicle_id = 'veh-Z' and id = 'sess-z-pre';
  get diagnostics v_n = row_count;
  perform assert_eq('P17 the pre-claim credential still updates its own unclaimed row',
                    '1', v_n::text);
end;
$$;
reset role;

do $$
declare v_acc text; v_status text;
begin
  select account_id::text, status into v_acc, v_status
    from public.session where id = 'sess-z-b';
  perform assert_eq('P17 the claimed row keeps its owner',
                    '00000000-0000-0000-0000-00000000000b', v_acc);
  perform assert_eq('P17 the claimed row keeps its state', 'OPEN', v_status);
  raise notice 'P17 PASS';
end;
$$;
-- ===========================================================================
-- T9 — The cloud corrected re-upload (Option A, plan §5.2): a car-scoped
--      DELETE of exactly the keys the sweeper rewrote, after the corrected
--      row landed. The delete's `using` clause demands the token's vehicle
--      AND account match the row, so:
--        * the owner's credential deletes its own wrong minutes (scoped);
--        * a different account's credential for the SAME vehicle cannot
--          delete the owner's minutes (the two-owners guard);
--        * a pre-claim (account-less) credential cannot delete rows a claim
--          backfilled;
--      The corrected-row insert happens BEFORE the delete in the car's
--      uploader; this harness proves the RLS half — the ordering half is
--      proven by TelemetryCloudUploaderTest (insert first, delete after).
-- ===========================================================================

-- Seed: an interval on veh-Z owned by B, uploaded by B at a wrong stamp,
-- plus B's corrected row that replaced it (the corrected key is exactly
-- what must SURVIVE the delete pass).
do $$
begin
  delete from public."interval" where session_id = 'sess-z-b';
  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis,
    corrected_from_utc_millis
  ) values ('veh-Z', 'sess-z-b', '00000000-0000-0000-0000-00000000000b',
            1750002000000, 60000, 1, 0, 0, 0, 0, 0.1, 60, 60, 60, 60,
            1750002000000, null);
  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis,
    corrected_from_utc_millis
  ) values ('veh-Z', 'sess-z-b', '00000000-0000-0000-0000-00000000000b',
            1750002060000, 60000, 1, 0, 0, 0, 0, 0.1, 60, 60, 60, 60,
            1750002060000, 1750002000000);
end;
$$;

\echo '=== T9: applying interval device deletes migration ==='
\i supabase/migrations/20260912220000_interval_device_deletes.sql

\echo '=== T9: owner deletes its own corrected-from key, corrected row survives ==='
set role anon;
do $$
declare v_n integer;
begin
  perform as_car('tok-Z-b');

  -- The owner's credential deletes the wrong stamp...
  delete from public."interval"
  where vehicle_id = 'veh-Z'
    and session_id = 'sess-z-b'
    and start_utc_millis = 1750002000000;
  get diagnostics v_n = row_count;
  perform assert_eq('T9 the owner deletes the wrong key', '1', v_n::text);

  -- ...and the corrected key survives: no duplicate minute, no orphan.
  select count(*) into v_n from public."interval"
  where vehicle_id = 'veh-Z' and session_id = 'sess-z-b';
  perform assert_eq('T9 exactly one interval remains', '1', v_n::text);
  select count(*) into v_n from public."interval"
  where vehicle_id = 'veh-Z' and session_id = 'sess-z-b'
    and start_utc_millis = 1750002060000
    and corrected_from_utc_millis = 1750002000000;
  perform assert_eq('T9 the corrected row survived with its marker', '1', v_n::text);
end;
$$;
reset role;

\echo '=== T9: a different account for the same vehicle cannot delete its minutes ==='
set role anon;
do $$
declare v_n integer;
begin
  -- Re-seed the wrong row the seller must not be able to remove.
  insert into public."interval" (
    vehicle_id, session_id, account_id, start_utc_millis, width_millis,
    traction_wh, regen_wh, auxiliary_wh, climate_wh, delivered_wh, distance_km,
    covered_seconds, climate_covered_seconds, speed_covered_seconds,
    delivered_covered_seconds, updated_at_utc_millis, corrected_from_utc_millis
  ) values ('veh-Z', 'sess-z-b', '00000000-0000-0000-0000-00000000000b',
            1750002100000, 60000, 1, 0, 0, 0, 0, 0.1, 60, 60, 60, 60,
            1750002100000, null);

  perform as_car('tok-Z-a');
  delete from public."interval"
  where vehicle_id = 'veh-Z'
    and session_id = 'sess-z-b'
    and start_utc_millis = 1750002100000;
  get diagnostics v_n = row_count;
  perform assert_eq('T9 the seller deletes none of the buyer rows', '0', v_n::text);

  raise notice 'T9P2 PASS';
end;
$$;
reset role;

do $$
declare v_n integer;
begin
  -- The seller's scoped read cannot see the buyer's row either; the superuser
  -- check below proves the row survived the refused delete.
  select count(*) into v_n from public."interval"
  where vehicle_id = 'veh-Z' and session_id = 'sess-z-b'
    and start_utc_millis = 1750002100000;
  perform assert_eq('T9 the buyer row is still there after the refusal', '1', v_n::text);
end;
$$;

\echo '=== T9: an account-less token cannot delete rows a claim backfilled ==='
set role anon;
do $$
declare v_n integer;
begin
  perform as_car('tok-Z-null');
  delete from public."interval"
  where vehicle_id = 'veh-Z'
    and session_id = 'sess-z-b'
    and start_utc_millis = 1750002100000;
  get diagnostics v_n = row_count;
  perform assert_eq('T9 the account-less credential deletes no claimed row', '0', v_n::text);
  raise notice 'T9P3 PASS';
end;
$$;
reset role;

do $$
declare v_n integer;
begin
  select count(*) into v_n from public."interval"
  where vehicle_id = 'veh-Z' and session_id = 'sess-z-b'
    and start_utc_millis = 1750002100000;
  perform assert_eq('T9 the claimed row survives the account-less delete',
                    '1', v_n::text);
end;
$$;

do $$
declare v_n integer;
begin
  -- Final state: the corrected row from the first proof plus the wrong row
  -- the refusals kept. No duplicates, no orphan.
  select count(*) into v_n from public."interval" where session_id = 'sess-z-b';
  perform assert_eq('T9 row count exactly', '2', v_n::text);
  raise notice 'T9 PASS';
end;
$$;


-- ===========================================================================
-- P18 — Cross-account preference read isolation on ONE vehicle (gb236 L2).
--       Account A's desired/reported rows on veh-Z must be invisible to
--       account B's credential (tok-Z-b), through the base tables AND through
--       the `preference_control_status` view (`security_invoker` inherits the
--       base-table policies). The view is exactly where an assumption like
--       "the view inherits RLS" goes wrong, so it is asserted, not assumed.
--       This test FAILS if the `account_id` predicate is removed from the two
--       device read policies again: with the old vehicle-only predicate, B
--       would see all three rows below.
-- ===========================================================================
\echo '=== P18: car credential of account B reads none of account A preference rows on the shared vehicle ==='
do $$
begin
  insert into public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
  values ('00000000-0000-0000-0000-00000000000a', 'veh-Z', 'default_charge_cost_per_kwh', '0.87', 1750002000000, 'phone');
  insert into public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
  values ('00000000-0000-0000-0000-00000000000a', 'veh-Z', 'charge_target_soc', '80', 1750002100000, 'phone');
  insert into public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
  values ('veh-Z', '00000000-0000-0000-0000-00000000000a', 'default_charge_cost_per_kwh', '0.87', 'accepted', 1750002200000, 1750002200000);
end;
$$;

set role anon;
do $$
declare v_n integer; v_keys text;
begin
  perform as_car('tok-Z-b');

  -- Base tables: account A's rows must be absent from account B's reads.
  select count(*) into v_n from public.preference_desired where vehicle_id = 'veh-Z';
  perform assert_eq('P18 credential B reads none of A desired rows', '0', v_n::text);
  select count(*) into v_n from public.preference_reported where vehicle_id = 'veh-Z';
  perform assert_eq('P18 credential B reads none of A reported rows', '0', v_n::text);

  -- The join view: security_invoker must inherit the tightened base-table
  -- policies, not the vehicle-only carve-out the base tables used to have.
  select count(*) into v_n from public.preference_control_status where vehicle_id = 'veh-Z';
  perform assert_eq('P18 credential B sees none of A through the status view', '0', v_n::text);
  select coalesce(string_agg(key, ',' order by key), '') into v_keys
    from public.preference_control_status where vehicle_id = 'veh-Z';
  perform assert_eq('P18 no A preference key leaks through the view', '', v_keys);

  raise notice 'P18 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P19 — The same credential still reads its OWN account's rows normally: the
--       car's ordinary control-plane read must keep working after the fix.
--       tok-Z-b reads the desired/reported rows account B wrote for veh-Z,
--       on the base tables and through the view.
-- ===========================================================================
\echo '=== P19: account B credential reads its own preference rows on the shared vehicle ==='
do $$
begin
  insert into public.preference_desired (account_id, vehicle_id, key, value, proposed_at_utc_millis, origin)
  values ('00000000-0000-0000-0000-00000000000b', 'veh-Z', 'charge_target_soc', '90', 1750002300000, 'phone');
  insert into public.preference_reported (vehicle_id, account_id, key, value, status, decided_at_utc_millis, reported_at_utc_millis)
  values ('veh-Z', '00000000-0000-0000-0000-00000000000b', 'charge_target_soc', '90', 'accepted', 1750002400000, 1750002400000);
end;
$$;

set role anon;
do $$
declare v_n integer; v_status text; v_value text;
begin
  perform as_car('tok-Z-b');

  select count(*) into v_n from public.preference_desired where vehicle_id = 'veh-Z';
  perform assert_eq('P19 credential B reads its own desired rows', '1', v_n::text);
  select count(*) into v_n from public.preference_reported where vehicle_id = 'veh-Z';
  perform assert_eq('P19 credential B reads its own reported rows', '1', v_n::text);
  select status, desired_value into v_status, v_value
    from public.preference_control_status where vehicle_id = 'veh-Z' and key = 'charge_target_soc';
  perform assert_eq('P19 view shows B own desire confirmed', 'confirmed', v_status);
  perform assert_eq('P19 view carries B own desired value', '90', v_value);

  raise notice 'P19 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- P20 — Phase 4 cutover readiness: car sets and clears car_direct_upload_active
--       under its own vehicle and account via anon device policies; phone reads.
-- ===========================================================================
\echo '=== P20: car writes/updates car_direct_upload_active and phone reads ==='
set role anon;
do $$
begin
  perform as_car('tok-X');

  -- 1. Car inserts its cutover readiness row with car_direct_upload_active = true
  insert into public.phone_cutover_readiness (
    account_id, vehicle_id, updated_at_utc_millis, car_direct_upload_active
  ) values (
    '00000000-0000-0000-0000-00000000000a', 'veh-X', 1750003000000, true
  );

  -- 2. Car updates car_direct_upload_active to false (e.g. on unpair/revoke)
  update public.phone_cutover_readiness
    set car_direct_upload_active = false, updated_at_utc_millis = 1750003100000
    where vehicle_id = 'veh-X' and account_id = '00000000-0000-0000-0000-00000000000a';

  -- 3. Car cannot insert for another vehicle (veh-Y)
  begin
    insert into public.phone_cutover_readiness (
      account_id, vehicle_id, updated_at_utc_millis, car_direct_upload_active
    ) values (
      '00000000-0000-0000-0000-00000000000a', 'veh-Y', 1750003000000, true
    );
    raise exception 'Expected RLS denial when tok-X writes for veh-Y';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;

-- 4. Phone reads the row
set role authenticated;
do $$
declare v_active boolean;
begin
  perform as_phone('00000000-0000-0000-0000-00000000000a');
  select car_direct_upload_active into v_active
    from public.phone_cutover_readiness where vehicle_id = 'veh-X';
  perform assert_eq('P20 phone reads car_direct_upload_active', 'false', v_active::text);

  -- Account B cannot see veh-X
  perform as_phone('00000000-0000-0000-0000-00000000000b');
  select car_direct_upload_active into v_active
    from public.phone_cutover_readiness where vehicle_id = 'veh-X';
  perform assert_eq('P20 account B cannot read veh-X readiness', null, v_active::text);

  raise notice 'P20 PASS';
end;
$$;
reset role;

\echo '=== All car-direct-upload RLS proofs (P1..P20 + T9) PASSED ==='
