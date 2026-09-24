-- Migration: 20260830220000_track_table_and_missing_measure_columns.sql
--
-- The cloud schema fell behind the car on three measurement streams, and the
-- phone's upload has been refused ever since.
--
-- The uploader sends every key the car's row carries, snake_cased
-- (`CloudUploader._row`). It holds no allow-list, on purpose: a column added to
-- a measurement is a column the cloud must carry, and a list here would let the
-- two drift quietly. They drifted anyway, because nothing failed until the
-- phone tried to upload:
--
--   * `session` — the car has sent `climbM`, `descentM` and `fixCount` since
--     the Track landed (51fa1e55). PostgREST answered PGRST204 and refused the
--     whole page of 215 sessions, which then kept its dirty mark and retried
--     for ever;
--   * `interval` — the same, for `startSoc`, `endSoc`, `startVoltage` and
--     `endVoltage`;
--   * `track` — the route is one row per session since issue 173 slice 5, and
--     this table was never created. The upload names `public.track`, so it was
--     answered PGRST205 rather than 204.
--
-- `public.trip_segments` is the route as it was drawn before: many rows per
-- session, uploaded by a build that no longer exists. It is left alone here.
-- Dropping it is a separate decision, and it holds real history.
--
-- Every statement is additive. Nothing is dropped and no row is rewritten.

-- ---------------------------------------------------------------------------
-- 1. The session's climb, descent and fix count
--
-- Summed once from the Track when the session closes, so they are null for a
-- session that is still open and for every session recorded before the Track.
-- `fix_count` of zero is a drive the GNSS never fixed, which is not the same
-- fact as a null.

alter table public.session
  add column if not exists climb_m double precision default null,
  add column if not exists descent_m double precision default null,
  add column if not exists fix_count bigint default null;

-- ---------------------------------------------------------------------------
-- 2. The minute's state of charge and pack voltage
--
-- Nullable, and they must stay nullable: a minute the pack did not report
-- carries neither, and the charge curves are drawn from the minutes that do.

alter table public."interval"
  add column if not exists start_soc double precision default null,
  add column if not exists end_soc double precision default null,
  add column if not exists start_voltage double precision default null,
  add column if not exists end_voltage double precision default null;

-- ---------------------------------------------------------------------------
-- 3. The route, as one row per session
--
-- `t`, `speed` and `alt` are JSON arrays of integers holding exactly
-- `point_count` entries each; `path` is the same positions as a Google
-- polyline at 1e5. The car refuses a short array on decode rather than drawing
-- a shifted map, so the four are only ever read together.
--
-- The row is rewritten every minute while the session runs, holding the points
-- raw, and replaced once at close with the simplified path. That is why the
-- table takes an UPDATE policy and a grant to match: the phone upserts it with
-- merge, and the later version has to replace the earlier one.

create table if not exists public.track (
  vehicle_id text not null,
  session_id text not null,
  account_id uuid not null,
  encoding_version bigint not null,
  point_count bigint not null,
  t text not null,
  path text not null,
  speed text not null,
  alt text not null,
  updated_at_utc_millis bigint not null,
  uploaded_at timestamptz not null default now(),
  primary key (vehicle_id, session_id),
  foreign key (vehicle_id, session_id)
    references public.session (vehicle_id, id) on delete cascade
);

create index if not exists track_account_updated_idx
  on public.track (account_id, updated_at_utc_millis desc);

-- ---------------------------------------------------------------------------
-- 4. The tier boundary
--
-- The publishable key ships inside the phone binary, so anything that decides
-- what an account may read lives in RLS and nowhere else. The route follows
-- the same owner rule as every other measurement: read, insert and update your
-- own rows, and nobody else's.

alter table public.track enable row level security;

drop policy if exists track_owner_reads on public.track;
create policy track_owner_reads on public.track
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists track_owner_uploads on public.track;
create policy track_owner_uploads on public.track
  for insert to authenticated
  with check (account_id = (select auth.uid()));

-- The route grows while the session is open and settles at close, so the
-- second write of the same session is an UPDATE of the row already there.
drop policy if exists track_owner_completes on public.track;
create policy track_owner_completes on public.track
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

grant select, insert, update on public.track to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Tell PostgREST
--
-- PGRST204 and PGRST205 are both answered from a cached schema. Supabase
-- reloads it on DDL by itself, but the reload is what makes this migration
-- take effect, so it is asked for here rather than assumed.

notify pgrst, 'reload schema';
