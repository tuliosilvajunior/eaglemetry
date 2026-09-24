-- Slice 8: InsightPlace autoName suggestion from companion Nominatim.
--
-- Additive nullable columns. Existing rows stay valid, no backfill.
-- Follows decision in docs/adr/0009-companion-nominatim-auto-name.md:
-- user name always wins and is never overwritten by autoName; display is
-- name ?? autoName, sync is car > phone > cloud via origin tie-break.

alter table public.insight_places
  add column if not exists auto_name text default null,
  add column if not exists auto_name_updated_at_utc_millis bigint default null,
  add column if not exists auto_name_source text default null;
