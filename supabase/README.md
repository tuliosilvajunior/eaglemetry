# The cloud replica

Status: all three slice-6 migrations are pushed, and the tier boundary is
verified against the real PostgREST. The uploader is written and tested against
a fake sink; **no screen calls it yet**. This directory holds slice 6, phase C. The uploader is not built.

## What is here

| File | What it holds |
| --- | --- |
| `migrations/20260820120000_slice6_cloud_schema.sql` | the tables, one per car table, with the same names and the same columns; the monthly partitioning of `sample`; `vehicle`, `entitlement` and `plan_config` |
| `migrations/20260820120100_slice6_rls.sql` | the tier boundary, which is Row Level Security and nothing else |
| `migrations/20260820150000_slice6_detail_cascade.sql` | the two foreign keys the verification found missing |
| `migrations/20260831120000_battery_cycles_key_on_start_time.sql` | issue 227 phase 0: keys `battery_cycles` on `(vehicle_id, start_utc_millis)` instead of the renumbering ordinal |
| `migrations/20260902170100_battery_cycle_sessions_fk_on_start_time.sql` | re-points `battery_cycle_sessions` at the new `battery_cycles` key, carrying the cycle's `start_utc_millis` on the membership row so the foreign key (and its `ON DELETE CASCADE`) can exist again |
| `migrations/20260902190000_car_device_telemetry_rls.sql` | issue 227: the car (`anon` + `x-car-token`) gets grants and RLS on the telemetry and annotation tables, every policy scoped by `car_device_identity_from_header()` |
| `migrations/20260903120000_car_direct_upload_schema.sql` | issue 236 phase 1: `account_id` becomes nullable, a `before insert or update` trigger stamps it from the request identity, and the car reaches the measurement tables as `anon` scoped to its own vehicle |
| `schema_full.sql` | the same database as every migration above, applied in one file. `MeasurementIngestionSchemaTest` and `DevicePairingSchemaTest` read it, so it is a contract, not a convenience copy |

**One policy per verb per table.** The car's policies are named `<table>_device_reads` / `_device_writes` / `_device_updates`, and issue 236 reuses issue 227's names on the seven measurement tables on purpose: 227 demanded `account_id = <the device's account_id>`, which a car cannot satisfy before a claim, and 236 replaces that rule with the vehicle-only one. Two permissive policies for the same verb are ORed together and the looser one wins silently, so the newer definition takes the older name instead of adding a second. The annotation and ownership policies keep 227's account-scoped rule: only a measurement can exist before a claim.

The column names are the car's Room columns in snake_case. That transform is
mechanical and one-directional, and it is what the uploader must apply. Postgres
folds an unquoted identifier to lower case, so a literal camelCase column would
have to be quoted at every call site and would still not read as the car's name.

## Running the SQL tests

Each file in `tests/` runs with `psql` against a scratch database. They apply
the schema themselves and need only the three Supabase roles, which they create
if the database has none:

```bash
createdb test_car_direct_upload
psql -d test_car_direct_upload -f supabase/tests/car_direct_upload_rls.sql
```

`\set ON_ERROR_STOP on` is at the top of every file, so a non-zero exit is a
failure and the last `PASS` notice says how far it got.

`tests/car_direct_upload_rls.sql` holds the issue 236 proof matrix, P1 to P17:
an unclaimed car write stores `account_id` NULL, a forged or nulled `account_id`
in the payload is overwritten by the stamp trigger, a token reaches only its own
vehicle, the phone sees an unclaimed row only after the claim backfills it, and
an `authenticated` caller carrying a stolen car token is refused. P7, P14 and
P15 run the claim itself through the real `claim_pairing_session` RPC
(migration `20260911120000_claim_history_backfill.sql`).

## Applying it

The CLI is linked to the project. From the repository root:

```bash
supabase db push
```

If the CLI asks for a project directory, run `supabase init` first and keep the
generated `config.toml`; nothing here depends on its contents.

`supabase/.temp/` is the CLI's local link state and is not committed.

## Two things the schema does that are worth knowing before you change them

**The partitions live in the `partitions` schema, not in `public`.** A policy on
a partitioned table applies when the query goes through the parent. A query
against a partition **directly** uses that partition's own policies, and a fresh
partition has none. A partition sitting in `public` would therefore be one more
table PostgREST exposes, holding the same detail rows with no window on them.
Two guards, because this failure is silent: the schema is not exposed, and every
partition has RLS enabled with no policy of its own.

**`sample`'s primary key is `(vehicle_id, key, t_utc_millis)`**, not the tuple
the plan names. `session_id` is nullable by the back-stamp rule — the
transitions that start a session happen before the session exists — and a
nullable column cannot sit in a primary key. What remains is still idempotent:
one vehicle, one signal, one instant is one reading.

## What was verified, and what was not

The two files were applied to a scratch PostgreSQL 17 database with `auth.users`,
the `authenticated` role and `auth.uid()` stubbed, and these were checked:

- a row lands in the partition for its own month;
- a free account reads its session rows at any age, and reads only the detail
  inside the window;
- an account with a live entitlement reads the detail outside the window;
- an account cannot write its own entitlement, cannot delete a measurement, and
  cannot read a partition directly;
- re-inserting the same session changes nothing.

The `curl` verification the plan asks for then ran against the real project,
with the publishable key from `.env` and a free account's token:

- the free account reads 2 sessions and 2 intervals of any age;
- it reads 1 of the 2 rows in each of `sample`, `telemetry_events` and
  `trip_segments` — the row outside the window is **absent**, not refused;
- it cannot read or write `entitlement` or `plan_config`, cannot delete a
  measurement, cannot read a partition directly (PostgREST does not know the
  name), and cannot insert a row carrying another account's id;
- a replayed session upload changes nothing.

**The run found a defect the file review had not.** `sample` and
`telemetry_events` carried no foreign key, so deleting an account removed its
sessions and left the two largest detail tables behind — and `sample` is where
the coordinates live. `20260820150000_slice6_detail_cascade.sql` fixes it, is
pushed, and is live: a sample or an event naming a vehicle that does not exist
now comes back 409 `23503` instead of being stored.

## The uploader

`apps/companion/lib/sync/cloud_uploader.dart` holds the rules and knows no
provider. `supabase_cloud_sink.dart` is the one file in the sync layer that
knows the cloud is Supabase, which mirrors what `SupabaseAccountGateway` does
for the account. `CompanionRuntime.uploadToCloud()` runs it.

Three things it does that are decisions rather than plumbing:

- **what owes an upload is a mark per row, not a cursor.** Every uploadable
  table on the phone carries `dirty`, set by the write and cleared only after
  the cloud accepted that exact row. A cursor was tried first and is wrong
  twice: the orders available are the natural keys, and a session's uuid does
  not grow with arrival — a drive recorded today can sort before one uploaded
  last week and would sit behind the cursor forever — and a cursor cannot say
  that a row already uploaded has **changed**, which every open session does
  when it closes. The mark is still the phone's own, and it is not the car's
  ack cursor: the car is acked for what reached the phone, this records what
  reached Postgres;
- **the order follows the foreign keys.** The vehicle goes first, then the
  sessions, then everything that hangs off them. A run that stops halfway
  leaves a shorter history, never a broken one;
- **a staged sample is not uploaded.** A staged row is one the car has not been
  acked for, so it may still be replaced, and a measurement table is never
  edited.

The trigger is a button on the Sync tab, in a card of its own beside the sync
card. It is never automatic: the phone is the archive whether or not anything
is sent, and a pull that quietly posted a year of routes to a server would be a
decision the reader never made. The card is separate from the sync card for the
same reason the two states are separate on the controller — the pull talks to
the car on the local network and the upload talks to a server, they fail for
unrelated reasons, and a reader has to see which of the two did not work.

## Test data still in the project

The verification account is `capy-rls-test-…@mailinator.com`, id
`161dc63e-326b-499f-b372-bab852a05370`, and it owns vehicle `RLSTEST1` with two
sessions, two intervals, two samples, two events and two route segments.
Deleting that user in the dashboard removes all of it, because the cascade is
now in place. The CLI cannot do it: it runs migrations, not statements, and the
admin auth API needs the service role key.
