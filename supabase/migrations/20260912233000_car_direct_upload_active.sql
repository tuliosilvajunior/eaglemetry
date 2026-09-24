-- Migration: 20260912233000_car_direct_upload_active.sql
--
-- Phase 4 Wave 4.1 (P4-T2) — Cutover-signal migration.
-- Adds `car_direct_upload_active` to `public.phone_cutover_readiness` and
-- mirrors device policies so the car can insert and update the cutover flag
-- as `anon` with `x-car-token`.

alter table public.phone_cutover_readiness
  add column if not exists car_direct_upload_active boolean not null default false;

alter table public.phone_cutover_readiness
  alter column phone_outbox_count set default 0;

alter table public.phone_cutover_readiness
  alter column migration_completed set default false;

-- Car writes (insert) readiness for its own vehicle (scoped by device token).
drop policy if exists phone_cutover_readiness_device_writes on public.phone_cutover_readiness;
create policy phone_cutover_readiness_device_writes on public.phone_cutover_readiness
  for insert to anon
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

-- Car updates readiness for its own vehicle (scoped by device token).
drop policy if exists phone_cutover_readiness_device_updates on public.phone_cutover_readiness;
create policy phone_cutover_readiness_device_updates on public.phone_cutover_readiness
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  )
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

notify pgrst, 'reload schema';
