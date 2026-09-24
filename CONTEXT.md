# Capy Energy Domain Context

Capy Energy is an automotive telemetry application for Geely / Flyme Auto Android Automotive head units, paired with a multi-platform phone companion app.

## Language

### Storage & Telemetry

**Telemetry Store**:
The primary abstraction for reading historical telemetry on both car and companion apps. It exposes only three queries: `listSessions`, `session`, and `series`.
_Avoid_: Direct SQLite queries in UI widgets, custom historical aggregation endpoints.

**Session**:
A contiguous block of vehicle activity representing a single mode: Trip, Charge, or Parked.
_Avoid_: Drive, ride, charge cycle.

**Interval**:
A 1-minute folded aggregation of telemetry samples recorded within an active session.
_Avoid_: Minute bucket, timeslice, chunk.

**Sample** _(historical, removed in issue 221)_:
An instantaneous reading of vehicle signals that existed before the position tuple moved to Track and the state-of-charge series moved to Interval. No live code path reads or writes Sample rows after schema version 41.
_Avoid_: Building any new code that references the `sample` table.

**Measurement**:
A domain type combining a numeric value, its unit, and a validity state (`valid`, `estimated`, `invalid`, `unreported`).
_Avoid_: Raw primitive numbers, untyped floats.

**Annotation**:
User or app metadata that any device may edit (places, costs, journeys, display preferences), converging by last-writer-wins with tombstones. A setting that changes what the car does or records is a Control, not an Annotation.
_Avoid_: Session column mutation, measurement tag, calling a Control an Annotation.

**Control**:
A setting the phone asks for and the car decides: it carries a desired value and a reported one, and never merges. Everything that changes what the vehicle does or records is a Control.
_Avoid_: Last-writer-wins on a vehicle setting, optimistic local state, "synced preference".

### Vehicle Hardware & Signals

**Layer 0 (Vehicle Profile)**:
The hardware specification layer (`VehicleProfile`, `GeelyProfile`, `SignalKey`) containing all vehicle-specific identifiers, conversions, and limits. Code above layer 0 never references raw property IDs.
_Avoid_: VHAL property literals in UI or services.

**Trip Energy**:
Net energy consumption integrated from CAN bus voltage and current over time (`TelemetryEnergy.tripPowerIntegral`).
_Avoid_: SOC-derived energy, multiplying battery percentage by pack capacity.

**Heading**:
Direction of travel derived from GNSS course-over-ground (`Location.getBearing()`) above 1.5 km/h, held stationary during stops.
_Avoid_: Magnetic compass, gyroscope yaw integral.

**Smoothness**:
The rate of change of motor drive power per kilometre over a trailing 30-second window.
_Avoid_: Instantaneous speed/power ratio, instant efficiency pill.

**Pack Capacity**:
Fixed nominal pack capacity configured via vehicle settings or profile defaults.
_Avoid_: Dynamic VHAL capacity property queries.

### Integration & Boundaries

**Pigeon Surface**:
Typed schema-generated communication interface between Flutter Dart and Kotlin Android (`pigeons/telemetry_wire.dart`).
_Avoid_: Ad-hoc `MethodChannel` calls for migrated methods.

**Live Stream**:
A one-way encrypted BLE push of transient vehicle snapshots from car to phone (`0xCB02`), gated by pairing and the Beta switch. Carries no Session, Interval, or Sample.
_Avoid_: BLE sync, live telemetry channel, bidirectional GATT command.

**Sync Lane**:
One of the three paths data takes between car and phone, decided by who writes it (ADR-0012): the **Measurement Lane** (the car is the only writer; no conflict rule is needed; the car uploads directly to the cloud and the phone suppresses duplicate measurement uploads through `phone_cutover_readiness`), the **Annotation Lane** (any device writes; converges by last-writer-wins), and the **Control Lane** (the phone asks, the car decides; never merges). Frames are not a lane and never cross.
_Avoid_: Bidirectional raw telemetry sync, "the sync" as one undifferentiated path.

**Time Authority**:
Minutes recorded before the boot learns real time wait as pending (kept, marked, never uploaded); the trusted wall-to-monotonic pair then corrects them by exact arithmetic. A boot whose time never arrives stays marked, and a boot between two dated boots earns a time range, never an exact time. Anchor needs two independent sources or history (ADR-0013).
_Avoid_: Trusting a single clock source, deleting pending rows early, fabricating an exact time for an unplaceable boot.

**Unclaimed Telemetry Lifecycle (Decision D2)**:
Pre-claim telemetry recorded by the car without an account (`account_id IS NULL`) is preserved indefinitely until claimed. Automatic `pg_cron` deletion is kept disabled (standing owner decision: manual cleanup only via `cleanup_unclaimed_telemetry`).
_Avoid_: Enabling automated pg_cron deletion without explicit owner request.


**Dual-Channel Sync** _(historical, superseded by ADR-0012)_:
The two-channel topology used while the car and the phone met on the local network, with cursor-based replication and acknowledgements standing in for a central database.
_Avoid_: Building anything new on cursors, acknowledgements, or the local sync channel.

### UI Composition

**Screen Body**:
Shared, platform-agnostic content of a screen (e.g. `SettingsBody`, `HistoryBody`) composed into different scaffolds per surface. Takes view state, intents, and surface capabilities; knows nothing about navigation or store wiring.
_Avoid_: Scaffold-agnostic screen, shared page, unified scaffold.

**Surface Scaffold**:
Chrome that frames a Screen Body: `AppJourneyScaffold` (car bezel, `CardStage`, `staticBar`) or `CompanionShell` (PillTabBar, PageView). Owns navigation, chrome, and how the body is mounted.
_Avoid_: Unified scaffold, generic shell.

**Surface Capabilities**:
Value object describing what the current surface can do (`widthClass`, `supportsSelection`, `inputMode`, `allowKeyboard`, density). Screen Bodies branch on capabilities, never on platform identity.
_Avoid_: Platform enum, `isCar` flag.

**Reactivity Axes**:
Three independent dimensions every Screen Body must handle: `data-reactive` (store to view model to UI via `TelemetryQuery`/`Loadable`), `viewport-reactive` (available width class), `input-reactive` (rotary vs touch, selection model, keyboard allowance, reduced motion).
_Avoid_: Unqualified "adaptive" or "responsive".

### Insights & Routes

**InsightPlace**:
A named location with a center and a configurable radius. The user `name` always wins over any suggested `autoName`.
_Avoid_: Auto-clustered place, raw GPS point.

**Candidate Place**:
A derived grouping of `Trip` endpoints that match no `InsightPlace`, clustered by 100 m cell. It exists only to suggest naming and is never stored.
_Avoid_: Unnamed InsightPlace, raw endpoint.

**AutoName**:
A name suggested by reverse geocode (`Nominatim` `road` + `house_number` only, e.g. `Rua Visconde de Piraja, 100`) on the companion only, cached per 100 m cell, filled automatically as early as possible when opt-in is on (start, after sync, Places screen) for every namable point. Shown only when `InsightPlace.name` is empty.
_Avoid_: Long `display_name`, auto-overwrite, car-side geocode.

**Place Recurrence**:
The count of `Trip`s where a place or candidate appears as origin plus as destination. It orders the "Consultar locais" list.
_Avoid_: One-way count, raw visit counter.

**Named Route**:
An ordered pair of two `InsightPlace`s and all recorded trips between them (par ordenado de dois `InsightPlace`, e todas as viagens registradas entre eles).
_Avoid_: Unordered place pairs, waypoint route lists, screen-level grouping.

**Measured Trip**:
A closed trip that passes every comparison gate: CAN energy present, minute buckets present, sign confirmed, distance above the floor. Only measured trips enter averages and rankings.
_Avoid_: Any closed trip, GPS-only trip.

**Route Ranking**:
Every `Measured Trip` of a `Named Route` ordered by Wh/km, most efficient first. It answers "which run was best" and makes no statistical claim.
_Avoid_: Cross-route leaderboard, statistical claim list.

**Range Drop**:
The change in a range value across a measured stretch, set against the distance actually driven over that same stretch. Measured live and in memory for the current stretch only, for the car value (`RANGE_REMAINING`) and the app value (`RangeEstimate.ownRangeKm`) together.
_Avoid_: Range accuracy score, honesty rating, prediction verdict.

**Route Variant**:
A distinct path taken between the same pair of named places, identified by a snapped 100-metre cell signature (um caminho distinto entre o mesmo par, identificado pela assinatura de células de 100 m).
_Avoid_: Raw GPS trace comparisons, unquantized polyline diffing.

