-- ===========================================================================
-- Capy Energy - Full Consolidated Supabase Schema
-- ===========================================================================
-- This file contains the complete, idempotent database setup.
-- You can run this file directly in the Supabase SQL Editor on a fresh database
-- or on an existing one to ensure all tables, cascades, functions, and RLS
-- policies are correctly configured.
-- ===========================================================================

-- 1. EXTENSIONS & SCHEMAS
create extension if not exists pgcrypto;
create schema if not exists partitions;
revoke all on schema partitions from public;
grant usage on schema partitions to authenticated, service_role;

-- 2. VEHICLE & ENTITLEMENTS
create table if not exists public.vehicle (
  vehicle_id text primary key,
  account_id uuid references auth.users (id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);
create index if not exists vehicle_account_idx on public.vehicle (account_id);

create table if not exists public.entitlement (
  account_id uuid primary key references auth.users (id) on delete cascade,
  tier text not null default 'free',
  valid_until timestamptz,
  updated_at timestamptz not null default now()
);

-- 3. MEASUREMENT TABLES
create table if not exists public.session (
  vehicle_id text not null references public.vehicle (vehicle_id) on delete cascade,
  id text not null,
  account_id uuid,
  kind text not null,
  status text not null,
  started_at_utc_millis bigint not null,
  started_at_elapsed_nanos bigint not null,
  started_at_boot_count bigint,
  ended_at_utc_millis bigint,
  ended_at_elapsed_nanos bigint,
  ended_at_boot_count bigint,
  movement_started_at_utc_millis bigint,
  movement_started_at_elapsed_nanos bigint,
  movement_started_at_boot_count bigint,
  charge_started_at_utc_millis bigint,
  charge_started_at_elapsed_nanos bigint,
  charge_started_at_boot_count bigint,
  charge_ended_at_utc_millis bigint,
  charge_ended_at_elapsed_nanos bigint,
  charge_ended_at_boot_count bigint,
  plug_disconnected_at_utc_millis bigint,
  plug_disconnected_at_elapsed_nanos bigint,
  plug_disconnected_at_boot_count bigint,
  rollup_distance_km double precision,
  rollup_traction_wh double precision,
  rollup_regen_wh double precision,
  rollup_auxiliary_wh double precision,
  rollup_climate_wh double precision,
  rollup_delivered_wh double precision,
  rollup_integrated_seconds double precision,
  start_odometer_km double precision,
  end_odometer_km double precision,
  plug_type bigint,
  start_ambient_temp_c double precision,
  end_ambient_temp_c double precision,
  mean_ambient_temp_c double precision,
  start_soc_percent double precision,
  end_soc_percent double precision,
  min_soc_percent double precision,
  max_soc_percent double precision,
  soc_agrees_with_integral text,
  no_longer_reducible boolean not null default false,
  start_power_kw double precision,
  start_latitude double precision,
  start_longitude double precision,
  start_altitude_m double precision,
  start_gps_accuracy_m double precision,
  start_location_provider text,
  start_location_elapsed_realtime_nanos bigint,
  cost_per_kwh double precision,
  paid_amount double precision,
  cost_currency text,
  charge_end_reason text,
  end_reason text,
  start_gear bigint,
  last_soc double precision,
  sleep_seconds bigint,
  sleep_soc_delta_percent double precision,
  sleep_energy_wh_estimate double precision,
  parking_mode bigint,
  -- Summed once from the Track at close, so null while the session is open.
  climb_m double precision,
  descent_m double precision,
  fix_count bigint,
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  updated_at_elapsed_nanos bigint,
  uploaded_at timestamptz not null default now(),
  primary key (vehicle_id, id)
);

create index if not exists session_account_started_idx
  on public.session (account_id, started_at_utc_millis desc);
create index if not exists session_kind_started_idx
  on public.session (vehicle_id, kind, started_at_utc_millis desc);

create table if not exists public."interval" (
  vehicle_id text not null,
  session_id text not null,
  account_id uuid,
  start_utc_millis bigint not null,
  width_millis bigint not null,
  traction_wh double precision not null,
  regen_wh double precision not null,
  auxiliary_wh double precision not null,
  climate_wh double precision not null,
  delivered_wh double precision not null,
  distance_km double precision not null,
  covered_seconds double precision not null,
  climate_covered_seconds double precision not null,
  speed_covered_seconds double precision not null,
  delivered_covered_seconds double precision not null,
  -- Null for a minute the pack did not report. The charge curves are drawn
  -- from the minutes that do.
  start_soc double precision,
  end_soc double precision,
  start_voltage double precision,
  end_voltage double precision,
  updated_at_utc_millis bigint not null,
  -- Time authority (T1): the monotonic reading behind the stamp. Nullable
  -- because rows uploaded before the car wrote the pair cannot be recovered.
  start_elapsed_nanos bigint default null,
  start_boot_count bigint default null,
  -- What the time authority believes about the stamp; 'unknown' until the
  -- detector and sweeper say otherwise.
  time_state text not null default 'unknown',
  -- The stamp this row carried before the sweeper corrected it; null means
  -- never corrected.
  corrected_from_utc_millis bigint default null,
  primary key (vehicle_id, session_id, start_utc_millis),
  foreign key (vehicle_id, session_id)
    references public.session (vehicle_id, id) on delete cascade
);

create index if not exists interval_account_start_idx
  on public."interval" (account_id, start_utc_millis);

create table if not exists public.telemetry_events (
  vehicle_id text not null,
  session_id text,
  account_id uuid,
  type text not null,
  occurred_at_utc_millis bigint not null,
  signal_id text not null default '',
  occurred_at_elapsed_nanos bigint not null,
  source_timestamp_nanos bigint,
  timestamp_accuracy text not null,
  uncertainty_millis bigint not null,
  value text,
  previous_value text,
  quality text,
  source text,
  details text not null,
  primary key (vehicle_id, occurred_at_utc_millis, occurred_at_elapsed_nanos, type, signal_id)
);

create index if not exists telemetry_events_account_idx
  on public.telemetry_events (account_id, occurred_at_utc_millis desc);
create index if not exists telemetry_events_session_idx
  on public.telemetry_events (vehicle_id, session_id, occurred_at_utc_millis);

-- Named to match 20260820150000_slice6_detail_cascade.sql, so a database built
-- from this file and one built from the migrations carry the same constraint.
do $$ begin
  alter table public.telemetry_events
    add constraint telemetry_events_vehicle_fk
    foreign key (vehicle_id) references public.vehicle (vehicle_id) on delete cascade;
exception when duplicate_object then null;
end $$;

create table if not exists public.trip_segments (
  vehicle_id text not null,
  session_id text not null,
  ordinal bigint not null,
  account_id uuid,
  start_utc_millis bigint not null,
  end_utc_millis bigint not null,
  distance_km double precision not null,
  pack_wh double precision,
  traction_wh double precision,
  regenerated_wh double precision,
  auxiliary_wh double precision,
  integrated_seconds double precision not null,
  elapsed_seconds double precision not null,
  mean_speed_kmh double precision,
  altitude_gain_m double precision,
  altitude_loss_m double precision,
  ambient_temp_c double precision,
  start_latitude double precision,
  start_longitude double precision,
  end_latitude double precision,
  end_longitude double precision,
  path text not null,
  primary key (vehicle_id, session_id, ordinal),
  foreign key (vehicle_id, session_id)
    references public.session (vehicle_id, id) on delete cascade
);

create index if not exists trip_segments_account_idx
  on public.trip_segments (account_id, start_utc_millis);

-- The route as it is drawn now: one row per session. `trip_segments` above is
-- the route as it was drawn before, and no build still uploads to it.
create table if not exists public.track (
  vehicle_id text not null,
  session_id text not null,
  account_id uuid,
  encoding_version bigint not null,
  point_count bigint not null,
  t text not null,
  path text not null,
  speed text not null,
  alt text not null,
  updated_at_utc_millis bigint not null,
  uploaded_at timestamptz not null default now(),
  primary key (vehicle_id, session_id),
  foreign key (vehicle_id, session_id)
    references public.session (vehicle_id, id) on delete cascade
);

create index if not exists track_account_updated_idx
  on public.track (account_id, updated_at_utc_millis desc);

create table if not exists public.battery_cycles (
  vehicle_id text not null references public.vehicle (vehicle_id) on delete cascade,
  ordinal bigint not null,
  account_id uuid,
  start_utc_millis bigint not null,
  end_utc_millis bigint not null,
  discharge_percent double precision not null,
  distance_km double precision not null,
  trip_energy_kwh double precision not null,
  parked_energy_kwh double precision not null,
  parked_soc_percent double precision not null,
  cost double precision,
  cost_currency text,
  priced_energy_kwh double precision not null,
  unpriced_energy_kwh double precision not null,
  is_open boolean not null default false,
  is_partial boolean not null default false,
  energy_incomplete boolean not null default false,
  mixed_currency boolean not null default false,
  opening_priced_fraction double precision not null,
  opening_blended_price double precision not null,
  frozen_at_utc_millis bigint,
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  primary key (vehicle_id, start_utc_millis)
);

create index if not exists battery_cycles_account_idx
  on public.battery_cycles (account_id, start_utc_millis);

create table if not exists public.battery_cycle_sessions (
  vehicle_id text not null,
  cycle_ordinal bigint not null,
  session_kind text not null,
  session_id text not null,
  account_id uuid,
  share double precision not null,
  start_utc_millis bigint not null,
  end_utc_millis bigint not null,
  cycle_start_utc_millis bigint not null,
  primary key (vehicle_id, cycle_ordinal, session_kind, session_id),
  constraint battery_cycle_sessions_cycle_fkey
    foreign key (vehicle_id, cycle_start_utc_millis)
    references public.battery_cycles (vehicle_id, start_utc_millis)
    on delete cascade
);

-- 4. ANNOTATION TABLES
create table if not exists public.insight_places (
  id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
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
  -- HLC per field group (additive, Phase 2 Step 1). See migration
  -- 20260902120000_annotation_hlc_stamps.sql for grouping rationale.
  -- 20260902140000 adds auto_name group per ADR 0009 (car>phone>cloud).
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

create table if not exists public.session_costs (
  vehicle_id text not null,
  session_id text not null,
  account_id uuid,
  cost_per_kwh double precision,
  paid_amount double precision,
  cost_currency text,
  updated_at_utc_millis bigint not null,
  origin text not null,
  -- HLC per field group (cost fields share one clock — see migration
  -- 20260902120000_annotation_hlc_stamps.sql). Cost is atomic.
  cost_hlc_millis bigint not null default 0,
  cost_hlc_counter integer not null default 0,
  cost_hlc_device_id text not null default '',
  primary key (vehicle_id, session_id),
  foreign key (vehicle_id, session_id)
    references public.session (vehicle_id, id) on delete cascade
);

create table if not exists public.preferences (
  account_id uuid not null references auth.users (id) on delete cascade,
  scope text not null,
  key text not null,
  value text,
  updated_at_utc_millis bigint not null,
  origin text not null,
  deleted_at_utc_millis bigint,
  -- Row-level HLC (row == field for key/value table). See migration
  -- 20260902120000_annotation_hlc_stamps.sql.
  hlc_millis bigint not null default 0,
  hlc_counter integer not null default 0,
  hlc_device_id text not null default '',
  primary key (account_id, scope, key)
);

create table if not exists public.preference_proposals (
  id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  key text not null,
  value text,
  status text not null,
  proposed_at_utc_millis bigint not null,
  decided_at_utc_millis bigint,
  updated_at_utc_millis bigint not null,
  origin text not null,
  primary key (account_id, id)
);

create table if not exists public.journeys (
  id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  started_at_utc_millis bigint not null,
  ended_at_utc_millis bigint not null,
  note text,
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  origin text not null,
  deleted_at_utc_millis bigint,
  -- HLC per field group (additive, Phase 2 Step 1). See migration
  -- 20260902120000_annotation_hlc_stamps.sql for grouping rationale.
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

-- 4b. DEVICE PAIRING & VEHICLE OWNERSHIP (Phase 2 — OAuth 2.0 Device Flow)

create table if not exists public.device_pairing_sessions (
  device_code uuid primary key default gen_random_uuid(),
  user_code varchar(8) not null,
  vehicle_id text not null,
  status text not null check (status in ('pending', 'approved', 'rejected', 'expired')) default 'pending',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '5 minutes'),
  approved_by uuid references auth.users (id) on delete set null,
  car_token text
);

create index if not exists device_pairing_sessions_user_code_idx
  on public.device_pairing_sessions (user_code);
create index if not exists device_pairing_sessions_status_expires_idx
  on public.device_pairing_sessions (status, expires_at);

create table if not exists public.vehicle_ownership (
  id uuid primary key default gen_random_uuid(),
  vehicle_id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (vehicle_id, account_id)
);

create index if not exists vehicle_ownership_account_vehicle_idx
  on public.vehicle_ownership (account_id, vehicle_id);

create unique index if not exists vehicle_ownership_single_active_owner_idx
  on public.vehicle_ownership (vehicle_id) where revoked_at is null;

create table if not exists public.vehicle_devices (
  device_id uuid primary key default gen_random_uuid(),
  vehicle_id text not null,
  account_id uuid references auth.users (id) on delete cascade,
  token_hash text not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index if not exists vehicle_devices_vehicle_token_idx
  on public.vehicle_devices (vehicle_id, token_hash);

create table if not exists public.pairing_claim_attempts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index if not exists pairing_claim_attempts_account_time_idx
  on public.pairing_claim_attempts (account_id, attempted_at);

create table if not exists public.device_registration_attempts (
  id uuid primary key default gen_random_uuid(),
  vehicle_id text not null,
  ip text,
  attempted_at timestamptz not null default now()
);

create index if not exists device_registration_attempts_vehicle_time_idx
  on public.device_registration_attempts (vehicle_id, attempted_at);

create index if not exists device_registration_attempts_ip_time_idx
  on public.device_registration_attempts (ip, attempted_at);

-- 4c. LANE C — CONTROL TABLES (Phase 3 — preference_control_lane_c)
--
-- The phone writes what it *wants* (`preference_desired`), the car writes
-- what it *does* (`preference_reported`), and `preference_control_status`
-- joins the two. This lane must never auto-merge (issue #227). Full
-- rationale in `supabase/migrations/20260902150000_preference_control_lane_c.sql`.
--
-- The view runs `security_invoker = true` so RLS on the underlying tables
-- applies per querying role: the car (`anon`, device token) sees only its own
-- vehicle's rows, the phone (`authenticated`) only its own account's rows.

create table if not exists public.preference_desired (
  account_id uuid not null references auth.users (id) on delete cascade,
  vehicle_id text not null,
  key text not null,
  value text,
  proposed_at_utc_millis bigint not null,
  origin text not null,
  primary key (account_id, vehicle_id, key)
);

create index if not exists preference_desired_vehicle_key_idx
  on public.preference_desired (vehicle_id, key);

create table if not exists public.preference_reported (
  vehicle_id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  key text not null,
  value text,
  status text not null check (status in ('accepted', 'refused')),
  decided_at_utc_millis bigint not null,
  reported_at_utc_millis bigint not null,
  primary key (vehicle_id, key, decided_at_utc_millis)
);

create index if not exists preference_reported_account_vehicle_key_idx
  on public.preference_reported (account_id, vehicle_id, key, reported_at_utc_millis desc);

drop view if exists public.preference_control_status;
create view public.preference_control_status
with (security_invoker = true)
as
with desired_latest as (
  select distinct on (vehicle_id, key)
    vehicle_id,
    account_id,
    key,
    value,
    proposed_at_utc_millis
  from public.preference_desired
  order by vehicle_id, key, proposed_at_utc_millis desc
),
reported_latest as (
  select distinct on (vehicle_id, key)
    vehicle_id,
    account_id,
    key,
    value,
    status,
    decided_at_utc_millis,
    reported_at_utc_millis
  from public.preference_reported
  order by vehicle_id, key, reported_at_utc_millis desc, decided_at_utc_millis desc
)
select
  coalesce(d.vehicle_id, r.vehicle_id) as vehicle_id,
  coalesce(d.account_id, r.account_id) as account_id,
  coalesce(d.key, r.key) as key,
  d.value as desired_value,
  d.proposed_at_utc_millis,
  r.value as reported_value,
  r.status as reported_status,
  r.decided_at_utc_millis,
  r.reported_at_utc_millis,
  case
    when d.key is null then 'reported_only'
    when r.key is null then 'pending'
    when d.proposed_at_utc_millis > r.decided_at_utc_millis then 'stale'
    when r.status = 'accepted' and r.value is not distinct from d.value then 'confirmed'
    else 'refused'
  end as status
from desired_latest d
full outer join reported_latest r
  on d.vehicle_id = r.vehicle_id and d.key = r.key;

-- 4d. CAR DEVICE-TOKEN IDENTITY (Phase 3 Step 1a)
--
-- The car has no Supabase Auth session. To let Postgres tell "the car wrote
-- this" from "the phone wrote this", the car presents a raw token in the
-- `x-car-token` request header and these SECURITY DEFINER helpers resolve it
-- to its vehicle/account. Every anon (car) policy in this file — including
-- the Lane C ones above — is scoped by `car_device_identity_from_header()`.
-- Defined here, before the RLS policy sections, so the policies can call it.
-- Full rationale: `supabase/migrations/20260901130000_car_device_token_identity.sql`.

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
grant execute on function public.hash_car_token(text) to anon, authenticated, service_role;
grant execute on function public.car_device_identity_from_header() to anon, authenticated, service_role;

-- 4e. PHONE CUTOVER READINESS (Phase 4 — 20260902170000)
--
-- The phone writes its own outbox depth and migration state here; the car
-- reads them to decide whether it may retire the local channel. Writer model:
-- phone only, one row per (account_id, vehicle_id).
create table if not exists public.phone_cutover_readiness (
  account_id uuid not null references auth.users (id) on delete cascade,
  vehicle_id text not null,
  phone_outbox_count integer not null default 0 check (phone_outbox_count >= 0),
  migration_completed boolean not null default false,
  updated_at_utc_millis bigint not null,
  car_direct_upload_active boolean not null default false,
  primary key (account_id, vehicle_id)
);

create index if not exists phone_cutover_readiness_vehicle_idx
  on public.phone_cutover_readiness (vehicle_id);

-- 4f. NULLABLE account_id + SERVER-SIDE STAMP (issue #236 Phase 1 —
--     20260903120000_car_direct_upload_schema.sql)
--
-- The car uploads before any account claims the vehicle, so `account_id` is
-- nullable everywhere it denormalizes ownership. The `create table` blocks
-- above already declare it that way; these `alter` statements carry an
-- existing database across.
alter table public.vehicle
  alter column account_id drop not null;
alter table public.vehicle_devices
  alter column account_id drop not null;
alter table public.session
  alter column account_id drop not null;
alter table public."interval"
  alter column account_id drop not null;
alter table public.track
  alter column account_id drop not null;
alter table public.telemetry_events
  alter column account_id drop not null;
alter table public.trip_segments
  alter column account_id drop not null;
alter table public.battery_cycles
  alter column account_id drop not null;
alter table public.battery_cycle_sessions
  alter column account_id drop not null;

-- The column is write-only-from-the-server: whatever the payload says, the
-- stored value is derived from the request identity. Without this a car could
-- UPDATE a claimed row's account_id back to NULL and de-claim its history.
--
-- SECURITY INVOKER on purpose: a SECURITY DEFINER body reports the definer in
-- `current_user`, so the "leave privileged writers alone" branch would match
-- on every request and the stamp would never run.
create or replace function public.stamp_measurement_account_id()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ident jsonb;
begin
  -- Privileged writers manage the column themselves; never clobber them. The
  -- claim RPC (SECURITY DEFINER, owned by the migration definer) runs here,
  -- which is what lets the Phase 3 backfill write the account_id it chooses.
  if current_setting('is_superuser', true) = 'on'
     or current_user in ('postgres', 'supabase_admin', 'service_role') then
    return new;
  end if;

  v_ident := public.car_device_identity_from_header();
  if v_ident is not null then
    -- A device write: the account the token maps to right now — NULL before
    -- the claim, the claimer's id after it. The vehicle check lives in the
    -- RLS policy; this sets the stamp and nothing else.
    new.account_id := nullif(v_ident ->> 'account_id', '')::uuid;
  elsif auth.uid() is not null then
    -- An account write (the phone).
    new.account_id := auth.uid();
  end if;
  -- Neither identity: the payload's value survives here, and the row is then
  -- refused by RLS, which has no policy that matches an identity-less caller.
  return new;
end;
$$;

revoke all on function public.stamp_measurement_account_id() from public;
grant execute on function public.stamp_measurement_account_id()
  to anon, authenticated, service_role;

do $$
declare t text;
begin
  foreach t in array array[
    'session', 'interval', 'track', 'telemetry_events',
    'trip_segments', 'battery_cycles', 'battery_cycle_sessions',
    'session_costs'
  ]
  loop
    execute format(
      'drop trigger if exists measurement_account_stamp on public.%I; ' ||
      'create trigger measurement_account_stamp before insert or update ' ||
      'on public.%I for each row execute function ' ||
      'public.stamp_measurement_account_id()',
      t, t
    );
  end loop;
end;
$$;

-- 5. ENABLE ROW LEVEL SECURITY
alter table public.vehicle enable row level security;
alter table public.session enable row level security;
alter table public."interval" enable row level security;
alter table public.telemetry_events enable row level security;
alter table public.trip_segments enable row level security;
alter table public.track enable row level security;
alter table public.battery_cycles enable row level security;
alter table public.battery_cycle_sessions enable row level security;
alter table public.insight_places enable row level security;
alter table public.session_costs enable row level security;
alter table public.preferences enable row level security;
alter table public.preference_proposals enable row level security;
alter table public.journeys enable row level security;
alter table public.preference_desired enable row level security;
alter table public.preference_reported enable row level security;
alter table public.device_pairing_sessions enable row level security;
alter table public.vehicle_ownership enable row level security;
alter table public.vehicle_devices enable row level security;
alter table public.pairing_claim_attempts enable row level security;
alter table public.device_registration_attempts enable row level security;
alter table public.phone_cutover_readiness enable row level security;
alter table public.entitlement enable row level security;

-- 6. RE-APPLY RLS POLICIES
drop policy if exists vehicle_owner_reads on public.vehicle;
create policy vehicle_owner_reads on public.vehicle
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists vehicle_owner_claims on public.vehicle;
create policy vehicle_owner_claims on public.vehicle
  for insert to authenticated
  with check (account_id = (select auth.uid()));

drop policy if exists vehicle_owner_renames on public.vehicle;
create policy vehicle_owner_renames on public.vehicle
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists session_owner_reads on public.session;
create policy session_owner_reads on public.session
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists session_owner_uploads on public.session;
create policy session_owner_uploads on public.session
  for insert to authenticated
  with check (account_id = (select auth.uid()));

drop policy if exists session_owner_completes on public.session;
create policy session_owner_completes on public.session
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists interval_owner_reads on public."interval";
create policy interval_owner_reads on public."interval"
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists interval_owner_uploads on public."interval";
create policy interval_owner_uploads on public."interval"
  for insert to authenticated
  with check (account_id = (select auth.uid()));

drop policy if exists interval_owner_completes on public."interval";
create policy interval_owner_completes on public."interval"
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists battery_cycles_owner_reads on public.battery_cycles;
create policy battery_cycles_owner_reads on public.battery_cycles
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists battery_cycles_owner_uploads on public.battery_cycles;
create policy battery_cycles_owner_uploads on public.battery_cycles
  for insert to authenticated
  with check (account_id = (select auth.uid()));

drop policy if exists battery_cycles_owner_completes on public.battery_cycles;
create policy battery_cycles_owner_completes on public.battery_cycles
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists battery_cycle_sessions_owner_reads on public.battery_cycle_sessions;
create policy battery_cycle_sessions_owner_reads on public.battery_cycle_sessions
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists battery_cycle_sessions_owner_uploads on public.battery_cycle_sessions;
create policy battery_cycle_sessions_owner_uploads on public.battery_cycle_sessions
  for insert to authenticated
  with check (account_id = (select auth.uid()));

drop policy if exists battery_cycle_sessions_owner_completes on public.battery_cycle_sessions;
create policy battery_cycle_sessions_owner_completes on public.battery_cycle_sessions
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists telemetry_events_owner_reads_window on public.telemetry_events;
drop policy if exists telemetry_events_owner_reads on public.telemetry_events;
create policy telemetry_events_owner_reads on public.telemetry_events
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists telemetry_events_owner_uploads on public.telemetry_events;
create policy telemetry_events_owner_uploads on public.telemetry_events
  for insert to authenticated
  with check (account_id = (select auth.uid()));

drop policy if exists trip_segments_owner_reads_window on public.trip_segments;
drop policy if exists trip_segments_owner_reads on public.trip_segments;
create policy trip_segments_owner_reads on public.trip_segments
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists trip_segments_owner_uploads on public.trip_segments;
create policy trip_segments_owner_uploads on public.trip_segments
  for insert to authenticated
  with check (account_id = (select auth.uid()));

drop policy if exists track_owner_reads on public.track;
create policy track_owner_reads on public.track
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists track_owner_uploads on public.track;
create policy track_owner_uploads on public.track
  for insert to authenticated
  with check (account_id = (select auth.uid()));

-- The route grows while the session is open and settles at close, so the
-- second write of the same session is an UPDATE of the row already there.
drop policy if exists track_owner_completes on public.track;
create policy track_owner_completes on public.track
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists insight_places_owner_all on public.insight_places;
create policy insight_places_owner_all on public.insight_places
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists session_costs_owner_all on public.session_costs;
create policy session_costs_owner_all on public.session_costs
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists preferences_owner_all on public.preferences;
create policy preferences_owner_all on public.preferences
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists preference_proposals_owner_all on public.preference_proposals;
create policy preference_proposals_owner_all on public.preference_proposals
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- Lane C (issue #227): the phone owns `preference_desired`, the car owns
-- `preference_reported`. Neither side writes the other's table; a car request
-- runs as `anon` resolved via the device-token identity function.

drop policy if exists preference_desired_owner_reads on public.preference_desired;
create policy preference_desired_owner_reads on public.preference_desired
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists preference_desired_device_reads on public.preference_desired;
create policy preference_desired_device_reads on public.preference_desired
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists preference_desired_owner_writes on public.preference_desired;
create policy preference_desired_owner_writes on public.preference_desired
  for insert to authenticated
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = preference_desired.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

drop policy if exists preference_desired_owner_updates on public.preference_desired;
create policy preference_desired_owner_updates on public.preference_desired
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = preference_desired.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

drop policy if exists preference_reported_device_writes on public.preference_reported;
create policy preference_reported_device_writes on public.preference_reported
  for insert to anon
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists preference_reported_device_updates on public.preference_reported;
create policy preference_reported_device_updates on public.preference_reported
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  )
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists preference_reported_device_reads on public.preference_reported;
create policy preference_reported_device_reads on public.preference_reported
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists preference_reported_owner_reads on public.preference_reported;
create policy preference_reported_owner_reads on public.preference_reported
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists journeys_owner_all on public.journeys;
create policy journeys_owner_all on public.journeys
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists device_pairing_sessions_owner_reads on public.device_pairing_sessions;
create policy device_pairing_sessions_owner_reads on public.device_pairing_sessions
  for select to authenticated
  using (approved_by = (select auth.uid()));

drop policy if exists vehicle_ownership_owner_reads on public.vehicle_ownership;
create policy vehicle_ownership_owner_reads on public.vehicle_ownership
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists vehicle_ownership_owner_inserts on public.vehicle_ownership;
-- Removed: inserts only via Edge Function service_role/RPC (H3.3)

drop policy if exists vehicle_ownership_owner_updates on public.vehicle_ownership;
create policy vehicle_ownership_owner_updates on public.vehicle_ownership
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

drop policy if exists vehicle_devices_owner_reads on public.vehicle_devices;
create policy vehicle_devices_owner_reads on public.vehicle_devices
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists vehicle_devices_owner_inserts on public.vehicle_devices;
-- Removed: inserts only via Edge Function service_role/RPC (H3.3)

drop policy if exists vehicle_devices_owner_updates on public.vehicle_devices;
create policy vehicle_devices_owner_updates on public.vehicle_devices
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- The car reads its own device row via its token (self-check after boot or
-- a revoke). Scoped by the device-token identity function; without a valid
-- token anon sees nothing. The account bound keeps a second credential on a
-- shared vehicle from reading another account's device rows (token hashes,
-- account ids).
drop policy if exists vehicle_devices_device_reads on public.vehicle_devices;
create policy vehicle_devices_device_reads on public.vehicle_devices
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

-- 6b. PHONE CUTOVER READINESS (20260902170000)
drop policy if exists phone_cutover_readiness_owner_reads on public.phone_cutover_readiness;
create policy phone_cutover_readiness_owner_reads on public.phone_cutover_readiness
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists phone_cutover_readiness_owner_writes on public.phone_cutover_readiness;
create policy phone_cutover_readiness_owner_writes on public.phone_cutover_readiness
  for insert to authenticated
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = phone_cutover_readiness.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

drop policy if exists phone_cutover_readiness_owner_updates on public.phone_cutover_readiness;
create policy phone_cutover_readiness_owner_updates on public.phone_cutover_readiness
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = phone_cutover_readiness.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

drop policy if exists phone_cutover_readiness_device_reads on public.phone_cutover_readiness;
create policy phone_cutover_readiness_device_reads on public.phone_cutover_readiness
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists phone_cutover_readiness_device_writes on public.phone_cutover_readiness;
create policy phone_cutover_readiness_device_writes on public.phone_cutover_readiness
  for insert to anon
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists phone_cutover_readiness_device_updates on public.phone_cutover_readiness;
create policy phone_cutover_readiness_device_updates on public.phone_cutover_readiness
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  )
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

-- 6c. CAR DIRECT UPLOAD — anon device policies (issue #236 Phase 1)
--
-- The car runs as `anon` with an `x-car-token` header and is scoped to the one
-- vehicle that token resolves to, and — on the clauses that see a row already
-- in the table (SELECT, and the `using` half of UPDATE) — to the account the
-- token belongs to. `is not distinct from` so an unclaimed row's NULL matches
-- an account-less token's NULL, which is what keeps the pre-claim upload path
-- working. `account_id` stays deliberately absent from every `with check`:
-- the stamp trigger in section 4f owns writes to that column and has already
-- run when the check is evaluated. The trigger stops the payload from forging
-- the value; these `using` clauses are what stop an existing row from moving
-- to another account's visibility.
--
-- These names are issue 227's names on purpose. 227 gave the car the same
-- policies but also demanded `account_id = <the device's account_id>`, which
-- an unclaimed car cannot satisfy. Reusing the names replaces those policies
-- instead of adding a second permissive one per verb, which Postgres would OR
-- together and the looser rule would win unseen.

drop policy if exists session_device_reads on public.session;
create policy session_device_reads on public.session
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists session_device_writes on public.session;
create policy session_device_writes on public.session
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists session_device_updates on public.session;
create policy session_device_updates on public.session
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists interval_device_reads on public."interval";
create policy interval_device_reads on public."interval"
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists interval_device_writes on public."interval";
create policy interval_device_writes on public."interval"
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists interval_device_updates on public."interval";
create policy interval_device_updates on public."interval"
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

-- T9: the corrected re-upload deletes EXACTLY the keys the car rewrote. A
-- delete sees a row already in the table, so it carries the same using
-- clauses as select/update: the token's vehicle AND the token's account must
-- match the row. A vehicle-scoped delete from another account (or from a
-- pre-claim credential after a claim backfilled) is refused — the same guard
-- that keeps UPDATE from moving rows is what keeps DELETE from removing
-- someone else's minutes.
drop policy if exists interval_device_deletes on public."interval";
create policy interval_device_deletes on public."interval"
  for delete to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists track_device_reads on public.track;
create policy track_device_reads on public.track
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists track_device_writes on public.track;
create policy track_device_writes on public.track
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists track_device_updates on public.track;
create policy track_device_updates on public.track
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists telemetry_events_device_reads on public.telemetry_events;
create policy telemetry_events_device_reads on public.telemetry_events
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists telemetry_events_device_writes on public.telemetry_events;
create policy telemetry_events_device_writes on public.telemetry_events
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists trip_segments_device_reads on public.trip_segments;
create policy trip_segments_device_reads on public.trip_segments
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists trip_segments_device_writes on public.trip_segments;
create policy trip_segments_device_writes on public.trip_segments
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists battery_cycles_device_reads on public.battery_cycles;
create policy battery_cycles_device_reads on public.battery_cycles
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists battery_cycles_device_writes on public.battery_cycles;
create policy battery_cycles_device_writes on public.battery_cycles
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists battery_cycles_device_updates on public.battery_cycles;
create policy battery_cycles_device_updates on public.battery_cycles
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists battery_cycle_sessions_device_reads on public.battery_cycle_sessions;
create policy battery_cycle_sessions_device_reads on public.battery_cycle_sessions
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists battery_cycle_sessions_device_writes on public.battery_cycle_sessions;
create policy battery_cycle_sessions_device_writes on public.battery_cycle_sessions
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists battery_cycle_sessions_device_updates on public.battery_cycle_sessions;
create policy battery_cycle_sessions_device_updates on public.battery_cycle_sessions
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

-- 6d. CAR DEVICE — anon policies on the annotation and ownership tables
--     (issue #227 — 20260902190000_car_device_telemetry_rls.sql)
--
-- These stay account-scoped on purpose. Issue #236 widens only the
-- measurement tables (section 6c), because only a measurement can exist
-- before a claim. An annotation is authored by an account, so a device with
-- no account_id reaches none of these rows — the `= ... ::uuid` comparison is
-- NULL, and NULL is not true.

-- insight_places
drop policy if exists insight_places_device_writes on public.insight_places;
create policy insight_places_device_writes on public.insight_places
  for insert to anon
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists insight_places_device_updates on public.insight_places;
create policy insight_places_device_updates on public.insight_places
  for update to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid)
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists insight_places_device_deletes on public.insight_places;
create policy insight_places_device_deletes on public.insight_places
  for delete to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists insight_places_device_reads on public.insight_places;
create policy insight_places_device_reads on public.insight_places
  for select to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid);

-- journeys
drop policy if exists journeys_device_writes on public.journeys;
create policy journeys_device_writes on public.journeys
  for insert to anon
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists journeys_device_updates on public.journeys;
create policy journeys_device_updates on public.journeys
  for update to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid)
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists journeys_device_deletes on public.journeys;
create policy journeys_device_deletes on public.journeys
  for delete to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists journeys_device_reads on public.journeys;
create policy journeys_device_reads on public.journeys
  for select to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid);

-- session_costs
drop policy if exists session_costs_device_reads on public.session_costs;
create policy session_costs_device_reads on public.session_costs
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists session_costs_device_writes on public.session_costs;
create policy session_costs_device_writes on public.session_costs
  for insert to anon
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists session_costs_device_updates on public.session_costs;
create policy session_costs_device_updates on public.session_costs
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

drop policy if exists session_costs_device_deletes on public.session_costs;
create policy session_costs_device_deletes on public.session_costs
  for delete to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

-- preferences
drop policy if exists preferences_device_writes on public.preferences;
create policy preferences_device_writes on public.preferences
  for insert to anon
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists preferences_device_updates on public.preferences;
create policy preferences_device_updates on public.preferences
  for update to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid)
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists preferences_device_deletes on public.preferences;
create policy preferences_device_deletes on public.preferences
  for delete to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists preferences_device_reads on public.preferences;
create policy preferences_device_reads on public.preferences
  for select to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid);

-- preference_proposals (legacy, kept for completeness)
drop policy if exists preference_proposals_device_writes on public.preference_proposals;
create policy preference_proposals_device_writes on public.preference_proposals
  for insert to anon
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists preference_proposals_device_updates on public.preference_proposals;
create policy preference_proposals_device_updates on public.preference_proposals
  for update to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid)
  with check (account_id = (car_device_identity_from_header()->>'account_id')::uuid);
drop policy if exists preference_proposals_device_reads on public.preference_proposals;
create policy preference_proposals_device_reads on public.preference_proposals
  for select to anon
  using (account_id = (car_device_identity_from_header()->>'account_id')::uuid);

-- vehicle + ownership: the car reads its own rows, bound to the account its
-- token resolves to, so a second credential on a shared vehicle does not see
-- another account's ownership/display metadata.
drop policy if exists vehicle_ownership_device_reads on public.vehicle_ownership;
create policy vehicle_ownership_device_reads on public.vehicle_ownership
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists vehicle_device_reads on public.vehicle;
create policy vehicle_device_reads on public.vehicle
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

-- 7. PERMISSIONS & GRANTS
grant usage on schema public to authenticated, anon, service_role;

grant select, insert, update on
  public.vehicle,
  public.session,
  public."interval",
  public.track,
  public.battery_cycles,
  public.battery_cycle_sessions
  to authenticated, service_role;
-- The car (anon, x-car-token) writes the same measurement tables; sections 6c
-- and 6d are what narrow it to its own vehicle. Standing rule: a refusal comes
-- from RLS, never from a missing grant.
grant select, insert, update, delete on
  public.vehicle,
  public.session,
  public."interval",
  public.track,
  public.battery_cycles,
  public.battery_cycle_sessions
  to anon;

grant select, insert on
  public.telemetry_events,
  public.trip_segments
  to authenticated, service_role;
grant select, insert on
  public.telemetry_events,
  public.trip_segments
  to anon;

grant select, insert, update, delete on
  public.insight_places,
  public.session_costs,
  public.preferences,
  public.preference_proposals,
  public.journeys
  to authenticated, service_role;
grant select, insert, update, delete on
  public.insight_places,
  public.session_costs,
  public.preferences,
  public.preference_proposals,
  public.journeys
  to anon;

-- Lane C control tables: INSERT/UPDATE are granted to both roles so the
-- negative cases fail on RLS (no matching policy), not on a missing grant.
grant select, insert, update on public.preference_desired to authenticated;
grant select, insert, update on public.preference_desired to anon;
grant select, insert, update on public.preference_reported to authenticated;
grant select, insert, update on public.preference_reported to anon;
grant select, insert, update on public.preference_desired to service_role;
grant select, insert, update on public.preference_reported to service_role;
grant select on public.preference_control_status to anon, authenticated, service_role;

grant select on public.device_pairing_sessions to authenticated;
grant select, update on public.vehicle_ownership to authenticated;
grant select, update on public.vehicle_devices to authenticated;
grant select on public.vehicle_devices to anon;
grant select, insert, update on public.vehicle_ownership to service_role;
grant select, insert, update on public.vehicle_devices to service_role;
grant all on public.device_pairing_sessions to service_role;
grant all on public.pairing_claim_attempts to service_role;
grant all on public.device_registration_attempts to service_role;

grant select, insert, update on public.phone_cutover_readiness to authenticated;
grant select, insert, update on public.phone_cutover_readiness to anon;
grant select, insert, update on public.phone_cutover_readiness to service_role;

revoke insert on public.vehicle_ownership from authenticated;
revoke insert on public.vehicle_devices from authenticated;

-- 8. ATOMIC CLAIM + ONE-TIME TOKEN HELPERS (H1/H3)
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

  -- Ensure vehicle singleton exists
  insert into public.vehicle (vehicle_id, account_id)
  values (p_vehicle_id, p_account_id)
  on conflict (vehicle_id) do nothing;

  -- Create device credential
  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values (p_vehicle_id, p_account_id, p_token_hash);

  -- Backfill history: only still-unclaimed rows move to the claimant.
  -- ROW_COUNT after each UPDATE is exactly the rows this claim adopted.
  update public.vehicle set account_id = p_account_id
   where vehicle_id = p_vehicle_id and account_id is null;
  get diagnostics v_backfilled = row_count;

  -- On transfer, the vehicle singleton row moves to the active claimant.
  -- This does not increment v_backfilled because it was not an unclaimed row.
  update public.vehicle set account_id = p_account_id
   where vehicle_id = p_vehicle_id;
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
  update public.session_costs set account_id = p_account_id
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

create or replace function public.consume_pairing_token(p_device_code uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_token text;
begin
  select car_token into v_token from public.device_pairing_sessions where device_code = p_device_code for update;
  if v_token is not null then
    update public.device_pairing_sessions set car_token = null where device_code = p_device_code;
  end if;
  return v_token;
end;
$$;
revoke all on function public.consume_pairing_token(uuid) from public, anon, authenticated;
grant execute on function public.consume_pairing_token(uuid) to service_role;

create or replace function public.cleanup_expired_pairing_tokens()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  update public.device_pairing_sessions
     set car_token = null
   where car_token is not null
     and expires_at < now() - interval '1 day';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.cleanup_expired_pairing_tokens() from public, anon, authenticated;
grant execute on function public.cleanup_expired_pairing_tokens() to service_role;

create or replace function public.cleanup_old_claim_attempts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  delete from public.pairing_claim_attempts where attempted_at < now() - interval '1 hour';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.cleanup_old_claim_attempts() from public, anon, authenticated;
grant execute on function public.cleanup_old_claim_attempts() to service_role;

create or replace function public.cleanup_old_registration_attempts()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.device_registration_attempts where attempted_at < now() - interval '1 hour';
$$;
revoke all on function public.cleanup_old_registration_attempts() from public, anon, authenticated;
grant execute on function public.cleanup_old_registration_attempts() to service_role;

-- 8a. UNCLAIMED TELEMETRY CLEANUP (issue #236 Phase 5 Wave 5.1 —
--     20260913000100_unclaimed_telemetry_cleanup.sql)
-- Drafted and disabled pending decision D2 (gb236-unclaimed-lifecycle).
-- Purges orphan telemetry rows (account_id IS NULL) older than retention window.
create or replace function public.cleanup_unclaimed_telemetry(
  p_retention_days integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cutoff_timestamp timestamptz;
  v_cutoff_millis bigint;
  v_intervals_deleted integer := 0;
  v_tracks_deleted integer := 0;
  v_events_deleted integer := 0;
  v_segments_deleted integer := 0;
  v_cycles_deleted integer := 0;
  v_costs_deleted integer := 0;
  v_sessions_deleted integer := 0;
  v_devices_deleted integer := 0;
  v_pairing_sessions_deleted integer := 0;
  v_reg_attempts_deleted integer := 0;
begin
  if p_retention_days < 1 then
    raise exception 'Retention days must be at least 1 day';
  end if;

  v_cutoff_timestamp := now() - (p_retention_days || ' days')::interval;
  v_cutoff_millis := (extract(epoch from v_cutoff_timestamp) * 1000)::bigint;

  -- 1. Dependent measurement tables
  delete from public."interval"
   where account_id is null
     and start_utc_millis < v_cutoff_millis;
  get diagnostics v_intervals_deleted = row_count;

  delete from public.track
   where account_id is null
     and updated_at_utc_millis < v_cutoff_millis;
  get diagnostics v_tracks_deleted = row_count;

  delete from public.telemetry_events
   where account_id is null
     and occurred_at_utc_millis < v_cutoff_millis;
  get diagnostics v_events_deleted = row_count;

  delete from public.trip_segments
   where account_id is null
     and start_utc_millis < v_cutoff_millis;
  get diagnostics v_segments_deleted = row_count;

  delete from public.battery_cycles
   where account_id is null
     and start_utc_millis < v_cutoff_millis;
  get diagnostics v_cycles_deleted = row_count;

  delete from public.session_costs
   where account_id is null
     and updated_at_utc_millis < v_cutoff_millis;
  get diagnostics v_costs_deleted = row_count;

  -- 2. Sessions
  delete from public.session
   where account_id is null
     and started_at_utc_millis < v_cutoff_millis;
  get diagnostics v_sessions_deleted = row_count;

  -- 3. Stale unclaimed vehicle devices
  delete from public.vehicle_devices
   where account_id is null
     and created_at < v_cutoff_timestamp;
  get diagnostics v_devices_deleted = row_count;

  -- 4. Expired and terminal pairing sessions
  delete from public.device_pairing_sessions
   where (status in ('approved', 'rejected', 'expired') or expires_at < v_cutoff_timestamp)
     and created_at < v_cutoff_timestamp;
  get diagnostics v_pairing_sessions_deleted = row_count;

  -- 5. Old registration attempts (fixed 7-day retention)
  delete from public.device_registration_attempts
   where attempted_at < now() - interval '7 days';
  get diagnostics v_reg_attempts_deleted = row_count;

  return jsonb_build_object(
    'retention_days', p_retention_days,
    'cutoff_timestamp', v_cutoff_timestamp,
    'intervals_deleted', v_intervals_deleted,
    'tracks_deleted', v_tracks_deleted,
    'events_deleted', v_events_deleted,
    'segments_deleted', v_segments_deleted,
    'cycles_deleted', v_cycles_deleted,
    'costs_deleted', v_costs_deleted,
    'sessions_deleted', v_sessions_deleted,
    'devices_deleted', v_devices_deleted,
    'pairing_sessions_deleted', v_pairing_sessions_deleted,
    'registration_attempts_deleted', v_reg_attempts_deleted
  );
end;
$$;
revoke all on function public.cleanup_unclaimed_telemetry(integer) from public, anon, authenticated;
grant execute on function public.cleanup_unclaimed_telemetry(integer) to service_role;


-- 8b. PRE-CLAIM DEVICE REGISTRATION (issue #236 Phase 2 Step 1 —
--     20260904120000_device_register_rpc.sql)
--
-- Before any account claims the vehicle, the car registers itself and gets
-- an account-less (`account_id = null`) credential. A second call rotates:
-- the previous unclaimed credential is revoked, so only one pre-claim
-- token is ever live. Executable by `service_role` only (registration Edge
-- Function); the car only presents the minted token in `x-car-token`.
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

  update public.vehicle_devices
     set revoked_at = now()
   where vehicle_id = p_vehicle_id
     and account_id is null
     and revoked_at is null;

  insert into public.vehicle (vehicle_id, account_id)
  values (p_vehicle_id, null)
  on conflict (vehicle_id) do nothing;

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

-- 9. ANNOTATION LWW MERGE TRIGGER (Phase 2 Lane B Step 2 + fixes 20260902140000)
-- Per-field last-write-wins with HLC ordering. See migrations
-- 20260902130000_annotation_merge_trigger.sql and 20260902140000_annotation_tiebreak_and_autoname_fix.sql for rationale.

-- ---------------------------------------------------------------------------
-- 1. Helpers: deterministic HLC ordering
-- ---------------------------------------------------------------------------

-- Device-id-only ordering (H-1 fix): millis -> counter -> device_id.
-- Origin params are kept for call-site compatibility but ignored. Identical
-- triple returns true (idempotent replay).
create or replace function public.annotation_hlc_greater(
  p_in_millis bigint,
  p_in_counter integer,
  p_in_device_id text,
  p_in_origin text,
  p_ex_millis bigint,
  p_ex_counter integer,
  p_ex_device_id text,
  p_ex_origin text
) returns boolean
language plpgsql
immutable
as $$
begin
  if p_in_millis is distinct from p_ex_millis then
    return p_in_millis > p_ex_millis;
  end if;
  if p_in_counter is distinct from p_ex_counter then
    return p_in_counter > p_ex_counter;
  end if;
  if p_in_device_id is distinct from p_ex_device_id then
    return p_in_device_id > p_ex_device_id;
  end if;
  return true;
end;
$$;

-- Origin-rank ordering for auto_name (ADR 0009): millis -> counter -> origin rank (car=2, phone=1, else 0) -> device_id.
-- Used ONLY for the auto_name field group per M-3; all other groups use annotation_hlc_greater.
create or replace function public.annotation_hlc_greater_with_origin_rank(
  p_in_millis bigint,
  p_in_counter integer,
  p_in_device_id text,
  p_in_origin text,
  p_ex_millis bigint,
  p_ex_counter integer,
  p_ex_device_id text,
  p_ex_origin text
) returns boolean
language plpgsql
immutable
as $$
declare
  v_in_rank integer;
  v_ex_rank integer;
begin
  if p_in_millis is distinct from p_ex_millis then
    return p_in_millis > p_ex_millis;
  end if;
  if p_in_counter is distinct from p_ex_counter then
    return p_in_counter > p_ex_counter;
  end if;
  v_in_rank := case p_in_origin when 'car' then 2 when 'phone' then 1 else 0 end;
  v_ex_rank := case p_ex_origin when 'car' then 2 when 'phone' then 1 else 0 end;
  if v_in_rank is distinct from v_ex_rank then
    return v_in_rank > v_ex_rank;
  end if;
  if p_in_device_id is distinct from p_ex_device_id then
    return p_in_device_id > p_ex_device_id;
  end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. insight_places: 3 groups — name, geofence, auto_name (ADR 0009), plus tombstone
-- ---------------------------------------------------------------------------

create or replace function public.insight_places_hlc_merge()
returns trigger
language plpgsql
as $$
declare
  v_name_wins boolean;
  v_geofence_wins boolean;
  v_auto_name_wins boolean;
  v_any_field_wins boolean;
  v_max_old_millis bigint;
  v_max_old_counter integer;
  v_max_old_device_id text;
  v_max_old_origin text;
  v_tomb_millis bigint;
  v_tomb_device_id text;
  v_tomb_origin text;
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  -- Per-group LWW: name, geofence use device_id-only; auto_name uses origin rank per ADR 0009.
  v_name_wins := public.annotation_hlc_greater(
    new.name_hlc_millis, new.name_hlc_counter, new.name_hlc_device_id, new.origin,
    old.name_hlc_millis, old.name_hlc_counter, old.name_hlc_device_id, old.origin
  );
  if not v_name_wins then
    new.name := old.name;
    new.name_hlc_millis := old.name_hlc_millis;
    new.name_hlc_counter := old.name_hlc_counter;
    new.name_hlc_device_id := old.name_hlc_device_id;
  end if;

  v_geofence_wins := public.annotation_hlc_greater(
    new.geofence_hlc_millis, new.geofence_hlc_counter, new.geofence_hlc_device_id, new.origin,
    old.geofence_hlc_millis, old.geofence_hlc_counter, old.geofence_hlc_device_id, old.origin
  );
  if not v_geofence_wins then
    new.latitude := old.latitude;
    new.longitude := old.longitude;
    new.radius_m := old.radius_m;
    new.geofence_hlc_millis := old.geofence_hlc_millis;
    new.geofence_hlc_counter := old.geofence_hlc_counter;
    new.geofence_hlc_device_id := old.geofence_hlc_device_id;
  end if;

  v_auto_name_wins := public.annotation_hlc_greater_with_origin_rank(
    new.auto_name_hlc_millis, new.auto_name_hlc_counter, new.auto_name_hlc_device_id, new.origin,
    old.auto_name_hlc_millis, old.auto_name_hlc_counter, old.auto_name_hlc_device_id, old.origin
  );
  if not v_auto_name_wins then
    new.auto_name := old.auto_name;
    new.auto_name_updated_at_utc_millis := old.auto_name_updated_at_utc_millis;
    new.auto_name_source := old.auto_name_source;
    new.auto_name_hlc_millis := old.auto_name_hlc_millis;
    new.auto_name_hlc_counter := old.auto_name_hlc_counter;
    new.auto_name_hlc_device_id := old.auto_name_hlc_device_id;
  end if;

  v_any_field_wins := v_name_wins or v_geofence_wins or v_auto_name_wins;

  -- Tombstone vs max field clock
  if old.deleted_at_utc_millis is null and new.deleted_at_utc_millis is not null then
    -- Delete attempt: compare delete clock (wall+origin) vs max OLD field HLC.
    -- Max is computed via device_id-only ordering across all groups for uniformity
    -- (tombstone clock itself is device_id-only after H-1). Auto_name's per-group
    -- acceptance already honored origin rank; max aggregation is about recency.
    if public.annotation_hlc_greater(
      old.name_hlc_millis, old.name_hlc_counter, old.name_hlc_device_id, old.origin,
      old.geofence_hlc_millis, old.geofence_hlc_counter, old.geofence_hlc_device_id, old.origin
    ) then
      v_max_old_millis := old.name_hlc_millis;
      v_max_old_counter := old.name_hlc_counter;
      v_max_old_device_id := old.name_hlc_device_id;
      v_max_old_origin := old.origin;
    else
      v_max_old_millis := old.geofence_hlc_millis;
      v_max_old_counter := old.geofence_hlc_counter;
      v_max_old_device_id := old.geofence_hlc_device_id;
      v_max_old_origin := old.origin;
    end if;
    -- Compare max with auto_name
    if public.annotation_hlc_greater(
      old.auto_name_hlc_millis, old.auto_name_hlc_counter, old.auto_name_hlc_device_id, old.origin,
      v_max_old_millis, v_max_old_counter, v_max_old_device_id, v_max_old_origin
    ) then
      v_max_old_millis := old.auto_name_hlc_millis;
      v_max_old_counter := old.auto_name_hlc_counter;
      v_max_old_device_id := old.auto_name_hlc_device_id;
      -- v_max_old_origin stays row-level origin
    end if;

    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin, ''), new.origin,
      v_max_old_millis, v_max_old_counter, v_max_old_device_id, v_max_old_origin
    ) then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;

  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is null then
    -- Resurrection via field edit: each winning field must also beat tombstone.
    v_tomb_millis := old.updated_at_utc_millis;
    v_tomb_device_id := coalesce(old.origin, '');
    v_tomb_origin := old.origin;

    if v_name_wins then
      if not public.annotation_hlc_greater(
        new.name_hlc_millis, new.name_hlc_counter, new.name_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.name := old.name;
        new.name_hlc_millis := old.name_hlc_millis;
        new.name_hlc_counter := old.name_hlc_counter;
        new.name_hlc_device_id := old.name_hlc_device_id;
        v_name_wins := false;
      end if;
    end if;

    if v_geofence_wins then
      if not public.annotation_hlc_greater(
        new.geofence_hlc_millis, new.geofence_hlc_counter, new.geofence_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.latitude := old.latitude;
        new.longitude := old.longitude;
        new.radius_m := old.radius_m;
        new.geofence_hlc_millis := old.geofence_hlc_millis;
        new.geofence_hlc_counter := old.geofence_hlc_counter;
        new.geofence_hlc_device_id := old.geofence_hlc_device_id;
        v_geofence_wins := false;
      end if;
    end if;

    if v_auto_name_wins then
      if not public.annotation_hlc_greater_with_origin_rank(
        new.auto_name_hlc_millis, new.auto_name_hlc_counter, new.auto_name_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.auto_name := old.auto_name;
        new.auto_name_updated_at_utc_millis := old.auto_name_updated_at_utc_millis;
        new.auto_name_source := old.auto_name_source;
        new.auto_name_hlc_millis := old.auto_name_hlc_millis;
        new.auto_name_hlc_counter := old.auto_name_hlc_counter;
        new.auto_name_hlc_device_id := old.auto_name_hlc_device_id;
        v_auto_name_wins := false;
      end if;
    end if;

    v_any_field_wins := v_name_wins or v_geofence_wins or v_auto_name_wins;

    if not v_any_field_wins then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;

  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is not null then
    -- Both deleted: keep newer tombstone clock, but also gate field values against tombstone (M-2 fix).
    v_tomb_millis := old.updated_at_utc_millis;
    v_tomb_device_id := coalesce(old.origin, '');
    v_tomb_origin := old.origin;

    if v_name_wins then
      if not public.annotation_hlc_greater(
        new.name_hlc_millis, new.name_hlc_counter, new.name_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.name := old.name;
        new.name_hlc_millis := old.name_hlc_millis;
        new.name_hlc_counter := old.name_hlc_counter;
        new.name_hlc_device_id := old.name_hlc_device_id;
        v_name_wins := false;
      end if;
    end if;

    if v_geofence_wins then
      if not public.annotation_hlc_greater(
        new.geofence_hlc_millis, new.geofence_hlc_counter, new.geofence_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.latitude := old.latitude;
        new.longitude := old.longitude;
        new.radius_m := old.radius_m;
        new.geofence_hlc_millis := old.geofence_hlc_millis;
        new.geofence_hlc_counter := old.geofence_hlc_counter;
        new.geofence_hlc_device_id := old.geofence_hlc_device_id;
        v_geofence_wins := false;
      end if;
    end if;

    if v_auto_name_wins then
      if not public.annotation_hlc_greater_with_origin_rank(
        new.auto_name_hlc_millis, new.auto_name_hlc_counter, new.auto_name_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.auto_name := old.auto_name;
        new.auto_name_updated_at_utc_millis := old.auto_name_updated_at_utc_millis;
        new.auto_name_source := old.auto_name_source;
        new.auto_name_hlc_millis := old.auto_name_hlc_millis;
        new.auto_name_hlc_counter := old.auto_name_hlc_counter;
        new.auto_name_hlc_device_id := old.auto_name_hlc_device_id;
        v_auto_name_wins := false;
      end if;
    end if;

    v_any_field_wins := v_name_wins or v_geofence_wins or v_auto_name_wins;

    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin, ''), new.origin,
      old.updated_at_utc_millis, 0, coalesce(old.origin, ''), old.origin
    ) then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;
  end if;

  -- Suppress metadata churn when nothing won and tombstone unchanged.
  if not v_any_field_wins and old.deleted_at_utc_millis is not distinct from new.deleted_at_utc_millis then
    new.updated_at_utc_millis := old.updated_at_utc_millis;
    new.origin := old.origin;
  end if;

  return new;
end;
$$;

drop trigger if exists insight_places_hlc_merge_trigger on public.insight_places;
create trigger insight_places_hlc_merge_trigger
before insert or update on public.insight_places
for each row execute function public.insight_places_hlc_merge();

-- ---------------------------------------------------------------------------
-- 3. session_costs: 1 group — cost, no tombstone (H-1 only)
-- ---------------------------------------------------------------------------

create or replace function public.session_costs_hlc_merge()
returns trigger
language plpgsql
as $$
declare
  v_cost_wins boolean;
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  v_cost_wins := public.annotation_hlc_greater(
    new.cost_hlc_millis, new.cost_hlc_counter, new.cost_hlc_device_id, new.origin,
    old.cost_hlc_millis, old.cost_hlc_counter, old.cost_hlc_device_id, old.origin
  );
  if not v_cost_wins then
    new.cost_per_kwh := old.cost_per_kwh;
    new.paid_amount := old.paid_amount;
    new.cost_currency := old.cost_currency;
    new.cost_hlc_millis := old.cost_hlc_millis;
    new.cost_hlc_counter := old.cost_hlc_counter;
    new.cost_hlc_device_id := old.cost_hlc_device_id;
    new.updated_at_utc_millis := old.updated_at_utc_millis;
    new.origin := old.origin;
  end if;

  return new;
end;
$$;

drop trigger if exists session_costs_hlc_merge_trigger on public.session_costs;
create trigger session_costs_hlc_merge_trigger
before insert or update on public.session_costs
for each row execute function public.session_costs_hlc_merge();

-- ---------------------------------------------------------------------------
-- 4. journeys: 3 groups — name, note, time_range, plus tombstone (H-1 + M-2)
-- ---------------------------------------------------------------------------

create or replace function public.journeys_hlc_merge()
returns trigger
language plpgsql
as $$
declare
  v_name_wins boolean;
  v_note_wins boolean;
  v_time_wins boolean;
  v_any_field_wins boolean;
  v_max_old_millis bigint;
  v_max_old_counter integer;
  v_max_old_device_id text;
  v_max_old_origin text;
  v_tomb_millis bigint;
  v_tomb_device_id text;
  v_tomb_origin text;
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  v_name_wins := public.annotation_hlc_greater(
    new.name_hlc_millis, new.name_hlc_counter, new.name_hlc_device_id, new.origin,
    old.name_hlc_millis, old.name_hlc_counter, old.name_hlc_device_id, old.origin
  );
  if not v_name_wins then
    new.name := old.name;
    new.name_hlc_millis := old.name_hlc_millis;
    new.name_hlc_counter := old.name_hlc_counter;
    new.name_hlc_device_id := old.name_hlc_device_id;
  end if;

  v_note_wins := public.annotation_hlc_greater(
    new.note_hlc_millis, new.note_hlc_counter, new.note_hlc_device_id, new.origin,
    old.note_hlc_millis, old.note_hlc_counter, old.note_hlc_device_id, old.origin
  );
  if not v_note_wins then
    new.note := old.note;
    new.note_hlc_millis := old.note_hlc_millis;
    new.note_hlc_counter := old.note_hlc_counter;
    new.note_hlc_device_id := old.note_hlc_device_id;
  end if;

  v_time_wins := public.annotation_hlc_greater(
    new.time_range_hlc_millis, new.time_range_hlc_counter, new.time_range_hlc_device_id, new.origin,
    old.time_range_hlc_millis, old.time_range_hlc_counter, old.time_range_hlc_device_id, old.origin
  );
  if not v_time_wins then
    new.started_at_utc_millis := old.started_at_utc_millis;
    new.ended_at_utc_millis := old.ended_at_utc_millis;
    new.time_range_hlc_millis := old.time_range_hlc_millis;
    new.time_range_hlc_counter := old.time_range_hlc_counter;
    new.time_range_hlc_device_id := old.time_range_hlc_device_id;
  end if;

  v_any_field_wins := v_name_wins or v_note_wins or v_time_wins;

  -- Tombstone vs max field clock
  if old.deleted_at_utc_millis is null and new.deleted_at_utc_millis is not null then
    -- Find max OLD field HLC among 3 groups.
    v_max_old_millis := old.name_hlc_millis;
    v_max_old_counter := old.name_hlc_counter;
    v_max_old_device_id := old.name_hlc_device_id;
    v_max_old_origin := old.origin;

    if public.annotation_hlc_greater(
      old.note_hlc_millis, old.note_hlc_counter, old.note_hlc_device_id, old.origin,
      v_max_old_millis, v_max_old_counter, v_max_old_device_id, v_max_old_origin
    ) then
      v_max_old_millis := old.note_hlc_millis;
      v_max_old_counter := old.note_hlc_counter;
      v_max_old_device_id := old.note_hlc_device_id;
    end if;

    if public.annotation_hlc_greater(
      old.time_range_hlc_millis, old.time_range_hlc_counter, old.time_range_hlc_device_id, old.origin,
      v_max_old_millis, v_max_old_counter, v_max_old_device_id, v_max_old_origin
    ) then
      v_max_old_millis := old.time_range_hlc_millis;
      v_max_old_counter := old.time_range_hlc_counter;
      v_max_old_device_id := old.time_range_hlc_device_id;
    end if;

    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin, ''), new.origin,
      v_max_old_millis, v_max_old_counter, v_max_old_device_id, v_max_old_origin
    ) then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;

  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is null then
    v_tomb_millis := old.updated_at_utc_millis;
    v_tomb_device_id := coalesce(old.origin, '');
    v_tomb_origin := old.origin;

    if v_name_wins then
      if not public.annotation_hlc_greater(
        new.name_hlc_millis, new.name_hlc_counter, new.name_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.name := old.name;
        new.name_hlc_millis := old.name_hlc_millis;
        new.name_hlc_counter := old.name_hlc_counter;
        new.name_hlc_device_id := old.name_hlc_device_id;
        v_name_wins := false;
      end if;
    end if;

    if v_note_wins then
      if not public.annotation_hlc_greater(
        new.note_hlc_millis, new.note_hlc_counter, new.note_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.note := old.note;
        new.note_hlc_millis := old.note_hlc_millis;
        new.note_hlc_counter := old.note_hlc_counter;
        new.note_hlc_device_id := old.note_hlc_device_id;
        v_note_wins := false;
      end if;
    end if;

    if v_time_wins then
      if not public.annotation_hlc_greater(
        new.time_range_hlc_millis, new.time_range_hlc_counter, new.time_range_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.started_at_utc_millis := old.started_at_utc_millis;
        new.ended_at_utc_millis := old.ended_at_utc_millis;
        new.time_range_hlc_millis := old.time_range_hlc_millis;
        new.time_range_hlc_counter := old.time_range_hlc_counter;
        new.time_range_hlc_device_id := old.time_range_hlc_device_id;
        v_time_wins := false;
      end if;
    end if;

    v_any_field_wins := v_name_wins or v_note_wins or v_time_wins;

    if not v_any_field_wins then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;

  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is not null then
    -- Both deleted: gate field values against tombstone (M-2 fix) then tombstone clock.
    v_tomb_millis := old.updated_at_utc_millis;
    v_tomb_device_id := coalesce(old.origin, '');
    v_tomb_origin := old.origin;

    if v_name_wins then
      if not public.annotation_hlc_greater(
        new.name_hlc_millis, new.name_hlc_counter, new.name_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.name := old.name;
        new.name_hlc_millis := old.name_hlc_millis;
        new.name_hlc_counter := old.name_hlc_counter;
        new.name_hlc_device_id := old.name_hlc_device_id;
        v_name_wins := false;
      end if;
    end if;

    if v_note_wins then
      if not public.annotation_hlc_greater(
        new.note_hlc_millis, new.note_hlc_counter, new.note_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.note := old.note;
        new.note_hlc_millis := old.note_hlc_millis;
        new.note_hlc_counter := old.note_hlc_counter;
        new.note_hlc_device_id := old.note_hlc_device_id;
        v_note_wins := false;
      end if;
    end if;

    if v_time_wins then
      if not public.annotation_hlc_greater(
        new.time_range_hlc_millis, new.time_range_hlc_counter, new.time_range_hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.started_at_utc_millis := old.started_at_utc_millis;
        new.ended_at_utc_millis := old.ended_at_utc_millis;
        new.time_range_hlc_millis := old.time_range_hlc_millis;
        new.time_range_hlc_counter := old.time_range_hlc_counter;
        new.time_range_hlc_device_id := old.time_range_hlc_device_id;
        v_time_wins := false;
      end if;
    end if;

    v_any_field_wins := v_name_wins or v_note_wins or v_time_wins;

    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin, ''), new.origin,
      old.updated_at_utc_millis, 0, coalesce(old.origin, ''), old.origin
    ) then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;
  end if;

  if not v_any_field_wins and old.deleted_at_utc_millis is not distinct from new.deleted_at_utc_millis then
    new.updated_at_utc_millis := old.updated_at_utc_millis;
    new.origin := old.origin;
  end if;

  return new;
end;
$$;

drop trigger if exists journeys_hlc_merge_trigger on public.journeys;
create trigger journeys_hlc_merge_trigger
before insert or update on public.journeys
for each row execute function public.journeys_hlc_merge();

-- ---------------------------------------------------------------------------
-- 5. preferences: row-level HLC, plus tombstone (H-1 + M-2)
-- ---------------------------------------------------------------------------

create or replace function public.preferences_hlc_merge()
returns trigger
language plpgsql
as $$
declare
  v_value_wins boolean;
  v_tomb_millis bigint;
  v_tomb_device_id text;
  v_tomb_origin text;
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  v_value_wins := public.annotation_hlc_greater(
    new.hlc_millis, new.hlc_counter, new.hlc_device_id, new.origin,
    old.hlc_millis, old.hlc_counter, old.hlc_device_id, old.origin
  );

  if old.deleted_at_utc_millis is null and new.deleted_at_utc_millis is not null then
    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin, ''), new.origin,
      old.hlc_millis, old.hlc_counter, old.hlc_device_id, old.origin
    ) then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
      if not v_value_wins then
        new.value := old.value;
        new.hlc_millis := old.hlc_millis;
        new.hlc_counter := old.hlc_counter;
        new.hlc_device_id := old.hlc_device_id;
      end if;
      return new;
    end if;
    if not v_value_wins then
      new.value := old.value;
      new.hlc_millis := old.hlc_millis;
      new.hlc_counter := old.hlc_counter;
      new.hlc_device_id := old.hlc_device_id;
    end if;
    return new;
  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is null then
    if not public.annotation_hlc_greater(
      new.hlc_millis, new.hlc_counter, new.hlc_device_id, new.origin,
      old.updated_at_utc_millis, 0, coalesce(old.origin,''), old.origin
    ) then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.value := old.value;
      new.hlc_millis := old.hlc_millis;
      new.hlc_counter := old.hlc_counter;
      new.hlc_device_id := old.hlc_device_id;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
      return new;
    end if;
    return new;
  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is not null then
    -- Both deleted: gate field value against tombstone (M-2) then tombstone clock.
    v_tomb_millis := old.updated_at_utc_millis;
    v_tomb_device_id := coalesce(old.origin, '');
    v_tomb_origin := old.origin;
    if v_value_wins then
      if not public.annotation_hlc_greater(
        new.hlc_millis, new.hlc_counter, new.hlc_device_id, new.origin,
        v_tomb_millis, 0, v_tomb_device_id, v_tomb_origin
      ) then
        new.value := old.value;
        new.hlc_millis := old.hlc_millis;
        new.hlc_counter := old.hlc_counter;
        new.hlc_device_id := old.hlc_device_id;
        v_value_wins := false;
      end if;
    end if;
    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin,''), new.origin,
      old.updated_at_utc_millis, 0, coalesce(old.origin,''), old.origin
    ) then
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;
    if not v_value_wins then
      new.value := old.value;
      new.hlc_millis := old.hlc_millis;
      new.hlc_counter := old.hlc_counter;
      new.hlc_device_id := old.hlc_device_id;
    end if;
    -- Suppress metadata churn when field didn't win and tombstone unchanged (mirror insight_places/journeys)
    if not v_value_wins and old.deleted_at_utc_millis is not distinct from new.deleted_at_utc_millis then
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;
    return new;
  end if;

  if not v_value_wins then
    new.value := old.value;
    new.hlc_millis := old.hlc_millis;
    new.hlc_counter := old.hlc_counter;
    new.hlc_device_id := old.hlc_device_id;
    new.updated_at_utc_millis := old.updated_at_utc_millis;
    new.origin := old.origin;
  end if;

  return new;
end;
$$;

drop trigger if exists preferences_hlc_merge_trigger on public.preferences;
create trigger preferences_hlc_merge_trigger
before insert or update on public.preferences
for each row execute function public.preferences_hlc_merge();


revoke all on public.entitlement from authenticated, anon;
