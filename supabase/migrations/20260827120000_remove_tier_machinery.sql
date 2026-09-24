-- Remove the tier machinery that was never switched on.
--
-- What is removed, not replaced:
--   * the plan window in days (`plan_config`)
--   * the floor function that turns it into a timestamp (`detail_floor_millis`)
--   * the three windowed read policies that compare rows against that floor
--   * the monthly partition lifecycle built to drop what falls outside it
--
-- After this, no clock remains inside a row-level security policy. An owner
-- reads every row they own, at any age, on any tier; another account reads
-- none of them. The check is the ownership column and nothing else.
--
-- Independent of the `Track`: nothing blocks it and it blocks nothing.

-- ---------------------------------------------------------------------------
-- 1. The three windowed read policies become ownership checks and nothing else
-- ---------------------------------------------------------------------------

drop policy if exists sample_owner_reads_window on public.sample;
drop policy if exists telemetry_events_owner_reads_window on public.telemetry_events;
drop policy if exists trip_segments_owner_reads_window on public.trip_segments;

-- Recreate as ownership checks, the same shape every other measurement table
-- already uses (`session`, `interval`, `battery_cycles`). No clock.
--
-- The new names are dropped first as well. Without that, a re-run finds the
-- windowed policy already gone and the ownership policy already there, and
-- `create policy` fails on the name: the migration would run once and refuse
-- every time after, which is not what a `schema_full.sql` apply expects.

drop policy if exists sample_owner_reads on public.sample;
drop policy if exists telemetry_events_owner_reads on public.telemetry_events;
drop policy if exists trip_segments_owner_reads on public.trip_segments;

create policy sample_owner_reads on public.sample
  for select to authenticated
  using (account_id = (select auth.uid()));

create policy telemetry_events_owner_reads on public.telemetry_events
  for select to authenticated
  using (account_id = (select auth.uid()));

create policy trip_segments_owner_reads on public.trip_segments
  for select to authenticated
  using (account_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 2. The plan window table and the floor function are gone
-- ---------------------------------------------------------------------------

drop function if exists public.detail_floor_millis(uuid) cascade;

drop table if exists public.plan_config cascade;

-- `plan_config` carried its own RLS marker; once the table is gone the
-- `enable row level security` row in `pg_tables` disappears with it. The
-- `revoke` that followed it has nothing to revoke, but keep the intent
-- readable: no client token ever read or wrote the window.
-- (No separate `revoke` needed after `drop table cascade`.)

-- ---------------------------------------------------------------------------
-- 3. The monthly partition lifecycle is gone
-- ---------------------------------------------------------------------------
--
-- `sample` was `partition by range (t_utc_millis)` so that dropping a month
-- was dropping a partition. With no window to enforce, the cheapest correct
-- policy is to store everything, and partitioning no longer pays for itself.
-- Convert the table to a plain heap when it is still partitioned, otherwise
-- do nothing. This runs once, on deploy; the `pg_partitioned_table` guard and
-- the `IF EXISTS` drops keep it idempotent for `schema_full.sql` applies and
-- for a re-run.
--
-- The copy takes an ACCESS EXCLUSIVE lock first, and it has to.
--
-- `insert into ... select` alone takes ACCESS SHARE on the source, which does
-- not conflict with the ROW EXCLUSIVE an upload takes. A row written after the
-- select had its snapshot and before `drop table` runs would land in the old
-- table and be destroyed with it, without an error anywhere. The phone uploads
-- in pages, continuously, and the table is 326 585 rows and 182 MB, so the
-- window is not theoretical. The explicit lock closes it: uploads wait, and
-- the `42501`/`23503` guard in `SupabaseCloudSink` already treats a refused
-- write as a retry, not a loss.
--
-- It is the same lock `DROP INDEX` already took on this table (see
-- 20260826120000_drop_sample_session_key_idx.sql). The table that pays for
-- the cost is the one that used to cost ~195 MB a month for one car; after
-- the Track lands it is ~5 MB, of which `interval` is the majority.

do $$
begin
  if exists (
    select 1 from pg_partitioned_table
    where partrelid = 'public.sample'::regclass
  ) then
    -- Keep the definition readable: a plain table with the same columns, the
    -- same primary key, the same foreign key to `vehicle`, and RLS enabled.
    -- `LIKE ... INCLUDING ALL` copies defaults, constraints and indexes, but
    -- for a partitioned source it copies the *partitioned* shape, so build
    -- the replacement explicitly and copy rows.

    -- Nothing may write to the source between the copy and the drop.
    lock table public.sample in access exclusive mode;

    create table public.sample_new (
      vehicle_id text not null references public.vehicle (vehicle_id) on delete cascade,
      session_id text,
      account_id uuid not null,
      key text not null,
      t_utc_millis bigint not null,
      t_elapsed_nanos bigint not null,
      boot_count bigint,
      value double precision,
      validity text not null,
      group_id text,
      primary key (vehicle_id, key, t_utc_millis)
    );

    insert into public.sample_new
      select vehicle_id, session_id, account_id, key, t_utc_millis,
             t_elapsed_nanos, boot_count, value, validity, group_id
      from public.sample;

    -- Drop the partitioned parent; `cascade` drops every `partitions.*`
    -- leaf and the `sample_default` default partition with it.
    drop table public.sample cascade;

    alter table public.sample_new rename to sample;

    -- `rename to` renames the table and nothing else, so the primary key and
    -- the foreign key would keep the name Postgres gave them on the temporary
    -- table. The next migration that has to name a constraint will name
    -- `sample_pkey`, not `sample_new_pkey`.
    -- Guarded by name: a rename that misses would abort the whole migration
    -- on a live database, and the constraint name is cosmetic next to that.
    if exists (
      select 1 from pg_constraint where conname = 'sample_new_pkey'
    ) then
      alter table public.sample rename constraint sample_new_pkey to sample_pkey;
    end if;
    if exists (
      select 1 from pg_constraint where conname = 'sample_new_vehicle_id_fkey'
    ) then
      alter table public.sample
        rename constraint sample_new_vehicle_id_fkey to sample_vehicle_id_fkey;
    end if;

    create index if not exists sample_group_idx
      on public.sample (vehicle_id, group_id);

    alter table public.sample enable row level security;

    -- Policies on the old parent were dropped by `cascade`; recreate the
    -- two that survive: ownership read and ownership insert.
    drop policy if exists sample_owner_reads on public.sample;
    drop policy if exists sample_owner_uploads on public.sample;

    create policy sample_owner_reads on public.sample
      for select to authenticated
      using (account_id = (select auth.uid()));

    create policy sample_owner_uploads on public.sample
      for insert to authenticated
      with check (account_id = (select auth.uid()));

    grant select, insert on public.sample to authenticated, service_role;
  end if;
end $$;

-- Whatever path ran above, the lifecycle helpers are gone. `IF EXISTS`
-- keeps this safe to run when `sample` was already plain (e.g. a fresh
-- database from `schema_full.sql` after this lands).

drop function if exists public.ensure_sample_partition(date) cascade;

drop table if exists partitions.sample_default;

-- The partitions themselves are gone with the `drop table ... cascade` above
-- when conversion ran. On a fresh database there were never any leaves, so
-- dropping the helpers is the whole job. The `partitions` schema may stay
-- empty; nothing in the app knows its name any more, and PostgREST does not
-- expose it (see `schema_full.sql` grants). Keeping the empty schema costs
-- nothing and avoids a `drop schema` that would fail when a leaf still
-- lingers on a replica that has not yet run this migration.

-- Grants that belonged to the lifecycle, not to the table. The table's own
-- grants were recreated inside the conversion block above; these two would
-- otherwise be left pointing at a function and a default partition that no
-- longer exist.
-- (No additional revoke/grant needed; `cascade` removed them.)
