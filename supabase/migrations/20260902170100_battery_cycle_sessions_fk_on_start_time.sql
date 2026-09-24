-- Migration: 20260902170000_battery_cycle_sessions_fk_on_start_time.sql
--
-- 20260831120000_battery_cycles_key_on_start_time.sql moved `battery_cycles`'
-- key to `(vehicle_id, start_utc_millis)` and dropped the foreign key from
-- `battery_cycle_sessions`, because the membership rows carry `cycle_ordinal`
-- but not the cycle's start time, and `(vehicle_id, cycle_ordinal)` stopped
-- being unique on the parent side. No client wrote that table at the time, so
-- the gap was left for whenever something starts.
--
-- Nothing writes `battery_cycle_sessions` yet, so this is additive: add the
-- column the reference needs, backfill it from any rows that already exist
-- (none are expected), then re-point the foreign key at the new key with its
-- cascade restored.

alter table public.battery_cycle_sessions
  add column if not exists cycle_start_utc_millis bigint;

update public.battery_cycle_sessions as s
set cycle_start_utc_millis = c.start_utc_millis
from public.battery_cycles as c
where s.cycle_start_utc_millis is null
  and c.vehicle_id = s.vehicle_id
  and c.ordinal = s.cycle_ordinal;

do $$
declare
  orphan record;
begin
  select count(*) as rows
  into orphan
  from public.battery_cycle_sessions
  where cycle_start_utc_millis is null;

  if orphan.rows > 0 then
    raise exception
      'battery_cycle_sessions holds % row(s) whose (vehicle_id, cycle_ordinal) '
      'no longer names a battery_cycles row, so cycle_start_utc_millis could '
      'not be backfilled. Resolve those rows before re-running this migration.',
      orphan.rows;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'battery_cycle_sessions_cycle_fkey'
      and conrelid = 'public.battery_cycle_sessions'::regclass
  ) then
    alter table public.battery_cycle_sessions
      add constraint battery_cycle_sessions_cycle_fkey
        foreign key (vehicle_id, cycle_start_utc_millis)
        references public.battery_cycles (vehicle_id, start_utc_millis)
        on delete cascade;
  end if;
end
$$;

notify pgrst, 'reload schema';
