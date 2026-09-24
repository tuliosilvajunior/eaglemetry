-- Migration: 20260902150000_preference_control_lane_c.sql
--
-- Phase 3 (Lane C — control) Step 1b — the control-plane tables and the
-- join view, on top of Step 1a's car device-token identity
-- (`public.car_device_identity_from_header()`).
--
-- Lane C from issue #227: the phone writes what it *wants* for a control
-- key; the car writes what it *does*. These are different facts written by
-- different devices, and — per the issue — this lane must never auto-merge.
-- The issue decides the shape up front: "two tables — desired and reported
-- — joined by a view. Column-level RLS is explicitly rejected as fragile
-- and unreadable."
--
-- Why two *new* tables instead of reusing the existing `preference_proposals`:
-- that table is the annotation-lane shape — one row carrying BOTH the phone's
-- proposal fields (value, proposed_at) and the car's decision fields (status,
-- decided_at) under a single `preference_proposals_owner_all` policy. On one
-- row, the phone's write and the car's write are the same row, so the only
-- ways to keep the single-writer boundary are (a) let the writer of the row
-- rewrite the other side's decision, which breaks "only the car's acceptance
-- is a write", or (b) column-level RLS, which #227 explicitly rejected.
-- Lane C therefore gets a dedicated pair of tables, each with exactly one
-- writer, and a view that is the only place the two are combined.
--
-- Writer model (mirrors the "one writer per fact" rule from the issue):
--
--   * `preference_desired`  — written ONLY by the phone (role `authenticated`,
--     `account_id = auth.uid()`), read by phone and car. Exactly one writer,
--     so no merge machinery: upsert-by-key on `(account_id, vehicle_id, key)`.
--     This table needs no HLC because there is no second writer to converge.
--   * `preference_reported` — written ONLY by the car (role `anon`, scoped by
--     `car_device_identity_from_header()`), read by phone and car. Write-once
--     per decision: one row per `(vehicle_id, key, decided_at_utc_millis)`.
--     The car is the sole writer here too; no HLC.
--   * `preference_control_status` — a view joining `desired` + `reported` per
--     `(vehicle_id, key)`, deriving `pending` / `confirmed` / `stale` /
--     `refused` / `reported_only`. It is what both read paths query; the
--     "never show applied before the car decided" rule lives here, in one
--     place, never in client joins.
--
-- View security model, deliberately:
--
-- The view is created with `security_invoker = true`. A plain view runs with
-- the privileges of its owner (the migration is run by a superuser), so
-- WITHOUT `security_invoker` any car token — or the phone — could read every
-- vehicle's rows through the view straight past RLS: a fault that is silent
-- when it fails. With `security_invoker = true`, every query on the view is
-- evaluated with the *querying role's* privileges and RLS on the underlying
-- tables, so a device request (`anon`, token for veh-A) sees only veh-A's
-- desired/reported rows and the phone (`authenticated`) sees only its own
-- account's rows. Postgres 15+; Supabase runs 15+.
--
-- Reference: Step 1a's report (`data/gb227-p3-s1a/report.md`) — the transport
-- contract and the exact RLS idiom this migration uses: `to anon` + the
-- device-identity function for the car, `to authenticated` + `auth.uid()` for
-- the phone, and `WITH CHECK` (not `USING`) on INSERT policies.

-- ---------------------------------------------------------------------------
-- 1. preference_desired — what the phone wants, written only by the phone
-- ---------------------------------------------------------------------------

create table if not exists public.preference_desired (
  account_id uuid not null references auth.users (id) on delete cascade,
  vehicle_id text not null,
  key text not null,
  value text,
  proposed_at_utc_millis bigint not null,
  origin text not null,
  primary key (account_id, vehicle_id, key)
);

-- The car and the join view look up by vehicle, never by account.
create index if not exists preference_desired_vehicle_key_idx
  on public.preference_desired (vehicle_id, key);

-- ---------------------------------------------------------------------------
-- 2. preference_reported — what the car actually did, written only by the car
-- ---------------------------------------------------------------------------

create table if not exists public.preference_reported (
  vehicle_id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  key text not null,
  value text,
  status text not null check (status in ('accepted', 'refused')),
  decided_at_utc_millis bigint not null,
  reported_at_utc_millis bigint not null,
  primary key (vehicle_id, key, decided_at_utc_millis)
);

-- The phone reads reported for its account; the join view picks the latest
-- decision per (vehicle_id, key).
create index if not exists preference_reported_account_vehicle_key_idx
  on public.preference_reported (account_id, vehicle_id, key, reported_at_utc_millis desc);

-- ---------------------------------------------------------------------------
-- 3. preference_control_status — the view both sides read
-- ---------------------------------------------------------------------------

-- `security_invoker = true`: see the header. Underlying tables keep their
-- own RLS, so a device (`anon`) sees only its own vehicle's rows and the
-- phone (`authenticated`) only its own account's rows — even through the
-- view.

drop view if exists public.preference_control_status;
create view public.preference_control_status
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
  order by vehicle_id, key, reported_at_utc_millis desc
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
    -- A decision the car recorded for a key the phone has not (re)proposed:
    -- the car runs this value; there is nothing to compare it to.
    when d.key is null then 'reported_only'
    -- The phone wants a value the car has not decided on yet.
    when r.key is null then 'pending'
    -- The phone proposed again after the car's last decision: the report
    -- predates the current desire, so even a matching value is NOT applied
    -- to *this* proposal. Never auto-merge.
    when d.proposed_at_utc_millis > r.decided_at_utc_millis then 'stale'
    -- The car accepted, and the accepted value equals the desired value.
    -- "reported matches desired".
    when r.status = 'accepted' and r.value is not distinct from d.value then 'confirmed'
    -- The car recorded a decision that does not confirm the current desire:
    -- it refused, or it accepted a different value than the phone asked for.
    else 'refused'
  end as status
from desired_latest d
full outer join reported_latest r
  on d.vehicle_id = r.vehicle_id and d.key = r.key;

-- The phone may not change another side's row; the car only ever reports.
-- No INSTEAD OF triggers exist: the view is read-only for every role, which
-- is exactly the "never auto-merge" guarantee — the two writers meet only
-- inside the view's derivation.

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------

alter table public.preference_desired enable row level security;
alter table public.preference_reported enable row level security;

-- required by the view's `security_invoker` reads
grant usage on schema public to anon, authenticated, service_role;

-- --- preference_desired: the phone owns the whole row -----------------------

-- Phone reads its own account's desires.
create policy preference_desired_owner_reads on public.preference_desired
  for select to authenticated
  using (account_id = (select auth.uid()));

-- The car reads the desires for its own vehicle (it must, to display what the
-- phone is asking).
create policy preference_desired_device_reads on public.preference_desired
  for select to anon
  using (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

-- Phone writes a desire for a vehicle it currently owns. The ownership check
-- closes the hole where the phone's own lane is scoped by account but a car
-- reads by vehicle: without it, account A could plant a desired row for
-- vehicle B (owned by account B), and vehicle B's car — which reads by its
-- own vehicle_id — would see a control suggestion its owner never made.
create policy preference_desired_owner_writes on public.preference_desired
  for insert to authenticated
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = preference_desired.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

-- The same row is upsert-by-key (the phone proposes again for the same
-- key/vehicle). `USING` + `WITH CHECK` keep it an owner-only rewrite.
create policy preference_desired_owner_updates on public.preference_desired
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (
    account_id = (select auth.uid())
    and exists (
      select 1 from public.vehicle_ownership vo
      where vo.vehicle_id = preference_desired.vehicle_id
        and vo.account_id = (select auth.uid())
        and vo.revoked_at is null
    )
  );

-- --- preference_reported: the car owns the whole row ------------------------

-- The car writes its decision scoped to the vehicle its token resolves to,
-- and to the account that vehicle belongs to. `WITH CHECK`, not `USING`:
-- an INSERT policy rejects `USING` outright.
create policy preference_reported_device_writes on public.preference_reported
  for insert to anon
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

-- Idempotent re-send: the car re-uploading the same decision (same vehicle,
-- key, decided_at_utc_millis) is sent with `Prefer:
-- resolution=ignore-duplicates` (ON CONFLICT DO NOTHING), so the stored row
-- and its `reported_at` are left untouched. The UPDATE policy below is
-- retained as a harmless no-op for forward compatibility.
create policy preference_reported_device_updates on public.preference_reported
  for update to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  )
  with check (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and car_device_identity_from_header()->>'account_id' = account_id::text
  );

-- The car reads its own vehicle's reports.
create policy preference_reported_device_reads on public.preference_reported
  for select to anon
  using (car_device_identity_from_header()->>'vehicle_id' = vehicle_id);

-- The phone reads the reports of its own account (the confirmed values it is
-- allowed to show).
create policy preference_reported_owner_reads on public.preference_reported
  for select to authenticated
  using (account_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
--
-- Grant-set notes:
--   * `authenticated` gets INSERT/UPDATE on `preference_reported` and `anon`
--     gets INSERT/UPDATE on `preference_desired` ONLY so the negative cases
--     are refused by an RLS policy, not by a missing grant — the repo's
--     standing rule: a boundary proven by RLS, not by client good manners.
--     Neither role has a matching policy, so both writes are still denied.

grant select, insert, update on public.preference_desired to authenticated;
grant select, insert, update on public.preference_reported to authenticated;
grant select, insert, update on public.preference_desired to anon;
grant select, insert, update on public.preference_reported to anon;
grant select, insert, update on public.preference_desired to service_role;
grant select, insert, update on public.preference_reported to service_role;

grant select on public.preference_control_status to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Tell PostgREST
-- ---------------------------------------------------------------------------

notify pgrst, 'reload schema';