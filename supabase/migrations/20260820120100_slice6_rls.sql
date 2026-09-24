-- Slice 6, phase C: the tier boundary.
--
-- **The tier is RLS and nothing else.** The publishable key is compiled into
-- the phone binary and is meant to ship in a client, so anyone can read it out
-- of the package and call PostgREST directly. A restriction written in Flutter
-- is not a restriction. Everything that decides what an account may read is in
-- this file.
--
-- Two rules:
--
--   * the window applies to `sample`, `telemetry_events` and the route, and
--     **never** to `session` or `interval`. The history list and every minute
--     chart are readable by any account. What is sold is the detail under them,
--     because that is what actually costs: about 700 MB a year against 10 for
--     the layers above it;
--   * a measurement is never edited and never tombstoned. It is inserted once
--     and, for the two tables that grow while a session is open, updated by its
--     owner. An annotation is the opposite: it is edited from both sides, and
--     it carries a tombstone so a stale replica cannot resurrect a deletion.

alter table public.vehicle enable row level security;
alter table public.session enable row level security;
alter table public."interval" enable row level security;
alter table public.sample enable row level security;
alter table public.telemetry_events enable row level security;
alter table public.trip_segments enable row level security;
alter table public.battery_cycles enable row level security;
alter table public.battery_cycle_sessions enable row level security;
alter table public.insight_places enable row level security;
alter table public.session_costs enable row level security;
alter table public.preferences enable row level security;
alter table public.preference_proposals enable row level security;

-- No policy at all, on purpose. The service role bypasses RLS, so the payment
-- webhook still writes them and no client token can read or write either.
alter table public.entitlement enable row level security;
alter table public.plan_config enable row level security;

-- ---------------------------------------------------------------------------
-- The vehicle
-- ---------------------------------------------------------------------------

create policy vehicle_owner_reads on public.vehicle
  for select to authenticated
  using (account_id = (select auth.uid()));

create policy vehicle_owner_claims on public.vehicle
  for insert to authenticated
  with check (account_id = (select auth.uid()));

create policy vehicle_owner_renames on public.vehicle
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- The layers no tier hides: the session list, the totals, the minute charts
-- ---------------------------------------------------------------------------

create policy session_owner_reads on public.session
  for select to authenticated
  using (account_id = (select auth.uid()));

create policy session_owner_uploads on public.session
  for insert to authenticated
  with check (account_id = (select auth.uid()));

-- An open session grows: it closes, it gains a rollup, it gains an end SOC.
-- The upload is idempotent on (vehicle_id, id), so the second upload of the
-- same session is an UPDATE of the row already there.
create policy session_owner_completes on public.session
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

create policy interval_owner_reads on public."interval"
  for select to authenticated
  using (account_id = (select auth.uid()));

create policy interval_owner_uploads on public."interval"
  for insert to authenticated
  with check (account_id = (select auth.uid()));

create policy interval_owner_completes on public."interval"
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

create policy battery_cycles_owner_reads on public.battery_cycles
  for select to authenticated
  using (account_id = (select auth.uid()));

create policy battery_cycles_owner_uploads on public.battery_cycles
  for insert to authenticated
  with check (account_id = (select auth.uid()));

create policy battery_cycles_owner_completes on public.battery_cycles
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

create policy battery_cycle_sessions_owner_reads on public.battery_cycle_sessions
  for select to authenticated
  using (account_id = (select auth.uid()));

create policy battery_cycle_sessions_owner_uploads on public.battery_cycle_sessions
  for insert to authenticated
  with check (account_id = (select auth.uid()));

create policy battery_cycle_sessions_owner_completes on public.battery_cycle_sessions
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- The detail: what the window applies to
-- ---------------------------------------------------------------------------
--
-- The row must be the account's **and** inside the window. A free account
-- calling PostgREST directly with the shipped key and its own token reads
-- nothing older, because the floor is computed server-side from a table the
-- account cannot write.
--
-- Uploading is not reading: an account may always insert its own detail, even
-- for an instant it may not read back. Otherwise a lapsed subscription would
-- make the phone unable to hand over what it holds.

create policy sample_owner_reads_window on public.sample
  for select to authenticated
  using (
    account_id = (select auth.uid())
    and t_utc_millis >= public.detail_floor_millis((select auth.uid()))
  );

create policy sample_owner_uploads on public.sample
  for insert to authenticated
  with check (account_id = (select auth.uid()));

create policy telemetry_events_owner_reads_window on public.telemetry_events
  for select to authenticated
  using (
    account_id = (select auth.uid())
    and occurred_at_utc_millis >= public.detail_floor_millis((select auth.uid()))
  );

create policy telemetry_events_owner_uploads on public.telemetry_events
  for insert to authenticated
  with check (account_id = (select auth.uid()));

create policy trip_segments_owner_reads_window on public.trip_segments
  for select to authenticated
  using (
    account_id = (select auth.uid())
    and start_utc_millis >= public.detail_floor_millis((select auth.uid()))
  );

create policy trip_segments_owner_uploads on public.trip_segments
  for insert to authenticated
  with check (account_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- The annotations: read, write, edit and tombstone, always the owner's
-- ---------------------------------------------------------------------------

create policy insight_places_owner_all on public.insight_places
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

create policy session_costs_owner_all on public.session_costs
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

create policy preferences_owner_all on public.preferences
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

create policy preference_proposals_owner_all on public.preference_proposals
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
--
-- RLS decides which rows. The grants decide which verbs exist at all, and a
-- measurement has no DELETE for anyone but the service role: retention is
-- `pg_cron` dropping a partition, not a client deleting rows.

grant select, insert, update on
  public.vehicle,
  public.session,
  public."interval",
  public.battery_cycles,
  public.battery_cycle_sessions
  to authenticated;

grant select, insert on
  public.sample,
  public.telemetry_events,
  public.trip_segments
  to authenticated;

grant select, insert, update, delete on
  public.insight_places,
  public.session_costs,
  public.preferences,
  public.preference_proposals
  to authenticated;

revoke all on public.entitlement from authenticated, anon;
revoke all on public.plan_config from authenticated, anon;
