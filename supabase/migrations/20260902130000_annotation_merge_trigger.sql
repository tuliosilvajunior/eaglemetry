-- Migration: 20260902130000_annotation_merge_trigger.sql
--
-- Phase 2 Lane B Step 2: per-field last-write-wins merge, enforced in Postgres.
--
-- Each annotation table already carries per-field-group HLC triples (added in
-- 20260902120000). This migration adds the trigger that *enforces* LWW
-- per field group, so the rule lives once, in the database, instead of twice
-- (Kotlin + Dart).
--
-- Comparison order matches `AnnotationConvergence.shouldReplace` in
-- `android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/AnnotationConvergence.kt`
-- and `annotationShouldReplace` in `packages/telemetry_core/lib/sync_annotations.dart`:
--   millis  (bigint, physical wall)  — strictly greater wins
--   counter (integer, logical)       — on equal millis, greater wins
--   origin rank (car=2, phone=1, other=0) — on equal millis+counter, greater wins
--   device_id (text, lexicographic)  — final deterministic tie-break; identical
--                                      triple returns true (idempotent replay).
--
-- Per-group independence: a single UPDATE that touches multiple groups is
-- evaluated per-group. Example: NEW has newer name_hlc but stale geofence_hlc:
-- the trigger keeps OLD geofence columns/HLC and lets the name change through.
-- This satisfies story 26 ("name and radius both survive").
--
-- Tombstone (`deleted_at_utc_millis`) handling — the deliberate unimplemented
-- detail from the previous migration:
--
-- * No dedicated HLC columns were added for the tombstone. Its effective HLC
--   reuses the row's wall clock plus origin that already exist:
--     millis    = updated_at_utc_millis
--     counter   = 0
--     device_id = origin (coalesced to '')
--     origin    = origin (for rank)
--   This mirrors the backfill seeding (updated_at -> hlc_millis, origin -> hlc_device_id).
--
-- * The tombstone competes against the MAX of the row's field-group HLCs.
--   Reasoning: a delete and a field edit are concurrent writes to the same
--   logical object. If the delete's wall clock is newer than every field edit's
--   HLC, the user's intent to delete is the latest and must survive; otherwise
--   the field edit is later and the delete is stale and must be ignored (prevents
--   a stale replica resurrecting or re-deleting incorrectly after weeks offline).
--
--   * Delete attempt (OLD not deleted, NEW deleted):
--       delete_clock = (NEW.updated, 0, NEW.origin, NEW.origin)
--       max_old_field = greatest OLD field-group HLC (by same ordering)
--       If delete_clock is not strictly greater, the delete is rejected: OLD
--       deleted/updated/origin are restored and the field-group decisions stand.
--
--   * Resurrection attempt (OLD deleted, NEW not deleted, NEW carries field edits):
--       tombstone_clock = (OLD.updated, 0, OLD.origin, OLD.origin)
--       For each field group that provisionally won (NEW HLC > OLD HLC), the
--       incoming HLC must also be > tombstone_clock to be allowed to clear the
--       tombstone. If no field group beats the tombstone, the row stays deleted.
--       If at least one beats it, resurrection is allowed (NEW.deleted stays NULL).
--
--   * Both deleted (already tombstoned, metadata change): keep the newer tombstone
--     clock (wall+origin). This is the same ordering as field groups and keeps
--     the trigger idempotent.
--
-- * When no group wins and no tombstone transition is accepted, updated_at/
--   origin are restored to OLD to avoid timestamp churn and keep the merge
--   idempotent (re-applying the same write changes nothing).
--
-- Trigger wiring: BEFORE INSERT OR UPDATE on each of the four tables. On INSERT
-- the row is new (no OLD), so the trigger simply returns NEW. On UPDATE the
-- per-group logic runs. Upserts via `INSERT ... ON CONFLICT DO UPDATE` still
-- hit the UPDATE path for the conflict case (Postgres fires the UPDATE trigger
-- for the DO UPDATE branch), so arrival order is still serialised.

-- ---------------------------------------------------------------------------
-- Helper: strict HLC ordering with deterministic tie-break.
-- ---------------------------------------------------------------------------

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
declare
  v_in_rank integer;
  v_ex_rank integer;
begin
  -- NULLs are treated as the smallest value (coalesce in trigger ensures
  -- 0/'' but IS DISTINCT FROM already handles NULL correctly).
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
  -- Identical triple: accept (idempotent replay — same write applied twice
  -- must be a no-op in values but not a rejection that would diverge).
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- insight_places: 2 groups — name and geofence, plus tombstone
-- ---------------------------------------------------------------------------

create or replace function public.insight_places_hlc_merge()
returns trigger
language plpgsql
as $$
declare
  v_name_wins boolean;
  v_geofence_wins boolean;
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

  -- Per-group LWW
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

  v_any_field_wins := v_name_wins or v_geofence_wins;

  -- Tombstone vs max field clock
  if old.deleted_at_utc_millis is null and new.deleted_at_utc_millis is not null then
    -- Delete attempt: compare delete clock (wall+origin) vs max OLD field HLC.
    -- Determine max OLD field HLC.
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

    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin, ''), new.origin,
      v_max_old_millis, v_max_old_counter, v_max_old_device_id, v_max_old_origin
    ) then
      -- Stale delete: keep alive.
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

    v_any_field_wins := v_name_wins or v_geofence_wins;

    if not v_any_field_wins then
      -- Nothing beat the tombstone: stay deleted.
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
    end if;

  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is not null then
    -- Both deleted: keep newer tombstone clock.
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
-- session_costs: 1 group — cost, no tombstone
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
-- journeys: 3 groups — name, note, time_range, plus tombstone
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
  v_tmp_millis bigint;
  v_tmp_counter integer;
  v_tmp_device_id text;
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

    -- compare with note
    if public.annotation_hlc_greater(
      old.note_hlc_millis, old.note_hlc_counter, old.note_hlc_device_id, old.origin,
      v_max_old_millis, v_max_old_counter, v_max_old_device_id, v_max_old_origin
    ) then
      v_max_old_millis := old.note_hlc_millis;
      v_max_old_counter := old.note_hlc_counter;
      v_max_old_device_id := old.note_hlc_device_id;
      -- origin stays same (row-level), keep
    end if;

    -- compare with time_range
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
-- preferences: row-level HLC, plus tombstone (row == field)
-- ---------------------------------------------------------------------------

create or replace function public.preferences_hlc_merge()
returns trigger
language plpgsql
as $$
declare
  v_value_wins boolean;
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  v_value_wins := public.annotation_hlc_greater(
    new.hlc_millis, new.hlc_counter, new.hlc_device_id, new.origin,
    old.hlc_millis, old.hlc_counter, old.hlc_device_id, old.origin
  );

  -- Tombstone and value share the same clock (row-level). The delete's
  -- effective clock is the same wall+origin as the value's HLC when counter=0.
  -- To keep the rule uniform, we evaluate tombstone transitions first.
  if old.deleted_at_utc_millis is null and new.deleted_at_utc_millis is not null then
    -- Deleting: must beat current value clock.
    if not public.annotation_hlc_greater(
      new.updated_at_utc_millis, 0, coalesce(new.origin, ''), new.origin,
      old.hlc_millis, old.hlc_counter, old.hlc_device_id, old.origin
    ) then
      -- Also require delete to beat value's own HLC via the value path?
      -- If value didn't win, delete shouldn't either? Check both: delete must be > old HLC.
      -- The value path already computed v_value_wins; if delete is just a tombstone marker
      -- we still use value clock as max. So reject stale delete.
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
      -- also revert value if it didn't win
      if not v_value_wins then
        new.value := old.value;
        new.hlc_millis := old.hlc_millis;
        new.hlc_counter := old.hlc_counter;
        new.hlc_device_id := old.hlc_device_id;
      end if;
      return new;
    end if;
    -- Delete wins: if value also didn't win, keep old value behind tombstone.
    if not v_value_wins then
      new.value := old.value;
      new.hlc_millis := old.hlc_millis;
      new.hlc_counter := old.hlc_counter;
      new.hlc_device_id := old.hlc_device_id;
    end if;
    return new;
  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is null then
    -- Resurrecting: incoming value must beat tombstone clock.
    if not public.annotation_hlc_greater(
      new.hlc_millis, new.hlc_counter, new.hlc_device_id, new.origin,
      old.updated_at_utc_millis, 0, coalesce(old.origin,''), old.origin
    ) then
      -- Tombstone wins, keep deleted.
      new.deleted_at_utc_millis := old.deleted_at_utc_millis;
      new.value := old.value;
      new.hlc_millis := old.hlc_millis;
      new.hlc_counter := old.hlc_counter;
      new.hlc_device_id := old.hlc_device_id;
      new.updated_at_utc_millis := old.updated_at_utc_millis;
      new.origin := old.origin;
      return new;
    end if;
    -- Value beats tombstone: allow resurrection (keep NEW deleted null).
    -- v_value_wins already true if HLC > old; but we just checked vs tombstone,
    -- so even if v_value_wins was false due to tie vs old HLC, the tombstone
    -- check may still allow it if tombstone is older. Keep NEW value/HLC.
    return new;
  elsif old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is not null then
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
    return new;
  end if;

  -- No tombstone transition: normal LWW on value.
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
