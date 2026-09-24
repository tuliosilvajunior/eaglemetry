-- Migration: 20260902120000_annotation_hlc_stamps.sql
--
-- Phase 2 Lane B Step 1: add hybrid-logical-clock (HLC) stamp columns to the
-- four cloud annotation tables. Pure additive migration — no trigger logic yet
-- (that is the next step). Mirrors the three-part shape from
-- `packages/telemetry_core/lib/dto/sync_models.dart`'s HlcTimestamp:
--   millis  (physical, UTC ms)  -> bigint
--   counter (logical tie-break)  -> integer
--   deviceId (origin, final deterministic tie-break) -> text
--
-- Grouping decision (judgment call, documented here per task):
--
-- * insight_places        — 2 field groups, each with its own HLC triple:
--     - name_hlc_*        -> `name` (identity). Renames happen on the phone's
--       larger keyboard, independently of map edits.
--     - geofence_hlc_*    -> `latitude`, `longitude`, `radius_m` (location).
--       Geofence edits are a map drag / radius slider, unrelated to the label.
--   Why 2 groups: story 26 of issue 227 says "an edit to a place's name and a
--   concurrent edit to its radius to both survive". Keeping name and geofence
--   on separate clocks makes that field-level merge possible. `created_at`,
--   `account_id` are immutable; `origin` is metadata; `deleted_at_utc_millis`
--   is a tombstone. A tombstone's HLC competes against every field group —
--   the future merge trigger will compare the delete's clock to the max of the
--   field clocks, so no new columns are needed for the tombstone itself in
--   this additive step (it reuses the wall clock + origin already stored).
--
-- * session_costs         — 1 field group:
--     - cost_hlc_*        -> `cost_per_kwh`, `paid_amount`, `cost_currency`
--   Why 1 group: the three cost columns are typically edited together (enter
--   price + currency at the same time). Splitting them would risk a partial
--   state where the amount and currency diverge across replicas — e.g. phone
--   writes 0.75 BRL while car writes 0.80 USD for the same session. One clock
--   keeps the monetary fact atomic, matching today's phone UX which saves all
--   three at once.
--
-- * journeys              — 3 field groups:
--     - name_hlc_*        -> `name`
--     - note_hlc_*        -> `note`
--     - time_range_hlc_*  -> `started_at_utc_millis`, `ended_at_utc_millis`
--   Why 3 groups: journey fields are edited for independent reasons (ADR 0012:
--   "whose fields are edited for independent reasons"). The name is set at
--   creation, the note is a free-text reflection added later, and the time
--   window is adjusted via a date picker to include/exclude sessions. Two
--   people (or the same person on two devices) editing note vs. time range
--   should not overwrite each other. Start and end stay together because a
--   window is meaningless with only one bound.
--
-- * preferences           — 1 row-level clock (row == field):
--     - hlc_millis, hlc_counter, hlc_device_id -> `value` (and tombstone)
--   Why row-level: preferences is already key/value (PK = scope,key), so the
--   row and the field coincide per the issue. One triple is the field's clock.
--
-- All columns are NOT NULL with sensible defaults (0 / ''), so existing rows
-- and new rows without an explicit stamp remain valid. Backfill sets each
-- group's millis = updated_at_utc_millis, counter = 0, device_id =
-- COALESCE(NULLIF(origin,''), 'car') — a sensible stamp for pre-HLC rows that
-- sorts identically to the wall-clock ordering that preceded it.

-- ---------------------------------------------------------------------------
-- 1. insight_places — 2 groups: name, geofence
-- ---------------------------------------------------------------------------

alter table public.insight_places
  add column if not exists name_hlc_millis bigint not null default 0;
alter table public.insight_places
  add column if not exists name_hlc_counter integer not null default 0;
alter table public.insight_places
  add column if not exists name_hlc_device_id text not null default '';

alter table public.insight_places
  add column if not exists geofence_hlc_millis bigint not null default 0;
alter table public.insight_places
  add column if not exists geofence_hlc_counter integer not null default 0;
alter table public.insight_places
  add column if not exists geofence_hlc_device_id text not null default '';

-- ---------------------------------------------------------------------------
-- 2. session_costs — 1 group: cost
-- ---------------------------------------------------------------------------

alter table public.session_costs
  add column if not exists cost_hlc_millis bigint not null default 0;
alter table public.session_costs
  add column if not exists cost_hlc_counter integer not null default 0;
alter table public.session_costs
  add column if not exists cost_hlc_device_id text not null default '';

-- ---------------------------------------------------------------------------
-- 3. journeys — 3 groups: name, note, time_range
-- ---------------------------------------------------------------------------

alter table public.journeys
  add column if not exists name_hlc_millis bigint not null default 0;
alter table public.journeys
  add column if not exists name_hlc_counter integer not null default 0;
alter table public.journeys
  add column if not exists name_hlc_device_id text not null default '';

alter table public.journeys
  add column if not exists note_hlc_millis bigint not null default 0;
alter table public.journeys
  add column if not exists note_hlc_counter integer not null default 0;
alter table public.journeys
  add column if not exists note_hlc_device_id text not null default '';

alter table public.journeys
  add column if not exists time_range_hlc_millis bigint not null default 0;
alter table public.journeys
  add column if not exists time_range_hlc_counter integer not null default 0;
alter table public.journeys
  add column if not exists time_range_hlc_device_id text not null default '';

-- ---------------------------------------------------------------------------
-- 4. preferences — row-level HLC
-- ---------------------------------------------------------------------------

alter table public.preferences
  add column if not exists hlc_millis bigint not null default 0;
alter table public.preferences
  add column if not exists hlc_counter integer not null default 0;
alter table public.preferences
  add column if not exists hlc_device_id text not null default '';

-- ---------------------------------------------------------------------------
-- 5. Backfill existing rows
-- ---------------------------------------------------------------------------

-- insight_places: both groups seeded from wall clock + origin
update public.insight_places
   set name_hlc_millis = updated_at_utc_millis,
       name_hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where name_hlc_millis = 0;

update public.insight_places
   set geofence_hlc_millis = updated_at_utc_millis,
       geofence_hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where geofence_hlc_millis = 0;

-- session_costs: single cost group
update public.session_costs
   set cost_hlc_millis = updated_at_utc_millis,
       cost_hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where cost_hlc_millis = 0;

-- journeys: three groups, each seeded independently
update public.journeys
   set name_hlc_millis = updated_at_utc_millis,
       name_hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where name_hlc_millis = 0;

update public.journeys
   set note_hlc_millis = updated_at_utc_millis,
       note_hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where note_hlc_millis = 0;

update public.journeys
   set time_range_hlc_millis = updated_at_utc_millis,
       time_range_hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where time_range_hlc_millis = 0;

-- preferences: row-level
update public.preferences
   set hlc_millis = updated_at_utc_millis,
       hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where hlc_millis = 0;

-- Counters stay 0 for backfilled rows; no causal history exists yet.
