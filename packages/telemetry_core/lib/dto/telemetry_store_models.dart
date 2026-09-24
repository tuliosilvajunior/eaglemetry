import 'package:flutter/foundation.dart';

import '../measurement.dart';
import '../track.dart';

/// The kind of session: trip (driving), charge (plugged in), or parked (stationary).
enum SessionKind {
  trip,
  charge,
  parked,
  continuous;

  static SessionKind fromName(String name) => switch (name.toUpperCase()) {
    'TRIP' => SessionKind.trip,
    'CHARGE' => SessionKind.charge,
    'PARKED' => SessionKind.parked,
    'CONTINUOUS' => SessionKind.continuous,
    _ => SessionKind.trip,
  };
}

/// Filter criteria for querying sessions.
@immutable
class SessionFilter {
  const SessionFilter({
    this.kind,
    this.fromUtcMillis,
    this.toUtcMillis,
    this.status,
  });

  final SessionKind? kind;
  final int? fromUtcMillis;
  final int? toUtcMillis;
  final String? status;

  @override
  bool operator ==(Object other) =>
      other is SessionFilter &&
      other.kind == kind &&
      other.fromUtcMillis == fromUtcMillis &&
      other.toUtcMillis == toUtcMillis &&
      other.status == status;

  @override
  int get hashCode => Object.hash(kind, fromUtcMillis, toUtcMillis, status);

  @override
  String toString() =>
      'SessionFilter(kind: $kind, from: $fromUtcMillis, to: $toUtcMillis, status: $status)';
}

/// Pagination parameters.
@immutable
class PageRequest {
  const PageRequest({this.limit = 50, this.offset = 0});

  final int limit;
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is PageRequest && other.limit == limit && other.offset == offset;

  @override
  int get hashCode => Object.hash(limit, offset);

  @override
  String toString() => 'PageRequest(limit: $limit, offset: $offset)';
}

/// Denormalized session rollup: energy, distance, and duration integrals.
///
/// Invariant: `session.rollup == fold(intervals)` (Rule 2.1 & Decision 5).
@immutable
class SessionRollup {
  const SessionRollup({
    required this.distance,
    required this.traction,
    required this.regen,
    required this.auxiliary,
    required this.climate,
    required this.delivered,
    required this.integratedSeconds,
  });

  final Measurement distance; // km
  final Measurement traction; // Wh (discharge positive)
  final Measurement regen; // Wh
  final Measurement auxiliary; // Wh
  final Measurement climate; // Wh
  final Measurement delivered; // Wh (charge sessions only)
  final Measurement integratedSeconds; // s

  /// Net pack energy: traction - regen + auxiliary.
  Measurement get netPackEnergy => Measurement.combine(
    Measurement.combine(traction, regen, unit: 'Wh', compute: (t, r) => t - r),
    auxiliary,
    unit: 'Wh',
    compute: (net, a) => net + a,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionRollup &&
      other.distance == distance &&
      other.traction == traction &&
      other.regen == regen &&
      other.auxiliary == auxiliary &&
      other.climate == climate &&
      other.delivered == delivered &&
      other.integratedSeconds == integratedSeconds;

  @override
  int get hashCode => Object.hash(
    distance,
    traction,
    regen,
    auxiliary,
    climate,
    delivered,
    integratedSeconds,
  );

  @override
  String toString() =>
      'SessionRollup(dist: $distance, trac: $traction, reg: $regen, '
      'aux: $auxiliary, clim: $climate, del: $delivered, sec: $integratedSeconds)';
}

/// Full session record as stored in Room, Sqflite, and Postgres.
@immutable
class SessionRecord {
  const SessionRecord({
    required this.id,
    required this.vehicleId,
    required this.kind,
    required this.status,
    required this.startedAtUtcMillis,
    required this.startedAtElapsedNanos,
    this.startedAtBootCount,
    this.endedAtUtcMillis,
    this.endedAtElapsedNanos,
    this.endedAtBootCount,
    this.durationMillis,
    required this.rollup,
    required this.startOdometer,
    required this.endOdometer,
    required this.startSoc,
    required this.endSoc,
    required this.minSoc,
    required this.maxSoc,
    this.socAgreesWithIntegral,
    required this.startAmbientTemp,
    required this.endAmbientTemp,
    required this.meanAmbientTemp,
    this.plugType,
    this.costPerKwh,
    this.paidAmount,
    this.costCurrency,
    this.chargeStartedAtUtcMillis,
    this.chargeEndedAtUtcMillis,
    this.plugDisconnectedAtUtcMillis,
    this.movementStartedAtUtcMillis,
    this.chargeEndReason,
    this.endReason,
    this.startLatitude,
    this.startLongitude,
    this.startAltitudeM,
    this.startGpsAccuracyM,
    this.startGear,
    this.startPowerKw,
    this.movementStartedAtElapsedNanos,
    this.movementStartedAtBootCount,
    this.chargeStartedAtElapsedNanos,
    this.chargeStartedAtBootCount,
    this.chargeEndedAtElapsedNanos,
    this.chargeEndedAtBootCount,
    this.plugDisconnectedAtElapsedNanos,
    this.plugDisconnectedAtBootCount,
    this.noLongerReducible = false,
    required this.createdAtUtcMillis,
    required this.updatedAtUtcMillis,
    this.startPlace,
    this.climbM,
    this.descentM,
    this.fixCount,
    this.sleepSeconds,
    this.sleepSocDeltaPercent,
    this.sleepEnergyWhEstimate,
  });

  final String id;
  final String vehicleId;
  final SessionKind kind;
  final String status;
  final int startedAtUtcMillis;
  final int startedAtElapsedNanos;
  final int? startedAtBootCount;
  final int? endedAtUtcMillis;
  final int? endedAtElapsedNanos;
  final int? endedAtBootCount;
  final int? durationMillis;
  final SessionRollup rollup;
  final Measurement startOdometer; // km
  final Measurement endOdometer; // km
  final Measurement startSoc; // %
  final Measurement endSoc; // %
  final Measurement minSoc; // %
  final Measurement maxSoc; // %
  final String? socAgreesWithIntegral; // "agrees", "contradicts", "unconfirmed"
  final Measurement startAmbientTemp; // °C
  final Measurement endAmbientTemp; // °C
  final Measurement meanAmbientTemp; // °C
  final int? plugType;
  final double? costPerKwh;
  final double? paidAmount;
  final String? costCurrency;
  final int? chargeStartedAtUtcMillis;
  final int? chargeEndedAtUtcMillis;
  final int? plugDisconnectedAtUtcMillis;
  final int? movementStartedAtUtcMillis;
  final String? chargeEndReason;
  final String? endReason;
  final double? startLatitude;
  final double? startLongitude;
  final double? startAltitudeM;
  final double? startGpsAccuracyM;

  /// The gear the drive started in, as the car's own code. A count, not a name.
  final int? startGear;

  /// The charge power at the first reading of a charge, kW.
  final double? startPowerKw;
  final int? movementStartedAtElapsedNanos;
  final int? movementStartedAtBootCount;
  final int? chargeStartedAtElapsedNanos;
  final int? chargeStartedAtBootCount;
  final int? chargeEndedAtElapsedNanos;
  final int? chargeEndedAtBootCount;
  final int? plugDisconnectedAtElapsedNanos;
  final int? plugDisconnectedAtBootCount;
  final bool noLongerReducible;
  final int createdAtUtcMillis;
  final int updatedAtUtcMillis;

  /// The named place the session started in, matched at read time against
  /// the place rows this store holds. Never stamped on the session table: a
  /// rename or a moved radius corrects every session at once.
  final String? startPlace;

  /// The climb and the descent, summed once from the Track at session close.
  ///
  /// Null on a session recorded before this column existed; a reader falls
  /// back to walking the altitude series for those. See issue 173.
  final double? climbM;
  final double? descentM;

  /// How many position fixes the drive holds. Null before this column
  /// existed, same fallback as [climbM].
  final int? fixCount;

  final int? sleepSeconds;
  final double? sleepSocDeltaPercent;
  final double? sleepEnergyWhEstimate;

  /// Applies the annotation side of a record over a stored one.
  ///
  /// The stores own the merge: the car's wire row carries a cost the car
  /// composed, the phone may hold a fresher cost annotation, and the place
  /// match is a reduction each store runs itself.
  SessionRecord copyWith({
    double? costPerKwh,
    double? paidAmount,
    String? costCurrency,
    String? startPlace,
    bool clearCost = false,
  }) {
    return SessionRecord(
      id: id,
      vehicleId: vehicleId,
      kind: kind,
      status: status,
      startedAtUtcMillis: startedAtUtcMillis,
      startedAtElapsedNanos: startedAtElapsedNanos,
      startedAtBootCount: startedAtBootCount,
      endedAtUtcMillis: endedAtUtcMillis,
      endedAtElapsedNanos: endedAtElapsedNanos,
      endedAtBootCount: endedAtBootCount,
      durationMillis: durationMillis,
      rollup: rollup,
      startOdometer: startOdometer,
      endOdometer: endOdometer,
      startSoc: startSoc,
      endSoc: endSoc,
      minSoc: minSoc,
      maxSoc: maxSoc,
      socAgreesWithIntegral: socAgreesWithIntegral,
      startAmbientTemp: startAmbientTemp,
      endAmbientTemp: endAmbientTemp,
      meanAmbientTemp: meanAmbientTemp,
      plugType: plugType,
      costPerKwh: clearCost ? null : (costPerKwh ?? this.costPerKwh),
      paidAmount: clearCost ? null : (paidAmount ?? this.paidAmount),
      costCurrency: clearCost ? null : (costCurrency ?? this.costCurrency),
      chargeStartedAtUtcMillis: chargeStartedAtUtcMillis,
      chargeEndedAtUtcMillis: chargeEndedAtUtcMillis,
      plugDisconnectedAtUtcMillis: plugDisconnectedAtUtcMillis,
      movementStartedAtUtcMillis: movementStartedAtUtcMillis,
      chargeEndReason: chargeEndReason,
      endReason: endReason,
      startLatitude: startLatitude,
      startLongitude: startLongitude,
      startAltitudeM: startAltitudeM,
      startGpsAccuracyM: startGpsAccuracyM,
      startGear: startGear,
      startPowerKw: startPowerKw,
      movementStartedAtElapsedNanos: movementStartedAtElapsedNanos,
      movementStartedAtBootCount: movementStartedAtBootCount,
      chargeStartedAtElapsedNanos: chargeStartedAtElapsedNanos,
      chargeStartedAtBootCount: chargeStartedAtBootCount,
      chargeEndedAtElapsedNanos: chargeEndedAtElapsedNanos,
      chargeEndedAtBootCount: chargeEndedAtBootCount,
      plugDisconnectedAtElapsedNanos: plugDisconnectedAtElapsedNanos,
      plugDisconnectedAtBootCount: plugDisconnectedAtBootCount,
      noLongerReducible: noLongerReducible,
      createdAtUtcMillis: createdAtUtcMillis,
      updatedAtUtcMillis: updatedAtUtcMillis,
      startPlace: startPlace ?? this.startPlace,
      climbM: climbM,
      descentM: descentM,
      fixCount: fixCount,
      sleepSeconds: sleepSeconds,
      sleepSocDeltaPercent: sleepSocDeltaPercent,
      sleepEnergyWhEstimate: sleepEnergyWhEstimate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionRecord &&
      other.id == id &&
      other.vehicleId == vehicleId &&
      other.kind == kind &&
      other.status == status &&
      other.startedAtUtcMillis == startedAtUtcMillis &&
      other.endedAtUtcMillis == endedAtUtcMillis &&
      other.rollup == rollup &&
      other.startOdometer == startOdometer &&
      other.endOdometer == endOdometer &&
      other.startSoc == startSoc &&
      other.endSoc == endSoc &&
      other.minSoc == minSoc &&
      other.maxSoc == maxSoc &&
      other.socAgreesWithIntegral == socAgreesWithIntegral &&
      other.startAmbientTemp == startAmbientTemp &&
      other.endAmbientTemp == endAmbientTemp &&
      other.meanAmbientTemp == meanAmbientTemp &&
      other.plugType == plugType &&
      other.costPerKwh == costPerKwh &&
      other.paidAmount == paidAmount &&
      other.costCurrency == costCurrency &&
      other.noLongerReducible == noLongerReducible;

  @override
  int get hashCode => Object.hash(
    id,
    vehicleId,
    kind,
    status,
    startedAtUtcMillis,
    endedAtUtcMillis,
    rollup,
    startOdometer,
    endOdometer,
    startSoc,
    endSoc,
  );
}

/// Paginated list of session records.
@immutable
class SessionListPage {
  const SessionListPage({
    required this.sessions,
    required this.totalCount,
    required this.page,
    required this.hasMore,
  });

  final List<SessionRecord> sessions;
  final int totalCount;
  final PageRequest page;
  final bool hasMore;

  @override
  bool operator ==(Object other) =>
      other is SessionListPage &&
      listEquals(other.sessions, sessions) &&
      other.totalCount == totalCount &&
      other.page == page &&
      other.hasMore == hasMore;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(sessions), totalCount, page, hasMore);
}

/// One event from table `telemetry_events`.
@immutable
class TelemetryEventRecord {
  const TelemetryEventRecord({
    required this.id,
    this.sessionId,
    required this.type,
    required this.occurredAtUtcMillis,
    required this.occurredAtElapsedNanos,
    this.signalKey,
    this.value,
    this.previousValue,
    this.quality,
    this.source,
    this.details = '',
  });

  final int id;
  final String? sessionId;
  final String type;
  final int occurredAtUtcMillis;
  final int occurredAtElapsedNanos;
  final String? signalKey;
  final String? value;
  final String? previousValue;
  final String? quality;
  final String? source;

  /// The event's own payload. Empty when it carries none, which is most of
  /// them: an event is a transition, and only some transitions have a body.
  final String details;

  @override
  bool operator ==(Object other) =>
      other is TelemetryEventRecord &&
      other.id == id &&
      other.sessionId == sessionId &&
      other.type == type &&
      other.occurredAtUtcMillis == occurredAtUtcMillis &&
      other.signalKey == signalKey &&
      other.value == value &&
      other.previousValue == previousValue &&
      other.quality == quality &&
      other.source == source &&
      other.details == details;

  @override
  int get hashCode =>
      Object.hash(id, sessionId, type, occurredAtUtcMillis, signalKey, value);
}

/// Full session record with its chronological transition events.
@immutable
class SessionDetail {
  const SessionDetail({
    required this.session,
    required this.events,
    this.track,
  });

  final SessionRecord session;
  final List<TelemetryEventRecord> events;
  final TrackRow? track;

  @override
  bool operator ==(Object other) =>
      other is SessionDetail &&
      other.session == session &&
      listEquals(other.events, events) &&
      other.track == track;

  @override
  int get hashCode => Object.hash(session, Object.hashAll(events), track);
}

/// One minute interval of CAN-rate integrals (or reduced to widthMillis).
@immutable
class IntervalRecord {
  const IntervalRecord({
    required this.sessionId,
    required this.startUtcMillis,
    required this.widthMillis,
    required this.traction,
    required this.regen,
    required this.auxiliary,
    required this.climate,
    required this.delivered,
    required this.distance,
    required this.coveredSeconds,
    required this.climateCoveredSeconds,
    required this.speedCoveredSeconds,
    required this.deliveredCoveredSeconds,
    this.startSoc = const Measurement.unreported(unit: '%'),
    this.endSoc = const Measurement.unreported(unit: '%'),
    this.startVoltage = const Measurement.unreported(unit: 'V'),
    this.endVoltage = const Measurement.unreported(unit: 'V'),
    this.startElapsedNanos,
    this.startBootCount,
    this.timeState = 'unknown',
    this.correctedFromUtcMillis,
  });

  final String sessionId;
  final int startUtcMillis;
  final int widthMillis;
  final Measurement traction; // Wh
  final Measurement regen; // Wh
  final Measurement auxiliary; // Wh
  final Measurement climate; // Wh
  final Measurement delivered; // Wh
  final Measurement distance; // km
  final double coveredSeconds;
  final double climateCoveredSeconds;
  final double speedCoveredSeconds;
  final double deliveredCoveredSeconds;
  final Measurement startSoc; // %
  final Measurement endSoc; // %
  final Measurement startVoltage; // V
  final Measurement endVoltage; // V
  /// The monotonic reading behind [startUtcMillis], null when the writer
  /// predates the pair (unrecoverable rows keep null).
  final int? startElapsedNanos;
  final int? startBootCount;

  /// What the time authority believes about the stamp; 'unknown' until the
  /// detector and sweeper say otherwise.
  final String timeState;

  /// The stamp this row carried before the sweeper corrected it.
  final int? correctedFromUtcMillis;

  @override
  bool operator ==(Object other) =>
      other is IntervalRecord &&
      other.sessionId == sessionId &&
      other.startUtcMillis == startUtcMillis &&
      other.widthMillis == widthMillis &&
      other.traction == traction &&
      other.regen == regen &&
      other.auxiliary == auxiliary &&
      other.climate == climate &&
      other.delivered == delivered &&
      other.distance == distance &&
      other.coveredSeconds == coveredSeconds &&
      other.climateCoveredSeconds == climateCoveredSeconds &&
      other.speedCoveredSeconds == speedCoveredSeconds &&
      other.deliveredCoveredSeconds == deliveredCoveredSeconds &&
      other.startSoc == startSoc &&
      other.endSoc == endSoc &&
      other.startVoltage == startVoltage &&
      other.endVoltage == endVoltage &&
      other.startElapsedNanos == startElapsedNanos &&
      other.startBootCount == startBootCount &&
      other.timeState == timeState &&
      other.correctedFromUtcMillis == correctedFromUtcMillis;

  @override
  int get hashCode => Object.hash(
    sessionId,
    startUtcMillis,
    widthMillis,
    traction,
    regen,
    auxiliary,
    climate,
    delivered,
    distance,
    coveredSeconds,
    startSoc,
    endSoc,
    startVoltage,
    endVoltage,
    startElapsedNanos,
    startBootCount,
    timeState,
    correctedFromUtcMillis,
  );
}

/// One sparse state sample point from table `sample`.
@immutable
class SamplePoint {
  const SamplePoint({
    required this.tUtcMillis,
    required this.tElapsedNanos,
    this.bootCount,
    required this.value,
    this.groupId,
  });

  final int tUtcMillis;
  final int tElapsedNanos;
  final int? bootCount;
  final Measurement value;
  final String? groupId;

  @override
  bool operator ==(Object other) =>
      other is SamplePoint &&
      other.tUtcMillis == tUtcMillis &&
      other.tElapsedNanos == tElapsedNanos &&
      other.bootCount == bootCount &&
      other.value == value &&
      other.groupId == groupId;

  @override
  int get hashCode =>
      Object.hash(tUtcMillis, tElapsedNanos, bootCount, value, groupId);
}

/// Series for a session: minute intervals and sparse sample curves.
@immutable
class TelemetrySeries {
  const TelemetrySeries({
    required this.sessionId,
    required this.intervals,
    this.samples = const {},
  });

  final String sessionId;
  final List<IntervalRecord> intervals;
  final Map<String, List<SamplePoint>> samples;

  @override
  bool operator ==(Object other) =>
      other is TelemetrySeries &&
      other.sessionId == sessionId &&
      listEquals(other.intervals, intervals) &&
      mapEquals(other.samples, samples);

  @override
  int get hashCode => Object.hash(
    sessionId,
    Object.hashAll(intervals),
    Object.hashAll(samples.keys),
  );
}
