-- Migration: 20260831120000_battery_cycles_key_on_start_time.sql
--
-- A cycle's cloud key was `(vehicle_id, ordinal)`, and an ordinal is a
-- position in a ledger, not an identity. The ledger is rebuilt by folding
-- closed sessions, so a reinstall, a deleted session or a price correction
-- renumbers every later cycle. The car then uploads its new cycle 120 and
-- Postgres' `ON CONFLICT (vehicle_id, ordinal)` overwrites an older, entirely
-- different cycle that also happened to be number 120 — destroying the cost
-- blend the ledger exists to protect, silently and irreversibly.
--
-- A cycle's start time is its identity: it comes from the first session in
-- the cycle and survives every renumbering. The key moves to
-- `(vehicle_id, start_utc_millis)`. `ordinal` stays as a column — it is still
-- the ledger position the car reports — it just stops being the key.
--
-- Two things follow that this migration also does:
--
--   * the foreign key from `battery_cycle_sessions` reached
--     `(vehicle_id, ordinal)`, which stops being unique here. No client
--     writes that table (the phone's uploader carries vehicle, session,
--     interval, track, telemetry_events and battery_cycles only), so the
--     reference is dropped rather than re-pointed at a column the membership
--     rows do not carry. Rebuilding cloud memberships on the new key is its
--     own decision, taken when something actually writes them;
--   * a renumbering can legitimately leave two cloud rows for one vehicle
--     holding the same ordinal (the old cycle 120 and the new one). That is
--     why nothing here keeps a unique index on ordinal: it would refuse the
--     very upload this change exists to let through.

-- ---------------------------------------------------------------------------
-- 1. The reference that names the old key

-- Found by name rather than assumed: the constraint was created inline in
-- slice 6 and Postgres named it, so the search matches any FK on the
-- membership table that reaches battery_cycles, whatever it is called.
do $$
declare
  fk record;
begin
  for fk in
    select conname
    from pg_constraint
    where conrelid = 'public.battery_cycle_sessions'::regclass
      and confrelid = 'public.battery_cycles'::regclass
      and contype = 'f'
  loop
    execute format(
      'alter table public.battery_cycle_sessions drop constraint %I',
      fk.conname
    );
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 2. The key

-- Rows already in the cloud were keyed by ordinal, so two of them can only
-- share a start time if something already wrote a cycle twice under different
-- ordinals. That has never been observed and nothing in the writers can
-- produce it, but if it has happened anyway, this migration refuses to pick
-- a survivor: the unique key below cannot be built over colliding rows, and
-- choosing which cycle is the real one is not a decision a migration makes
-- in passing. The failure names the vehicle and the colliding starts, and
-- nothing has been dropped when it fires.
do $$
declare
  collision record;
begin
  select vehicle_id, count(*) as rows, min(start_utc_millis) as first_start
  into collision
  from public.battery_cycles
  group by vehicle_id, start_utc_millis
  having count(*) > 1
  limit 1;

  if collision is not null then
    raise exception
      'battery_cycles holds % rows for vehicle % that share the start time %; '
      'the new key (vehicle_id, start_utc_millis) cannot be built over them. '
      'Decide which cycle is real before re-running this migration.',
      collision.rows, collision.vehicle_id, collision.first_start;
  end if;
end
$$;

alter table public.battery_cycles
  drop constraint battery_cycles_pkey,
  add constraint battery_cycles_pkey
    primary key (vehicle_id, start_utc_millis);

-- ---------------------------------------------------------------------------
-- 3. Tell PostgREST

-- The uploader's `on_conflict` parameter is resolved against a unique
-- constraint from a cached schema. Supabase reloads it on DDL by itself, but
-- the reload is what makes the new key take effect, so it is asked for here
-- rather than assumed.
notify pgrst, 'reload schema';
