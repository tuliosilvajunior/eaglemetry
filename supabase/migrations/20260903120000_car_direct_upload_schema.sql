-- Migration: 20260903120000_car_direct_upload_schema.sql
--
-- Issue #236, Phase 1 — the car uploads measurements to Supabase directly,
-- before any account has claimed the vehicle. Three changes, all additive:
--
--   1. `account_id` becomes nullable on `vehicle`, on `vehicle_devices` and on
--      every measurement table. An unclaimed row carries NULL. The phone's RLS
--      (`account_id = auth.uid()`) is unchanged, so an unclaimed row is
--      invisible to every account until a claim backfills it (Phase 3).
--   2. A `before insert or update` trigger stamps `account_id` from the
--      request identity — the device token for the car, `auth.uid()` for the
--      phone. The client cannot forge the column and cannot null it back out:
--      the value the server derives always wins. Superuser and service-role
--      writers (edge functions, the claim RPC, privacy tooling) are untouched,
--      because they own the column themselves.
--   3. `anon` RLS policies scope the car to its own vehicle, resolved from the
--      `x-car-token` header by `car_device_identity_from_header()`
--      (20260901130000). The car never holds a user JWT and the phone never
--      runs as `anon`, so the two roads never cross.
--
-- Relationship to issue #227 (20260902190000_car_device_telemetry_rls.sql):
-- that migration already gave the car `anon` policies on these same
-- measurement tables, but every one of them also demanded
-- `account_id = <the device's account_id>` — a claimed car only. That is
-- exactly the requirement Phase 1 removes, so this migration **replaces**
-- #227's measurement policies instead of sitting beside them: it reuses
-- #227's names (`*_device_reads`, `*_device_writes`, `*_device_updates`), so
-- each `drop policy if exists` + `create policy` pair supersedes the older
-- definition. Two permissive policies for one verb are ORed together and the
-- looser one wins silently; one name per verb per table makes that
-- impossible. #227's annotation and ownership policies (insight_places,
-- journeys, session_costs, preferences, preference_proposals,
-- vehicle_ownership, vehicle) are untouched and stay account-scoped: only a
-- measurement can exist before a claim.
--
-- Why the trigger is load-bearing, and what it does *not* do: the trigger
-- stops a client from **forging** the value on write — the payload never
-- chooses `account_id`, the server-derived value always wins. That is the
-- same "one writer per fact" discipline as Lane C, applied to a column
-- instead of a table. It does **not** stop an existing row from **moving**
-- to another account's visibility: with an account-less token the trigger
-- itself stamps NULL, so a bare vehicle-only policy would let a pre-claim
-- credential de-claim a row that a claim had already backfilled — and the
-- car's ordinary upload path reaches that branch, because
-- `Prefer: resolution=merge-duplicates` is `insert ... on conflict do
-- update`. Movement is stopped by the policy instead: the `using` clauses in
-- section 3 (SELECT, and the `using` half of UPDATE) also demand that the
-- row's existing `account_id` matches the token's, so a credential can only
-- see and rewrite the rows of the account it belongs to. The `with check`
-- halves stay vehicle-only on purpose — the trigger has already run by then,
-- so the value being checked is always server-derived.
--
-- `public.sample` is not listed below: it was dropped in
-- 20260830120000_drop_sample_table.sql and no longer exists.

-- ---------------------------------------------------------------------------
-- 1. Nullable account_id
-- ---------------------------------------------------------------------------

alter table public.vehicle
  alter column account_id drop not null;

-- The device credential itself is account-less before the claim.
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

-- ---------------------------------------------------------------------------
-- 2. Server-side account stamping
--
-- SECURITY INVOKER on purpose. A SECURITY DEFINER body would report the
-- definer in `current_user`, so the "leave privileged writers alone" branch
-- would match on every request and the stamp would never run. The body needs
-- no extra privilege: `car_device_identity_from_header()` is already SECURITY
-- DEFINER and granted to `anon`, and `auth.uid()` reads a GUC.
-- ---------------------------------------------------------------------------

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
    'trip_segments', 'battery_cycles', 'battery_cycle_sessions'
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

-- ---------------------------------------------------------------------------
-- 3. anon (car device) RLS — SELECT / INSERT / UPDATE scoped to the token's
--    vehicle *and*, on the clauses that see a row already in the table, to
--    the token's account. `is not distinct from` so an unclaimed row's NULL
--    matches an account-less token's NULL: that is what keeps the Phase 1
--    pre-claim upload path working. `account_id` stays deliberately absent
--    from every `with check` — the trigger owns writes to that column, and
--    it has already run when the check is evaluated.
--
--    Accepted consequence: a car still holding a *pre-claim* token after a
--    claim gets a refusal on reads and UPDATEs of the rows the claim
--    backfilled, until it adopts the post-claim token (Phase 3). That is the
--    transient window the architecture already accepts — 403, retry on the
--    next tick — and it now fails closed instead of destroying the owner's
--    row.
-- ---------------------------------------------------------------------------

-- session
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

-- "interval"
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

-- track — the route grows while the session is open and settles at close, so
-- the second write of the same session is an UPDATE of the row already there.
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

-- telemetry_events (insert-only: an event is never edited)
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

-- trip_segments (insert-only, and dormant since the track landed; the policy
-- is kept so the two route tables answer the same way)
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

-- battery_cycles
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

-- battery_cycle_sessions
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

-- ---------------------------------------------------------------------------
-- 4. Grants — the standing rule: expose a refusal through RLS, never through a
--    missing grant. `anon` gains the measurement verbs; the policies above are
--    the only rows it may touch.
-- ---------------------------------------------------------------------------

grant usage on schema public to anon;

grant select, insert, update on
  public.session,
  public."interval",
  public.track,
  public.battery_cycles,
  public.battery_cycle_sessions
  to anon;

grant select, insert on
  public.telemetry_events,
  public.trip_segments
  to anon;

-- ---------------------------------------------------------------------------
-- 5. schema_full.sql parity — the `service_role` grants below are a no-op
--    re-grant: `20260902190200_service_role_grants.sql` already grants exactly
--    these verbs, so there is no drift left to settle. They are kept only
--    because `grant` is idempotent and repeating them here makes this
--    migration's own role picture readable in one file. The column defaults
--    and the `not null` further down are the real parity fixes.
-- ---------------------------------------------------------------------------

grant select, insert, update on
  public.vehicle,
  public.session,
  public."interval",
  public.track,
  public.battery_cycles,
  public.battery_cycle_sessions
  to service_role;

grant select, insert on
  public.telemetry_events,
  public.trip_segments
  to service_role;

grant select, insert, update, delete on
  public.insight_places,
  public.session_costs,
  public.preferences,
  public.preference_proposals,
  public.journeys
  to service_role;

-- Same drift, other direction: the consolidated file declares these boolean
-- defaults and the migrations never set them.
alter table public.battery_cycles
  alter column is_open set default false,
  alter column is_partial set default false,
  alter column energy_incomplete set default false,
  alter column mixed_currency set default false;
alter table public.session
  alter column no_longer_reducible set default false;

-- Same drift again: 20260902170100 adds `cycle_start_utc_millis` nullable and
-- then raises if any row is still NULL, so the column is NOT NULL in fact and
-- `schema_full.sql` already declares it so — but no migration ever said it.
-- The foreign key depends on the column, and a NULL there silently opts a
-- membership row out of the reference. Settle it in the direction the file
-- documents.
alter table public.battery_cycle_sessions
  alter column cycle_start_utc_millis set not null;

notify pgrst, 'reload schema';
