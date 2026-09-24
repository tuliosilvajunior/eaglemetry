-- Migration: 20260902160000_lane_c_tiebreak_fix.sql
--
-- Lane C fix pass — M-1 (tiebreak) + L-2 (doc alignment)
--
-- M-1: the status view's `reported_latest` CTE previously ordered by
-- `reported_at_utc_millis desc` alone. When the car uploads a batch of
-- offline decisions stamped with one `now()` for the whole sync pass
-- (PreferenceControlSync.kt:103), two decisions for the same
-- (vehicle_id, key) can share `reported_at`. DISTINCT ON with a single
-- sort key then picks an arbitrary row — reproduced live picking the
-- OLDER decision, contradicting the car's own decided_at ordering.
-- Fix: add `decided_at_utc_millis desc` as the tiebreak, so the car's
-- actual decision time governs. Preserves all non-tie behavior.
--
-- L-2: the 20260902150000 migration comment claimed the re-send used
-- `ON CONFLICT DO UPDATE SET reported_at`. The real client
-- (PreferenceControlCloud.kt:218) sends
-- `Prefer: resolution=ignore-duplicates` (DO NOTHING), leaving the stored
-- row and its reported_at untouched — the safer behavior. This migration
-- documents that accurately and replaces the view with the corrected
-- ordering. The `preference_reported_device_updates` UPDATE policy from
-- 20260902150000 is retained as a harmless no-op (the client never
-- exercises it); dropping it would be a no-op migration with no benefit
-- and is left for a future cleanup if desired.

create or replace view public.preference_control_status
with (security_invoker = true)
as
with desired_latest as (
  select distinct on (vehicle_id, key)
    vehicle_id,
    account_id,
    key,
    value,
    proposed_at_utc_millis
  from public.preference_desired
  order by vehicle_id, key, proposed_at_utc_millis desc
),
reported_latest as (
  select distinct on (vehicle_id, key)
    vehicle_id,
    account_id,
    key,
    value,
    status,
    decided_at_utc_millis,
    reported_at_utc_millis
  from public.preference_reported
  order by vehicle_id, key, reported_at_utc_millis desc, decided_at_utc_millis desc
)
select
  coalesce(d.vehicle_id, r.vehicle_id) as vehicle_id,
  coalesce(d.account_id, r.account_id) as account_id,
  coalesce(d.key, r.key) as key,
  d.value as desired_value,
  d.proposed_at_utc_millis,
  r.value as reported_value,
  r.status as reported_status,
  r.decided_at_utc_millis,
  r.reported_at_utc_millis,
  case
    when d.key is null then 'reported_only'
    when r.key is null then 'pending'
    when d.proposed_at_utc_millis > r.decided_at_utc_millis then 'stale'
    when r.status = 'accepted' and r.value is not distinct from d.value then 'confirmed'
    else 'refused'
  end as status
from desired_latest d
full outer join reported_latest r
  on d.vehicle_id = r.vehicle_id and d.key = r.key;

-- Grants and RLS are unchanged; the view remains read-only with no
-- INSTEAD OF triggers (never auto-merge).
grant select on public.preference_control_status to anon, authenticated, service_role;

notify pgrst, 'reload schema';
