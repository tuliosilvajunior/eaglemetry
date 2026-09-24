-- Migration: 20260902190200_service_role_grants.sql
--
-- Service_role could not read/write session/vehicle via PostgREST
-- (42501 permission denied) — slice-6 RLS granted only to `authenticated`.
-- service_role bypasses RLS but still needs GRANTs. schema_full.sql lists
-- them but they were never pushed as a migration. Add them idempotently.
-- Also fixes missing grants that blocked verification account setup.

grant usage on schema public to service_role;

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
  public.journeys,
  public.session_costs,
  public.preferences,
  public.preference_proposals
  to service_role;

-- vehicle_ownership / vehicle_devices already have service_role grants in prior
-- migrations; repeat idempotently.
grant select, insert, update on public.vehicle_ownership to service_role;
grant select, insert, update on public.vehicle_devices to service_role;
grant all on public.device_pairing_sessions to service_role;
grant all on public.pairing_claim_attempts to service_role;

notify pgrst, 'reload schema';
