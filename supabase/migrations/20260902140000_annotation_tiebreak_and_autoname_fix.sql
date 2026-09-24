-- Migration: 20260902140000_annotation_tiebreak_and_autoname_fix.sql
--
-- Fixes for PR #232 review (H-1, M-2, M-3).
--
-- H-1: drop origin_rank tie-break for general per-field merge. Ordering is now
--   millis -> counter -> device_id lexicographic. Still deterministic and removes
--   the row-metadata dependency that made convergence order-dependent
--   (same writes, different arrival order -> different final state -- reproduced
--   in the review report). The row-level `origin` column reflects the last
--   accepted write to ANY group, not the origin of the competing write, so
--   using it as a tie-break makes per-field comparisons impure.
--   Change applied here and mirrored in Kotlin/Dart:
--     supabase/migrations/20260902130000_annotation_merge_trigger.sql
--     android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/AnnotationConvergence.kt
--     packages/telemetry_core/lib/sync_annotations.dart
--   Tombstone clocks (wall+origin derived) also use this device_id-only ordering
--   after the fix; they remain comparable via millis/counter/device_id.
--
-- M-2: both-deleted branch was missing the tombstone gate. Every other tombstone
--   path gates field-value acceptance against the tombstone's own clock (wall
--   + origin, counter 0). The both-deleted branch skipped this and let a write
--   older than the deletion silently overwrite retained field values behind the
--   tombstone. Fix: gate each provisionally-winning field group against the
--   tombstone clock exactly as the resurrection branch does, for insight_places,
--   journeys, and preferences.
--
-- M-3: insight_places.auto_name* (auto_name, auto_name_updated_at_utc_millis,
--   auto_name_source) added by 20260825120000_slice8_insight_places_autoname.sql
--   was never covered by the Step-1 grouping or Step-2 trigger -- any UPDATE
--   carrying these values passed through with no merge. Per ADR 0009
--   (docs/adr/0009-companion-nominatim-auto-name.md) the sync rule for these
--   specific columns is "car > phone > cloud via origin tie-break" -- a distinct,
--   still-valid rule, NOT the general per-field tie-break simplified in H-1.
--   This migration:
--     1. Adds HLC stamp columns for auto_name as its own field group (separate
--        from the existing name group). Reason: name and auto_name are edited
--        for independent reasons -- name is user-edited (phone keyboard), auto_name
--        is a companion suggestion from Nominatim. Display is `name ?? autoName`,
--        and ADR 0009 forbids auto-overwrite of a non-empty name/autoName. Sharing
--        a clock would conflate them: a name edit would bump auto_name's HLC and
--        vice versa, breaking field-level independence. Keeping them separate lets
--        a rename and a geocode suggestion both survive, matching story 26's
--        intent for independent groups.
--     2. Adds trigger logic honoring ADR 0009's origin-based rank (car=2, phone=1,
--        cloud/other=0) for the auto_name group only, via a dedicated helper
--        `annotation_hlc_greater_with_origin_rank`. All other groups use the
--        device_id-only helper after H-1.
--     3. Fixes supabase/schema_full.sql drift (auto_name columns were missing).
--     4. Notes the grouping omission: 20260902120000_annotation_hlc_stamps.sql's
--        comment inventories insight_places as "2 groups: name, geofence" and
--        omits auto_name; the omission is corrected here without editing the
--        already-committed Step-1 file.
--
-- This file replaces trigger functions via `create or replace` and is additive
-- for columns (IF NOT EXISTS). It is idempotent.

-- ---------------------------------------------------------------------------
-- 0. Ensure auto_name base columns exist (slice 8) + add HLC triple for auto_name
-- ---------------------------------------------------------------------------

alter table public.insight_places
  add column if not exists auto_name text default null,
  add column if not exists auto_name_updated_at_utc_millis bigint default null,
  add column if not exists auto_name_source text default null;

alter table public.insight_places
  add column if not exists auto_name_hlc_millis bigint not null default 0;
alter table public.insight_places
  add column if not exists auto_name_hlc_counter integer not null default 0;
alter table public.insight_places
  add column if not exists auto_name_hlc_device_id text not null default '';

-- Backfill existing rows: reuse wall clock + origin, same as other groups.
update public.insight_places
   set auto_name_hlc_millis = updated_at_utc_millis,
       auto_name_hlc_device_id = coalesce(nullif(origin, ''), 'car')
 where auto_name_hlc_millis = 0;

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
