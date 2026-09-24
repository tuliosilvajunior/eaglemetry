# 10. What the Sample Series Carries

## Context and Decision

`FrameRepository.persistActiveSnapshot` writes a row for every state signal the
snapshot holds. No list says which signals the series carries, so a signal that
is declared is a signal that is stored, on the car and again in the cloud.

Measured on `partitions.sample_2026_08` over 23–25 Aug 2026, every vehicle,
after the `HV_BATTERY_VOLTAGE` deadband of commit `2f30f7a` was in effect:
187 132 rows over three days, 62 377 a day across four vehicles. The position
tuple was 58.7 % of them. Seven keys held 1 744 rows and answered no read path
in either app.

We decided three things.

**1. A signal states whether the series carries it.** `SignalDeclaration` gains
`sampled`, default true. False keeps the signal on the bus, in the live cards,
in the aggregates and in the event log, and out of the series.
`UNSAMPLED_KEYS` in `GeelyDeclarations` is the list, and each entry names the
measurement that put it there.

Seven keys start there. `IPK_AVERAGE_POWER_CONSUMPTION` held one value, 328.0,
for every row. `HYBRID_POWER_FLOW`, `TRIP_ED_DRIVING_ENERGY_FLOW_VENDOR`,
`DRIVE_POWER_OUT_PUT` and `ADAS_ACC_SPEED_VALUE` held 0.0 for every row.
`BATTERY_SOH_PERCENT` wrote 53 rows and every one was `INVALID`: it is polled,
the polling read carries no source timestamp, and `stateOfHealthPercent` needs
one to tell 99.9 % from the factory default. `TRIP_ED_DRIVING_ENERGY_FLOW` is
the shadow half of a comparison that has answered — it resolves to the same
property as `ED_DRIVING_ENERGY_FLOW`, and 1 701 of 1 701 pairs sharing a
millisecond held the same value.

**2. A position tuple is written whole or not at all.** The rule was already
stated on `SignalDeclaration.group`, and the maximum-gap branch broke it: it
fires on the clock, so it reached the members with one coordinate missing, and
each member is written only when present. That stored 1 171 groups holding a
latitude with no longitude and 778 holding an altitude alone — 4 291 rows
naming a place no vehicle stood.

**3. The position tuple earns a row every 20 m, not every 10 m.**
`GeelyProfile.POSITION_DISTANCE_THRESHOLD_M`. The collector ticks at 1 Hz, so
at 10 m anything above 36 km/h wrote on every tick. Simulated over the 26 388
recorded fixes: 20 m keeps 62.9 % of them, and a discarded point stands 14.4 m
on average from the one kept before it.

## Consequences

- The series drops about 26.5 % of its rows: 62 377 a day becomes 45 862.
- A route is coarser. The detail screen decimates to
  `kRouteExpandedPointLimit` = 1 200 points and the average recorded session
  held 520, so the drawn route is unchanged for most sessions and loses corner
  detail on the longest ones.
- A signal outside the series keeps its event log. `BATTERY_SOH_PERCENT` still
  records each change, so the degradation history survives if the property
  starts answering.
- Restoring a signal to the series is one line in `UNSAMPLED_KEYS`. Restoring
  the rows it did not write is not possible, so the list is a decision about
  data that will never exist.
- `OUTSIDE_TEMPERATURE` stays in the series although it held one distinct
  value. `kTripDetailSampleKeys` and `kChargeDetailSampleKeys` read it from the
  series, and `AmbientTemperatureSelector` reads it live as the fallback
  `GeelyProfile.trustOrder` names for the ambient reading. Its constant value
  is a read fault, not a storage one.

Considered: dropping the sample series for any signal with no declared
deadband, raising the position threshold to 30 m, and deleting the dead keys
from `SignalKey`. Rejected: the null-band rule is what `RANGE_REMAINING`
depends on to write at all; 30 m puts the discarded point 19.6 m from the kept
one, which shows on a city corner; and a deleted key loses the vendor
catalogue entry that says the probe was tried.

## Amendment 2026-08-28 (issue 184): the series is exactly the read set

Decision 1's mechanism stands: `UNSAMPLED_KEYS` is the only place membership
is decided, and `GeelyDeclarations` derives each declaration's `sampled` from
it when the map is built. No declaration opts out on its own; a declaration
without the flag in the map does not count as sampled by accident.

What changed is the size of the list. The read side narrowed to the union of
`kTripDetailSampleKeys` and `kChargeDetailSampleKeys` in
`packages/telemetry_core/lib/session_detail_reading.dart` —
`VEHICLE_SPEED`, `HV_BATTERY_SOC`, `ODOMETER`, `PACK_VOLTAGE`. Every other
`STATE` declaration joined `UNSAMPLED_KEYS`, each entry naming the measurement
that put it there. The consequences that reversed:

- `OUTSIDE_TEMPERATURE` no longer stays in the series. `Session` carries
  start/end/mean ambient as one distinct value (issue 181), and the tiles read
  that, so neither temperature signal earns rows anymore. The constant-value
  reasoning that kept it is superseded: the reading is now stored once on the
  session, not sampled.
- `RANGE_REMAINING` no longer writes at all, so the null-band rule it was the
  case for is no longer what keeps it in the series. The rule itself remains a
  general property of the evaluator for any sampled signal without a declared
  band.
- The position tuple (`LATITUDE`, `LONGITUDE`, `ALTITUDE`, `GPS_ACCURACY`)
  no longer earns rows. The route lives in `Track` (issue 173/174): one row
  per session holding the deadbanded path, evaluated by the same rules —
  distance, altitude, stop band, maximum gap — through a single evaluator
  entry point that returns only whether the `Track` earned a point. Restoring
  the position keys to `UNSAMPLED_KEYS` is therefore **not** the one-line
  promise: no write path emits position rows anymore, so removing them from
  the list would only change what the declarations say. The route is a `Track`
  question now, not a series question.
- Old sessions recorded before `Track` existed keep their map, terrain chart,
  climb tile and fix count: the stores supplement the position keys when a
  session has no `Track` row — the car's `storeGetSeries` and the companion's
  `SqfliteStore.series` both do, at read time, without rewriting the data — and
  the companion's route helpers (`firstGpsPoint`, `lastGpsPoint`, `gpsPath`)
  rebuild their points from the stored position samples the same way. This is
  a presentation fallback, not a sync path.
- `RATE` declarations are outside this decision. A rate is folded into the
  per-minute integral (ADR-0001) and never earns a sample row —
  `evaluateStandalone` refuses anything that is not a standalone `STATE` — so
  the read-set rule governs `STATE` only, and the membership test filters on
  `nature == STATE` for that reason.

