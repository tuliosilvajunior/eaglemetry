-- Slice 6, phase C: make an account deletion take the detail with it.
--
-- The first migration gave `session`, `interval`, `trip_segments` and
-- `battery_cycles` a foreign key that reaches `vehicle`, and `vehicle` cascades
-- from `auth.users`. `sample` and `telemetry_events` had none. Deleting an
-- account therefore removed the sessions and left the two largest detail tables
-- behind, holding rows nothing pointed at any more — and `sample` is where the
-- latitude and longitude live, which is the part of this database that names
-- where a person lives.
--
-- Found by the curl verification on 2026-08-20, not by reading the file: the
-- test account's rows were the ones that would have stayed.
--
-- `session_id` is not the parent here. It is nullable by the back-stamp rule,
-- and a row with no session still belongs to a vehicle.

alter table public.sample
  add constraint sample_vehicle_fk
  foreign key (vehicle_id) references public.vehicle (vehicle_id) on delete cascade;

alter table public.telemetry_events
  add constraint telemetry_events_vehicle_fk
  foreign key (vehicle_id) references public.vehicle (vehicle_id) on delete cascade;
