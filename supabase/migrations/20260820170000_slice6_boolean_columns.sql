-- Slice 6, phase C: five columns that are booleans and were typed as integers.
--
-- The first migration was generated from the car's exported Room schema, which
-- reports a **storage affinity**, not a type. SQLite has no boolean, so it
-- stores one as INTEGER, and the generator turned every INTEGER into `bigint`.
-- Kotlin still calls these fields `Boolean`, `toExportRow()` puts `true` in the
-- map, and the sync carries `true` all the way to PostgREST — which refuses it
-- for a bigint with `22P02`, invalid text representation.
--
-- The car app is the authority on what these mean, and it says boolean. The
-- affinity was a fact about SQLite, not about the measurement.
--
-- Found on 2026-08-20 by the first real upload from the phone: `22P02 ·
-- session · 23`. Nothing had landed, so the conversion below has no rows to
-- rewrite in practice; it is written to be correct anyway.

alter table public.session
  alter column no_longer_reducible drop default,
  alter column no_longer_reducible type boolean
    using (no_longer_reducible <> 0);

alter table public.battery_cycles
  alter column is_open type boolean using (is_open <> 0),
  alter column is_partial type boolean using (is_partial <> 0),
  alter column energy_incomplete type boolean using (energy_incomplete <> 0),
  alter column mixed_currency type boolean using (mixed_currency <> 0);
