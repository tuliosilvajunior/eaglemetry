-- Migration: 20260902190000_car_device_telemetry_rls.sql
--
-- Car device RLS for Lanes A/B (issue #227 — verify car uploads end-to-end).
--
-- Problem: HttpCloudSink runs as `anon` with `x-car-token` and relies on
-- `car_device_identity_from_header()` for identity (20260901130000). The only
-- `anon` policies that existed were for the Lane C control pair
-- (`preference_desired`/`preference_reported`) and `vehicle_devices`. Every
-- telemetry/annotation table (session, interval, track, telemetry_events,
-- trip_segments, battery_cycles, battery_cycle_sessions, insight_places,
-- journeys, session_costs, preferences, preference_proposals) allowed only
-- `authenticated` with `account_id = auth.uid()`. A car upload therefore
-- failed with 401/42501 even with a valid car_token and
-- CLOUD_SYNC_ENABLED=true — the gate being OFF hid the defect.
--
-- This migration gives the car (role `anon`) the grants + RLS it needs to
-- write its own telemetry/annotations via PostgREST, scoped by the device
-- token:
--   vehicle-scoped tables: vehicle_id = device vehicle_id AND
--                          account_id = device account_id
--   account-scoped tables: account_id = device account_id
--
-- INSERT uses WITH CHECK; UPDATE uses USING + WITH CHECK. Grants to `anon`
-- land alongside existing `authenticated`/`service_role` grants so a missing
-- policy still denies via RLS rather than via missing GRANT.

grant usage on schema public to anon;

grant select, insert, update on
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
  to anon;

grant select, insert, update, delete on
  public.insight_places,
  public.journeys,
  public.session_costs,
  public.preferences,
  public.preference_proposals
  to anon;

-- session
drop policy if exists session_device_writes on public.session;
create policy session_device_writes on public.session
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists session_device_updates on public.session;
create policy session_device_updates on public.session
  for update to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists session_device_reads on public.session;
create policy session_device_reads on public.session
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

-- interval
drop policy if exists interval_device_writes on public."interval";
create policy interval_device_writes on public."interval"
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists interval_device_updates on public."interval";
create policy interval_device_updates on public."interval"
  for update to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists interval_device_reads on public."interval";
create policy interval_device_reads on public."interval"
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

-- track
drop policy if exists track_device_writes on public.track;
create policy track_device_writes on public.track
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists track_device_updates on public.track;
create policy track_device_updates on public.track
  for update to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists track_device_reads on public.track;
create policy track_device_reads on public.track
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

-- battery_cycles
drop policy if exists battery_cycles_device_writes on public.battery_cycles;
create policy battery_cycles_device_writes on public.battery_cycles
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists battery_cycles_device_updates on public.battery_cycles;
create policy battery_cycles_device_updates on public.battery_cycles
  for update to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists battery_cycles_device_reads on public.battery_cycles;
create policy battery_cycles_device_reads on public.battery_cycles
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

-- battery_cycle_sessions
drop policy if exists battery_cycle_sessions_device_writes on public.battery_cycle_sessions;
create policy battery_cycle_sessions_device_writes on public.battery_cycle_sessions
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists battery_cycle_sessions_device_updates on public.battery_cycle_sessions;
create policy battery_cycle_sessions_device_updates on public.battery_cycle_sessions
  for update to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists battery_cycle_sessions_device_reads on public.battery_cycle_sessions;
create policy battery_cycle_sessions_device_reads on public.battery_cycle_sessions
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

-- telemetry_events
drop policy if exists telemetry_events_device_writes on public.telemetry_events;
create policy telemetry_events_device_writes on public.telemetry_events
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists telemetry_events_device_reads on public.telemetry_events;
create policy telemetry_events_device_reads on public.telemetry_events
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

-- trip_segments
drop policy if exists trip_segments_device_writes on public.trip_segments;
create policy trip_segments_device_writes on public.trip_segments
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists trip_segments_device_reads on public.trip_segments;
create policy trip_segments_device_reads on public.trip_segments
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

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
drop policy if exists session_costs_device_writes on public.session_costs;
create policy session_costs_device_writes on public.session_costs
  for insert to anon
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists session_costs_device_updates on public.session_costs;
create policy session_costs_device_updates on public.session_costs
  for update to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  )
  with check (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists session_costs_device_deletes on public.session_costs;
create policy session_costs_device_deletes on public.session_costs
  for delete to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );
drop policy if exists session_costs_device_reads on public.session_costs;
create policy session_costs_device_reads on public.session_costs
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
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

-- preference_proposals (legacy, keep for completeness)
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

-- vehicle + ownership: car reads its own row
drop policy if exists vehicle_ownership_device_reads on public.vehicle_ownership;
create policy vehicle_ownership_device_reads on public.vehicle_ownership
  for select to anon
  using (vehicle_id = (car_device_identity_from_header()->>'vehicle_id'));
drop policy if exists vehicle_device_reads on public.vehicle;
create policy vehicle_device_reads on public.vehicle
  for select to anon
  using (vehicle_id = (car_device_identity_from_header()->>'vehicle_id'));

notify pgrst, 'reload schema';
