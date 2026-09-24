# 12. Three Sync Lanes on a Central Database

Supersedes ADR-0003.

## Context and Decision

ADR-0003 split synchronization into two channels because the car and the phone
met on the local network, with nothing between them. Without a central point,
the product had to build one: `SyncBatchPacker` pages ten stream types,
`SyncCursorRepository` enforces six ACK invariants over a hybrid logical clock,
`CompanionSyncHttpServer` serves the protocol, and the phone finds the car
through NsdManager on `_geelysync._tcp`. Measured on the tree at `b12d0859`:
about 4 200 lines of protocol held up by about 4 100 lines of test, whose only
job is to behave like a database that is not there.

The topology has three faults, and each of them appears after the car app is
reinstalled — which destroys the Room database, the settings and the paired
device list, because `allowBackup` is false.

**The vehicle identity does not survive.** `VehicleIdMinter` freezes a random
UUID on the first VIN read failure, and at boot that failure is ordinary: the
mint runs on `detectorExecutor` before the Car service is guaranteed connected.
The same physical car then appears as a second vehicle, which orphans its
history and makes `_singleVehicleId` refuse to upload battery cycles at all.

**Two streams break in silence.** `packBatteryCycles` parses its cursor as an
integer and never checks that the ordinal exists, so a phone holding cursor
`120` receives empty answers from a reinstalled car until that car records its
121st cycle — which then overwrites a different cycle, because the cloud key is
`(vehicle_id, ordinal)` and the ordinal is a ledger position that renumbers
legitimately. On the phone, `events.id` is the car's rowid with
`ConflictAlgorithm.replace`, so a reinstalled car whose rowids restart at 1
overwrites the phone's event history one row at a time.

**A third lane already exists and has nowhere to live.** ADR-0003 names two
channels, so `PreferenceProposalEntity` was filed under annotations. Its own
comment describes something else: the phone writes a proposal, never the value,
because `pack_capacity_wh` and `default_charge_cost_per_kwh` change what the car
records, and only the car's acceptance turns one into a write. That is not
last-writer-wins. It is desired and reported.

We decided to make the cloud the only meeting point, and to describe the
topology by the rule that actually governs it: **one writer per fact; the lane
is decided by who writes, not by what the data looks like.**

**1. The meeting point is a row in the cloud, not a request on the local
network.** The mDNS service, the HTTP server, the cursor/ACK protocol and the
HMAC pairing are retired. What replaces the protocol is three rules: a row
carrying a pending mark is written to the database, a reader takes the rows
newer than its newest, and the database refuses a write older than the row
already there. There is no cursor, no acknowledgement, no protocol version and
no discovery.

**2. Lane A carries measurement, and the car is its only writer.** Sessions,
intervals, tracks, events and the battery cycle fold. A single writer needs no
conflict rule; correctness comes from the natural key, which makes a repeated
write a no-op. Every crossing table gains a per-row pending mark in Room — a
mark and not a cursor, for the reason `CompanionDatabase` already documents: a
UUID key does not grow with arrival, and a row already uploaded still changes
when its session closes.

**3. Derived state is published by whoever computes it, and computed by exactly
one device.** `BatteryCycleRepository.rebuild` folds cycles from
`sessionDao.closedFrom`, so the ledger is derivable anywhere the sessions are.
It is nevertheless folded only on the car and published as rows, because
folding it independently on each replica would put the ledger in Kotlin and in
Dart, pinned by a fixture — the exact cost decision 5 removes from lane B.
The cloud conflict key moves to `(vehicle_id, started_at_utc_millis)`, which a
renumbering cannot collide with.

**4. Lane B carries annotation, and any device may write it.** Places, session
costs, journeys and display preferences. The rule stays last-writer-wins with
tombstones — an LWW-Register, the simplest proven conflict-free type, which
`AnnotationConvergence` and `annotationShouldReplace` already implement.

**5. The lane B merge moves into the database, is compared on the hybrid
logical clock, and resolves per field.** Three changes to one rule:

*Into the database.* The rule exists twice today, once in Kotlin and once in
Dart, held together by the annotation convergence fixture. A central row makes
one implementation possible, as a trigger. This is what makes arrival order
irrelevant: Postgres serialises arrival, not causality, so without the trigger
a car reconnecting after three weeks overwrites three weeks of phone edits by
arriving last.

*On the HLC.* `HlcTimestamp` already exists and is used to order acknowledgements
— a stream with one origin, which barely needs causality — while the merge, where
two devices with disagreeing clocks decide one fact, compares raw
`updatedAtUtcMillis`. That is inverted. The stamp changes; the comparison does
not.

*Per field.* For `insight_places`, `session_costs` and `journeys`, whose fields
are edited for independent reasons. The row-level rule was deliberate — an
annotation row was judged small enough for one timestamp to decide every field
it carries — but it was chosen when the link was local and the concurrency
window was seconds. With a car offline for weeks, that window is weeks.
`preferences` is already one key per row, so row and field coincide and it is
unchanged.

**6. Lane C carries control, and it must never merge.** The phone writes the
desired value; the car writes the reported one; the two live in separate tables
joined by a view, because column-level RLS is fragile and unreadable.
Membership is mechanical: if it changes what the car does or records, it is
control; if it only changes what a screen shows, it is annotation. This
replaces a hard-coded list of two keys, and it gives the standing rule that a
control writing to the vehicle must display the confirmed read-back value — never
optimistic local state — a place in the architecture rather than in prose.

**7. No sync library and no CRDT library.** The product keeps using a CRDT; it
does not import one. Of the four kinds of data, three need no merge at all —
lane A has one writer, lane C must not merge, and frames never cross — so the
whole merge surface is one `shouldReplace` on lane B. The guarantee that would
have been bought with a dependency is asserted instead by a property test:
given N writes from several devices, every shuffled application order must
reach the same final state. That is what a CRDT library's own suite runs
against itself.

**8. Frames never cross.** They are not a lane, they are not uploaded, and they
are not restorable. Lane A restores the history; the second-by-second detail of
a session recorded before a reinstall is gone.

## Consequences

- A reinstall stops being a data-loss event. The car reads its own lane A rows
  back, which needs no importer and no reverse protocol.
- The vehicle id becomes a precondition of everything, not a detail. Every
  idempotence guarantee rests on the key matching, so the identity anchors ship
  and are verified on a real car before any upload path is enabled.
- Retention changes meaning. It protects rows the cloud has not received rather
  than rows the phone has not pulled, and a local delete for space must never
  propagate to the cloud as a delete.
- Sync stops working where there is no internet. The local network used to be
  enough. A car that has never uploaded cannot be cut over.
- Lane B is new construction, not a port. The uploader carries five measurement
  streams only; the five annotation tables exist in the cloud schema, with
  `origin` columns and RLS policies already written, and they are empty. The
  `cloud` rank in `originRank` was written for this and has never been reached.
- A wrong trigger is wrong for everyone at once, where a wrong client was wrong
  for one replica. The permutation, clock and late-arrival tests run in CI for
  that reason.
- Two concurrent edits to the same free-text field resolve to one instead of
  merging. This is accepted, not overlooked: a journey note is written by one
  person on one device, and a merged name is worse than a chosen one.
- The car app updates itself every minute through `AppUpdateManager`; the
  companion has no updater. The ordinary migration state is a new car and an old
  phone, so the local channel is removed per user on a drained-and-quiet rule,
  never on a date.

Considered: keeping the two channels and changing only the transport, which
leaves the proposal lane with nowhere to live and keeps the merge in two
languages; making the phone a pure reader, which deletes the annotation channel
the product actively uses and makes lane C impossible; and adopting a library.
PowerSync fits the stack — production Kotlin and Dart SDKs, Supabase
integration, an offline upload queue, last-writer-wins per field — and was
rejected because it is a paid hosted service as the project grows and brings
its own SQLite that cannot be the car's Room database, so every crossing row
would be written twice on the car. ElectricSQL has a deprecated Dart client and
no offline write path. `sqlite-sync` is the only library spanning Kotlin, Dart
and Supabase, and it is a loadable SQLite extension: Android cannot load one
with the stock implementation, so adopting it means swapping the SQLite engine
underneath a Room schema past version 40 on a device holding irreplaceable
telemetry. Synk is Kotlin-only and merge-only, which reintroduces the second
implementation. Automerge, Yjs and Loro are document types whose state would
sit in Postgres as opaque blobs, forfeiting SQL, RLS and every analytical
query.

Not considered a library problem at all: durability while offline. No
conflict-free type provides a durable outbox, retry, ordering, or protection
from a retention sweep deleting unsent rows. That work exists under every
option here.
