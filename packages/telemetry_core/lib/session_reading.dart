/// What a screen reads from one [SessionRecord].
///
/// The store answers three questions and returns the record as it is stored.
/// A list row and a header still need a distance, a duration and a delta, and
/// each of those is a **reduction** over what the record already holds — never
/// a second integral (Rule 2.1). This file is the one place those reductions
/// live, so the car app and the companion app read one session the same way.
library;

import 'measurement.dart';
import 'session_duration.dart';
import 'telemetry_store.dart';

/// The duration of [record], by the rule its kind is reconciled with.
///
/// A trip is start to end. A charge is charging-start to unplugged, falling
/// back through the endpoints the car reconciles with. Both go through
/// [sessionDurationMillis], so a span across a reboot is refused rather than
/// reported as the difference of two clocks that were never the same clock.
int? sessionReadingDurationMillis(SessionRecord record) {
  if (record.kind == SessionKind.charge) {
    final startUtc =
        record.chargeStartedAtUtcMillis ?? record.startedAtUtcMillis;
    final startElapsed =
        record.chargeStartedAtElapsedNanos ?? record.startedAtElapsedNanos;
    final startBoot =
        record.chargeStartedAtBootCount ?? record.startedAtBootCount;
    final endUtc =
        record.plugDisconnectedAtUtcMillis ??
        record.chargeEndedAtUtcMillis ??
        record.endedAtUtcMillis;
    final endElapsed =
        record.plugDisconnectedAtElapsedNanos ??
        record.chargeEndedAtElapsedNanos ??
        record.endedAtElapsedNanos;
    final endBoot =
        record.plugDisconnectedAtBootCount ??
        record.chargeEndedAtBootCount ??
        record.endedAtBootCount;
    if (endUtc == null || endElapsed == null) return null;
    return sessionDurationMillis(
      startUtcMillis: startUtc,
      startElapsedNanos: startElapsed,
      startBootCount: startBoot,
      endUtcMillis: endUtc,
      endElapsedNanos: endElapsed,
      endBootCount: endBoot,
      maxWallDurationMillis: kMaxChargeWallDurationMillis,
    );
  }
  final endUtc = record.endedAtUtcMillis;
  final endElapsed = record.endedAtElapsedNanos;
  if (endUtc == null || endElapsed == null) return null;
  return sessionDurationMillis(
    startUtcMillis: record.startedAtUtcMillis,
    startElapsedNanos: record.startedAtElapsedNanos,
    startBootCount: record.startedAtBootCount,
    endUtcMillis: endUtc,
    endElapsedNanos: endElapsed,
    endBootCount: record.endedAtBootCount,
    maxWallDurationMillis: kMaxTripWallDurationMillis,
  );
}

/// The distance of [record], odometer first.
///
/// The odometer delta is what the car counted. The rollup distance is the
/// integral the car folded, and it answers when an endpoint is missing. The
/// order is the same one `TelemetryEnergy` applies on the car, so the two do
/// not disagree.
Measurement sessionReadingDistance(SessionRecord record) {
  final start = record.startOdometer;
  final end = record.endOdometer;
  if (start.displayValue != null && end.displayValue != null) {
    final delta = end.displayValue! - start.displayValue!;
    if (delta >= 0) {
      return Measurement.combine(
        start,
        end,
        unit: 'km',
        compute: (a, b) => b - a,
      );
    }
  }
  return record.rollup.distance;
}

/// The state of charge the session moved through, in points.
///
/// Discharge is positive for a drive, so a charge answers a negative number.
/// Null when either end is unavailable: an absent SOC is not a zero delta.
double? sessionReadingSocDelta(SessionRecord record) {
  final start = record.startSoc.displayValue;
  final end = record.endSoc.displayValue;
  if (start == null || end == null) return null;
  return start - end;
}

/// The energy delivered to the pack over a charge, kWh.
Measurement sessionReadingDeliveredKwh(SessionRecord record) =>
    record.rollup.delivered.map((wh) => wh / 1000.0, unit: 'kWh');

/// The net pack energy of a drive, kWh.
Measurement sessionReadingNetKwh(SessionRecord record) =>
    record.rollup.netPackEnergy.map((wh) => wh / 1000.0, unit: 'kWh');

/// What the session cost, in its own currency.
///
/// A charge is priced in its own row (`CLAUDE.md`): a paid amount is a receipt
/// and outranks a rate. Null means that nobody priced it, which is a different
/// fact from a free charge priced at zero.
double? sessionReadingCost(SessionRecord record) {
  final paid = record.paidAmount;
  if (paid != null) return paid;
  final rate = record.costPerKwh;
  if (rate == null) return null;
  final kwh = sessionReadingDeliveredKwh(record).displayValue;
  if (kwh == null) return null;
  return kwh * rate;
}

/// The last charge priced before [startedAtUtcMillis].
///
/// A drive is scored at the rate of the charge that filled it, so what a drive
/// cost is a fact about an earlier session. It is asked for with the same
/// question every list uses — one filter, one page — and not with a query of
/// its own. Null means that nothing before it was priced, which is an unpriced
/// drive and not a free one.
Future<SessionRecord?> lastPricedChargeBefore(
  TelemetryStore store,
  int startedAtUtcMillis, {
  int scan = 20,
}) async {
  final page = await store.listSessions(
    filter: SessionFilter(
      kind: SessionKind.charge,
      toUtcMillis: startedAtUtcMillis,
    ),
    page: PageRequest(limit: scan),
  );
  for (final charge in page.sessions) {
    if (charge.costPerKwh != null || charge.paidAmount != null) return charge;
  }
  return null;
}
