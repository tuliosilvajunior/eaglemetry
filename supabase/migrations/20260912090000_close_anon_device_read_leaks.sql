-- Migration: 20260912090000_close_anon_device_read_leaks.sql
--
-- gb236 scout finding L2: a car authenticated with ANY credential for a
-- vehicle could read the `preference_desired` / `preference_reported` rows
-- written by a DIFFERENT account on that same vehicle (charge target SOC,
-- `default_charge_cost_per_kwh` — the owner's charging habits and electricity
-- cost). Proven empirically on scratch Postgres and closed here.
--
-- The gap was asymmetric and read-only: the write policies already required
-- both halves of the token identity, and the sibling table
-- `phone_cutover_readiness` already carried the correct account bound. These
-- five `anon` SELECT policies were scoped by the token's `vehicle_id` alone:
--
--   preference_desired_device_reads    (20260902150000 — Lane C)
--   preference_reported_device_reads   (20260902150000 — Lane C)
--   vehicle_devices_device_reads       (20260901130000 — car self-check)
--   vehicle_ownership_device_reads     (20260901130000 — car reads own row)
--   vehicle_device_reads               (20260901130000 — car reads own row)
--
-- Each is tightened to the exact predicate
-- `phone_cutover_readiness_device_reads` (20260902170000) already uses:
-- the token's vehicle AND the token's account must equal the row's. The
-- remaining anon SELECT policies in the schema already carry an account bound
-- (measurements use `is not distinct from` to keep the pre-claim NULL path,
-- annotations use `= ... ::uuid`), so this is the complete sweep.
--
-- Post-claim behaviour on a shared vehicle: a car reading its OWN account's
-- rows still works — that is the control plane's whole point. After a real
-- transfer the seller's credential is revoked (identity resolves to NULL),
-- and the buyer's post-claim rows carry the buyer's account, so nothing that
-- should be readable is cut off. A vehicle carrying two live credentials of
-- DIFFERENT accounts (the state the gb236 scout tested, and the only state
-- where the old predicates leaked) now returns zero of the other account's
-- rows. Rows written before this migration under the old owner keep the old
-- owner's account_id and stay invisible to the new one, matching the
-- transfer semantics of 20260911120000 (history stays with the account that
-- wrote it).

drop policy if exists preference_desired_device_reads on public.preference_desired;
create policy preference_desired_device_reads on public.preference_desired
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists preference_reported_device_reads on public.preference_reported;
create policy preference_reported_device_reads on public.preference_reported
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists vehicle_devices_device_reads on public.vehicle_devices;
create policy vehicle_devices_device_reads on public.vehicle_devices
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

drop policy if exists vehicle_ownership_device_reads on public.vehicle_ownership;
create policy vehicle_ownership_device_reads on public.vehicle_ownership
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

drop policy if exists vehicle_device_reads on public.vehicle;
create policy vehicle_device_reads on public.vehicle
  for select to anon
  using (
    vehicle_id = (car_device_identity_from_header()->>'vehicle_id')
    and account_id = (car_device_identity_from_header()->>'account_id')::uuid
  );

notify pgrst, 'reload schema';