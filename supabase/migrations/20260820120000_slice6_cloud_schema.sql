-- Slice 6, phase C: the cloud replica of the car's schema.
--
-- Three rules decide the shape of this file (see below):
--
--   1. The same names and the same columns as the car. The Room columns are
--      camelCase and every name below is that name in snake_case, which is a
--      mechanical transform in one direction. Postgres folds an unquoted
--      identifier to lower case, so a literal camelCase column would have to be
--      quoted at every call site and would still not read as the car's name.
--   2. Nothing is calculated here. A rollup arrives already summed.
--   3. Idempotency is on the vehicle and the session's uuid, never on an
--      integer primary key. A wipe restarts the car's `rowId` at 1, and the
--      same vehicle's older cloud rows would collide with it.
--
-- The car's device-local integer keys (`session.rowId`, `sample.id`,
-- `telemetry_events.id`) are deliberately absent. They have no meaning outside
-- one database.

-- ---------------------------------------------------------------------------
-- Who owns what
-- ---------------------------------------------------------------------------

-- One row per car. This is the only place the owner is stored once; every
-- measurement row carries `account_id` denormalised beside it, which is the one
-- justified exception to the denormalisation rule. The reason is the RLS
-- policy, not a query: a policy that had to join to `vehicle` on every row
-- would be a join per check.
create table public.vehicle (
  vehicle_id text primary key,
  account_id uuid not null references auth.users (id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

create index vehicle_account_idx on public.vehicle (account_id);

-- What an account is allowed to read, and until when.
--
-- This table is written **only** by the payment webhook, through the service
-- role. It carries no policy at all, so no client token can read or write it;
-- the window function below reads it as `security definer`. A client-writable
-- entitlement is a client-editable subscription.
create table public.entitlement (
  account_id uuid primary key references auth.users (id) on delete cascade,
  tier text not null default 'free',
  valid_until timestamptz,
  updated_at timestamptz not null default now()
);

-- The free window, in days.
--
-- **This number is not decided yet** (still open product decision). It lives in a row rather than inside a policy
-- so that deciding it is one UPDATE and not a migration. It applies to
-- `sample`, `telemetry_events` and the route, and never to `session` or
-- `interval`.
create table public.plan_config (
  id boolean primary key default true check (id),
  free_window_days integer not null default 30
);

insert into public.plan_config (id) values (true);

-- The oldest instant an account may read a detail row at, as epoch millis.
--
-- A paid account with a live entitlement reads everything, which is 0. A free
-- account, or one whose entitlement has lapsed, reads back to the window. What
-- happens to a lapsed account's rows in the cloud — delete, freeze or a grace
-- period — is a separate open decision with a legal edge, and this function
-- deliberately does not answer it: it only stops the reading.
create or replace function public.detail_floor_millis(uid uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select case
    when exists (
      select 1 from public.entitlement e
      where e.account_id = uid
        and e.tier <> 'free'
        and (e.valid_until is null or e.valid_until > now())
    ) then 0::bigint
    else (extract(epoch from now()) * 1000)::bigint
         - (select free_window_days from public.plan_config) * 86400000::bigint
  end;
$$;

revoke all on function public.detail_floor_millis(uuid) from public;
grant execute on function public.detail_floor_millis(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Measurement tables — one writer, never edited
-- ---------------------------------------------------------------------------

create table public.session (
  vehicle_id text not null references public.vehicle (vehicle_id) on delete cascade,
  id text not null,
  account_id uuid not null,
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
  no_longer_reducible bigint not null,
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
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  updated_at_elapsed_nanos bigint,
  uploaded_at timestamptz not null default now(),
  primary key (vehicle_id, id)
);

create index session_account_started_idx
  on public.session (account_id, started_at_utc_millis desc);
create index session_kind_started_idx
  on public.session (vehicle_id, kind, started_at_utc_millis desc);

-- `interval` is a reserved word in Postgres, so the table is quoted wherever it
-- is named. The name matches the car's table, which is the rule that decided it.
create table public."interval" (
  vehicle_id text not null,
  session_id text not null,
  account_id uuid not null,
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
  updated_at_utc_millis bigint not null,
  primary key (vehicle_id, session_id, start_utc_millis),
  foreign key (vehicle_id, session_id)
    references public.session (vehicle_id, id) on delete cascade
);

create index interval_account_start_idx
  on public."interval" (account_id, start_utc_millis);

-- `sample` is partitioned by month on `t_utc_millis`.
--
-- Deleting a month is dropping a partition. A DELETE over millions of rows
-- locks the table and inflates the WAL, and this is the table that grows at
-- about 700 MB a year against 10 for the layers above it.
--
-- The primary key is (vehicle_id, key, t_utc_millis) and **not** the tuple the
-- plan names. `session_id` is nullable by the back-stamp rule — the transitions
-- that start a session happen before the session exists — and a nullable column
-- cannot sit in a primary key. The key that remains is still correct and still
-- idempotent: one vehicle, one signal, one instant is one reading.
create table public.sample (
  vehicle_id text not null,
  session_id text,
  account_id uuid not null,
  key text not null,
  t_utc_millis bigint not null,
  t_elapsed_nanos bigint not null,
  boot_count bigint,
  value double precision,
  validity text not null,
  group_id text,
  primary key (vehicle_id, key, t_utc_millis)
) partition by range (t_utc_millis);

create index sample_session_key_idx
  on public.sample (vehicle_id, session_id, key, t_utc_millis);
create index sample_group_idx on public.sample (vehicle_id, group_id);

-- The partitions live outside `public`, and that is a boundary rather than
-- tidiness.
--
-- A policy on a partitioned table applies when the query goes through the
-- parent. Querying a partition **directly** uses that partition's own policies,
-- and a fresh partition has none — so a partition sitting in `public` would be
-- one more table PostgREST exposes, holding the same detail rows with no window
-- on them. Two guards, because this one is silent when it fails: the partitions
-- are created in a schema PostgREST does not expose, and each one has RLS
-- enabled with no policy of its own, which denies every direct read while
-- leaving reads through `public.sample` to the parent's policy.
create schema partitions;
revoke all on schema partitions from public;

-- Make the partition for one month, and for every month it is called for.
--
-- Boundaries are epoch millis so the partition key stays the column the car
-- already writes. Call it from the uploader before a batch, and from pg_cron
-- ahead of the turn of the month.
create or replace function public.ensure_sample_partition(month_start date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  lo bigint := (extract(epoch from date_trunc('month', month_start)) * 1000)::bigint;
  hi bigint := (extract(epoch from date_trunc('month', month_start) + interval '1 month') * 1000)::bigint;
  name text := format('sample_%s', to_char(date_trunc('month', month_start), 'YYYY_MM'));
begin
  if to_regclass(format('partitions.%I', name)) is null then
    execute format(
      'create table partitions.%I partition of public.sample for values from (%s) to (%s)',
      name, lo, hi
    );
    execute format('alter table partitions.%I enable row level security', name);
  end if;
end;
$$;

revoke all on function public.ensure_sample_partition(date) from public;
grant execute on function public.ensure_sample_partition(date) to authenticated;

-- A row whose month has no partition lands here rather than failing the batch.
-- It is a fault to investigate, not a place to leave rows.
create table partitions.sample_default partition of public.sample default;
alter table partitions.sample_default enable row level security;

create table public.telemetry_events (
  vehicle_id text not null,
  session_id text,
  account_id uuid not null,
  type text not null,
  occurred_at_utc_millis bigint not null,
  -- The car allows a null `signalId`. A null cannot sit in the key that makes
  -- a replayed upload a no-op, so an absent signal is the empty string here.
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

create index telemetry_events_account_idx
  on public.telemetry_events (account_id, occurred_at_utc_millis desc);
create index telemetry_events_session_idx
  on public.telemetry_events (vehicle_id, session_id, occurred_at_utc_millis);

-- The route. It is a detail, and the window applies to it.
create table public.trip_segments (
  vehicle_id text not null,
  session_id text not null,
  ordinal bigint not null,
  account_id uuid not null,
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

create index trip_segments_account_idx
  on public.trip_segments (account_id, start_utc_millis);

create table public.battery_cycles (
  vehicle_id text not null references public.vehicle (vehicle_id) on delete cascade,
  ordinal bigint not null,
  account_id uuid not null,
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
  is_open bigint not null,
  is_partial bigint not null,
  energy_incomplete bigint not null,
  mixed_currency bigint not null,
  opening_priced_fraction double precision not null,
  opening_blended_price double precision not null,
  frozen_at_utc_millis bigint,
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  primary key (vehicle_id, ordinal)
);

create index battery_cycles_account_idx
  on public.battery_cycles (account_id, start_utc_millis);

create table public.battery_cycle_sessions (
  vehicle_id text not null,
  cycle_ordinal bigint not null,
  session_kind text not null,
  session_id text not null,
  account_id uuid not null,
  share double precision not null,
  start_utc_millis bigint not null,
  end_utc_millis bigint not null,
  primary key (vehicle_id, cycle_ordinal, session_kind, session_id),
  foreign key (vehicle_id, cycle_ordinal)
    references public.battery_cycles (vehicle_id, ordinal) on delete cascade
);

-- ---------------------------------------------------------------------------
-- Annotation tables — many writers, always editable
-- ---------------------------------------------------------------------------
--
-- These are keyed on the account, not on the vehicle: a place a person names
-- belongs to the person and names the trips of every car they own. They carry
-- a tombstone, because a stale replica must not resurrect a deletion. A
-- measurement never gets one — it must be gone.

create table public.insight_places (
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
  primary key (account_id, id)
);

create table public.session_costs (
  vehicle_id text not null,
  session_id text not null,
  account_id uuid not null,
  cost_per_kwh double precision,
  paid_amount double precision,
  cost_currency text,
  updated_at_utc_millis bigint not null,
  origin text not null,
  primary key (vehicle_id, session_id),
  foreign key (vehicle_id, session_id)
    references public.session (vehicle_id, id) on delete cascade
);

create table public.preferences (
  account_id uuid not null references auth.users (id) on delete cascade,
  scope text not null,
  key text not null,
  value text,
  updated_at_utc_millis bigint not null,
  origin text not null,
  deleted_at_utc_millis bigint,
  primary key (account_id, scope, key)
);

create table public.preference_proposals (
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
