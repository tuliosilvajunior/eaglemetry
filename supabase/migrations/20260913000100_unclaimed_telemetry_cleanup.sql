-- Migration: 20260913000100_unclaimed_telemetry_cleanup.sql
-- Phase 5 Wave 5.1 (P5-T3) — D2 cleanup RPC (drafted, disabled pending decision D2).
-- Purges orphan/unclaimed telemetry rows (account_id IS NULL) older than retention window.

create or replace function public.cleanup_unclaimed_telemetry(
  p_retention_days integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cutoff_timestamp timestamptz;
  v_cutoff_millis bigint;
  v_intervals_deleted integer := 0;
  v_tracks_deleted integer := 0;
  v_events_deleted integer := 0;
  v_segments_deleted integer := 0;
  v_cycles_deleted integer := 0;
  v_costs_deleted integer := 0;
  v_sessions_deleted integer := 0;
  v_devices_deleted integer := 0;
  v_pairing_sessions_deleted integer := 0;
  v_reg_attempts_deleted integer := 0;
begin
  if p_retention_days < 1 then
    raise exception 'Retention days must be at least 1 day';
  end if;

  v_cutoff_timestamp := now() - (p_retention_days || ' days')::interval;
  v_cutoff_millis := (extract(epoch from v_cutoff_timestamp) * 1000)::bigint;

  -- 1. Dependent measurement tables (intervals, tracks, events, segments, cycles, costs)
  delete from public."interval"
   where account_id is null
     and start_utc_millis < v_cutoff_millis;
  get diagnostics v_intervals_deleted = row_count;

  delete from public.track
   where account_id is null
     and updated_at_utc_millis < v_cutoff_millis;
  get diagnostics v_tracks_deleted = row_count;

  delete from public.telemetry_events
   where account_id is null
     and occurred_at_utc_millis < v_cutoff_millis;
  get diagnostics v_events_deleted = row_count;

  delete from public.trip_segments
   where account_id is null
     and start_utc_millis < v_cutoff_millis;
  get diagnostics v_segments_deleted = row_count;

  delete from public.battery_cycles
   where account_id is null
     and start_utc_millis < v_cutoff_millis;
  get diagnostics v_cycles_deleted = row_count;

  delete from public.session_costs
   where account_id is null
     and updated_at_utc_millis < v_cutoff_millis;
  get diagnostics v_costs_deleted = row_count;

  -- 2. Sessions: only delete sessions whose start is older than cutoff and account_id is null
  delete from public.session
   where account_id is null
     and started_at_utc_millis < v_cutoff_millis;
  get diagnostics v_sessions_deleted = row_count;

  -- 3. Stale unclaimed vehicle devices
  delete from public.vehicle_devices
   where account_id is null
     and created_at < v_cutoff_timestamp;
  get diagnostics v_devices_deleted = row_count;

  -- 4. Expired and terminal pairing sessions
  delete from public.device_pairing_sessions
   where (status in ('approved', 'rejected', 'expired') or expires_at < v_cutoff_timestamp)
     and created_at < v_cutoff_timestamp;
  get diagnostics v_pairing_sessions_deleted = row_count;

  -- 5. Old registration attempts (fixed 7-day retention)
  delete from public.device_registration_attempts
   where attempted_at < now() - interval '7 days';
  get diagnostics v_reg_attempts_deleted = row_count;

  return jsonb_build_object(
    'retention_days', p_retention_days,
    'cutoff_timestamp', v_cutoff_timestamp,
    'intervals_deleted', v_intervals_deleted,
    'tracks_deleted', v_tracks_deleted,
    'events_deleted', v_events_deleted,
    'segments_deleted', v_segments_deleted,
    'cycles_deleted', v_cycles_deleted,
    'costs_deleted', v_costs_deleted,
    'sessions_deleted', v_sessions_deleted,
    'devices_deleted', v_devices_deleted,
    'pairing_sessions_deleted', v_pairing_sessions_deleted,
    'registration_attempts_deleted', v_reg_attempts_deleted
  );
end;
$$;

revoke all on function public.cleanup_unclaimed_telemetry(integer) from public, anon, authenticated;
grant execute on function public.cleanup_unclaimed_telemetry(integer) to service_role;

-- NOTE: pg_cron scheduled invocation is DRAFTED and DISABLED by default pending decision D2
-- (tracked in backlog task gb236-unclaimed-lifecycle).
-- To enable in production:
-- select cron.schedule('cleanup-unclaimed-telemetry', '0 3 * * *', 'select public.cleanup_unclaimed_telemetry(30);');
