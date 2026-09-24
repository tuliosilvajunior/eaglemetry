-- supabase/tests/device_register_rpc.sql
--
-- Issue #236 Phase 2 Step 1 — proofs for pre-claim registration:
-- `public.register_device_identity(text)` from
-- `supabase/migrations/20260904120000_device_register_rpc.sql`.
--
-- Run (from the repository root, against a scratch database):
--   createdb test_device_register
--   psql -h 127.0.0.1 -d test_device_register -f supabase/tests/device_register_rpc.sql
--
-- The whole schema is applied from `supabase/schema_full.sql`, which the
-- Kotlin schema tests hold in parity with the migrations. The negative cases
-- run under `SET ROLE anon` / `SET ROLE authenticated`, so a refusal is
-- proven by Postgres permissions, not by application logic.

\set ON_ERROR_STOP on

\echo '=== Device register RPC: roles and auth mock ==='

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

-- Run a statement under the current role and demand that Postgres refuse it
-- with a matching error (permission or RLS). `SET ROLE` before calling
-- decides which road the statement takes.
create or replace function expect_denied(label text, p_sql text, p_match text) returns void as $$
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
    raise exception 'ASSERT FAIL %: expected refusal, statement succeeded', label;
  end if;
  if v_msg !~* p_match then
    raise exception 'ASSERT FAIL %: refused, but not as expected (got: %)', label, v_msg;
  end if;
end;
$$ language plpgsql;

create or replace function as_car(p_token text) returns void as $$
begin
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.headers', json_build_object('x-car-token', p_token)::text, false);
end;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- Seed cleanup (as superuser; reruns start clean)
-- ---------------------------------------------------------------------------

\echo '=== Seed cleanup ==='

delete from public.session where vehicle_id like 'veh-R%';
delete from public.vehicle_devices where vehicle_id like 'veh-R%';
delete from public.vehicle where vehicle_id like 'veh-R%';

-- ===========================================================================
-- T0 — The function is locked down: security definer, service_role only.
-- ===========================================================================
\echo '=== T0: definer + grants ==='
do $$
declare v_definer boolean; v_config text;
begin
  select p.prosecdef, p.proconfig::text into v_definer, v_config
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'register_device_identity';
  if not coalesce(v_definer, false) then
    raise exception 'ASSERT FAIL T0: register_device_identity is not security definer';
  end if;
  if v_config is null or v_config !~ 'public, extensions, pg_catalog' then
    raise exception 'ASSERT FAIL T0: unexpected search_path (%)', v_config;
  end if;
  perform assert_eq('T0 anon cannot execute', 'false',
    has_function_privilege('anon', 'public.register_device_identity(text)', 'EXECUTE')::text);
  perform assert_eq('T0 authenticated cannot execute', 'false',
    has_function_privilege('authenticated', 'public.register_device_identity(text)', 'EXECUTE')::text);
  perform assert_eq('T0 service_role can execute', 'true',
    has_function_privilege('service_role', 'public.register_device_identity(text)', 'EXECUTE')::text);
  raise notice 'T0 PASS';
end;
$$;

-- ===========================================================================
-- T1 — Registration creates an unclaimed vehicle and active credential.
set role service_role;
do $$
declare v_tok text;
begin
  select public.register_device_identity('veh-R1') into v_tok;
  perform set_config('app.tok1', v_tok, false);
  if v_tok !~ '^[A-Za-z0-9_-]{43}$' then
    raise exception 'ASSERT FAIL T1: token is not 43-char base64url (%)', v_tok;
  end if;
  raise notice 'T1: token minted';
end;
$$;
reset role;

-- Assert as the table owner (service_role has no select policy on vehicle
-- here; locally it also lacks BYPASSRLS, so the row would be invisible).
do $$
declare v_tok text;
begin
  v_tok := current_setting('app.tok1', true);
  if (select count(*) from public.vehicle where vehicle_id = 'veh-R1' and account_id is null) <> 1 then
    raise exception 'ASSERT FAIL T1: unclaimed vehicle row missing';
  end if;
  if (select count(*) from public.vehicle_devices
       where vehicle_id = 'veh-R1' and account_id is null and revoked_at is null
         and token_hash = public.hash_car_token(v_tok)) <> 1 then
    raise exception 'ASSERT FAIL T1: active unclaimed credential missing';
  end if;
  raise notice 'T1 PASS';
end;
$$;
reset role;

-- ===========================================================================
-- T2 — Second call rotates: previous unclaimed credential is revoked.
-- ===========================================================================
\echo '=== T2: second call rotates the token ==='
set role service_role;
do $$
declare v_tok1 text; v_tok2 text;
begin
  v_tok1 := current_setting('app.tok1', true);
  select public.register_device_identity('veh-R1') into v_tok2;
  perform set_config('app.tok2', v_tok2, false);
  if v_tok2 = v_tok1 then
    raise exception 'ASSERT FAIL T2: token did not rotate';
  end if;
  raise notice 'T2: token rotated';
end;
$$;
reset role;

-- Assert as the table owner (same local service_role visibility gap as T1).
do $$
declare v_tok1 text; v_tok2 text; v_ident jsonb;
begin
  v_tok1 := current_setting('app.tok1', true);
  v_tok2 := current_setting('app.tok2', true);
  if (select count(*) from public.vehicle_devices
       where vehicle_id = 'veh-R1' and account_id is null and revoked_at is null) <> 1 then
    raise exception 'ASSERT FAIL T2: expected exactly one live unclaimed credential';
  end if;
  if (select count(*) from public.vehicle_devices
       where vehicle_id = 'veh-R1' and account_id is null and revoked_at is not null
         and token_hash = public.hash_car_token(v_tok1)) <> 1 then
    raise exception 'ASSERT FAIL T2: previous credential was not revoked';
  end if;
  -- Old token no longer resolves; new one does, with a null account.
  perform set_config('request.headers', json_build_object('x-car-token', v_tok1)::text, false);
  select public.car_device_identity_from_header() into v_ident;
  if v_ident is not null then
    raise exception 'ASSERT FAIL T2: revoked token still resolves (%)', v_ident;
  end if;
  perform set_config('request.headers', json_build_object('x-car-token', v_tok2)::text, false);
  select public.car_device_identity_from_header() into v_ident;
  perform assert_eq('T2 rotated token vehicle_id', 'veh-R1', v_ident->>'vehicle_id');
  if v_ident->>'account_id' is not null then
    raise exception 'ASSERT FAIL T2: rotated token account_id should be null (%)', v_ident;
  end if;
  raise notice 'T2 PASS';
end;
$$;

-- ===========================================================================
-- T3 — Only service_role can execute; anon and authenticated are refused.
-- ===========================================================================
\echo '=== T3: anon and authenticated are refused ==='
set role anon;
do $$
begin
  perform expect_denied('T3 anon refused',
    'select public.register_device_identity(''veh-RX'')', 'permission denied');
  raise notice 'T3a PASS (anon refused)';
end;
$$;
reset role;

set role authenticated;
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000000a')::text, false);
  perform expect_denied('T3 authenticated refused',
    'select public.register_device_identity(''veh-RX'')', 'permission denied');
  raise notice 'T3b PASS (authenticated refused)';
end;
$$;
reset role;

do $$
begin
  if exists (select 1 from public.vehicle where vehicle_id = 'veh-RX') then
    raise exception 'ASSERT FAIL T3: refused call left a vehicle row behind';
  end if;
  raise notice 'T3 PASS';
end;
$$;

-- ===========================================================================
-- T4 — The minted token resolves via car_device_identity_from_header()
--      with account_id null.
-- ===========================================================================
\echo '=== T4: minted token resolves with null account ==='
do $$
declare v_ident jsonb;
begin
  perform set_config('request.headers',
    json_build_object('x-car-token', current_setting('app.tok2', true))::text, false);
  select public.car_device_identity_from_header() into v_ident;
  perform assert_eq('T4 vehicle_id', 'veh-R1', v_ident->>'vehicle_id');
  if v_ident->>'account_id' is not null then
    raise exception 'ASSERT FAIL T4: account_id should be null (%)', v_ident;
  end if;
  raise notice 'T4 PASS';
end;
$$;

-- ===========================================================================
-- T5 — Measurement rows written with this token carry account_id = null,
--      even when the payload forges an account.
-- ===========================================================================
\echo '=== T5: car upload with minted token stores NULL account_id ==='
set role anon;
do $$
begin
  perform as_car(current_setting('app.tok2', true));
  insert into public.session (
    vehicle_id, id, account_id, kind, status,
    started_at_utc_millis, started_at_elapsed_nanos,
    created_at_utc_millis, updated_at_utc_millis
  ) values ('veh-R1', 'sess-r1', '00000000-0000-0000-0000-00000000000a',
            'TRIP', 'CLOSED', 1750000000000, 1, 1750000000000, 1750000000000);
  raise notice 'T5: car write accepted';
end;
$$;
reset role;

do $$
declare v_n integer;
begin
  select count(*) into v_n from public.session
   where vehicle_id = 'veh-R1' and id = 'sess-r1' and account_id is null;
  perform assert_eq('T5 forged account_id stamped to NULL', '1', v_n::text);
  raise notice 'T5 PASS (stamp)';
end;
$$;

-- The car can read its own unclaimed row back (NULL matches NULL).
set role anon;
do $$
declare v_read integer;
begin
  perform as_car(current_setting('app.tok2', true));
  select count(*) into v_read from public.session where vehicle_id = 'veh-R1' and id = 'sess-r1';
  perform assert_eq('T5 car reads its unclaimed row', '1', v_read::text);
  raise notice 'T5 PASS (read-back)';
end;
$$;
reset role;

\echo '=== All device-register-rpc tests PASSED ==='
