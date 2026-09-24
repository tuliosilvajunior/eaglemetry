-- Migration: 20260902170000_phone_cutover_readiness.sql
--
-- Phase 4 Finding 2 — phone cutover readiness cloud signal.
--
-- The car's evaluator hardcodes phone conditions (phoneOutboxCount=0,
-- migrationCompleted=true) because the phone's outbox + migration state are
-- not locally observable from the car. The car can retire while the phone
-- still holds undelivered outbox rows. This table gives the car a real
-- signal for the phone's side of cutover.
--
-- Writer model: phone only (authenticated, account_id = auth.uid()),
-- scoped to a vehicle it owns. Car only reads (anon + x-car-token).
-- One row per (account_id, vehicle_id) — last writer wins via upsert.
--
-- RLS follows the already-established idiom:
--   phone: to authenticated + auth.uid() + vehicle_ownership check
--   car:   to anon + car_device_identity_from_header()->>'vehicle_id'
-- Grants expose the refusal via RLS, not via missing grant (standing rule).

create table if not exists public.phone_cutover_readiness (
  account_id uuid not null references auth.users (id) on delete cascade,
  vehicle_id text not null,
  phone_outbox_count integer not null check (phone_outbox_count >= 0),
  migration_completed boolean not null,
  updated_at_utc_millis bigint not null,
  primary key (account_id, vehicle_id)
);

create index if not exists phone_cutover_readiness_vehicle_idx
  on public.phone_cutover_readiness (vehicle_id);

alter table public.phone_cutover_readiness enable row level security;

grant usage on schema public to anon, authenticated, service_role;

-- Phone reads its own readiness rows.
drop policy if exists phone_cutover_readiness_owner_reads on public.phone_cutover_readiness;
create policy phone_cutover_readiness_owner_reads on public.phone_cutover_readiness
  for select to authenticated
  using (account_id = (select auth.uid()));

-- Phone writes (insert) a readiness row for a vehicle it currently owns.
drop policy if exists phone_cutover_readiness_owner_writes on public.phone_cutover_readiness;
create policy phone_cutover_readiness_owner_writes on public.phone_cutover_readiness
  for insert to authenticated
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = phone_cutover_readiness.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

-- Phone updates its own readiness row (same ownership check, idempotent upsert).
drop policy if exists phone_cutover_readiness_owner_updates on public.phone_cutover_readiness;
create policy phone_cutover_readiness_owner_updates on public.phone_cutover_readiness
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = phone_cutover_readiness.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

-- Car reads the readiness for its own vehicle (scoped by device token).
drop policy if exists phone_cutover_readiness_device_reads on public.phone_cutover_readiness;
create policy phone_cutover_readiness_device_reads on public.phone_cutover_readiness
  for select to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

-- Grants: expose refusals via RLS, not missing grant.
grant select, insert, update on public.phone_cutover_readiness to authenticated;
grant select, insert, update on public.phone_cutover_readiness to anon;
grant select, insert, update on public.phone_cutover_readiness to service_role;

notify pgrst, 'reload schema';
