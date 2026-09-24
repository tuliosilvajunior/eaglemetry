import 'package:pigeon/pigeon.dart';

/// The typed half of the telemetry surface.
///
/// This file is the schema, not code that runs. Regenerate both sides with:
///
/// ```bash
/// dart run pigeon --input pigeons/telemetry_wire.dart
/// ```
///
/// Methods move here one at a time. A method described here leaves the shared
/// `com.timhss.capyenergy/telemetry` channel and gets its own generated one,
/// so the migration can stop at any point with both surfaces working.
///
/// What this buys, per method: the key names become fields, so a rename fails
/// to compile on both sides instead of reaching the car as a null. The
/// hand-written DTOs stay — they carry validation, not parsing, and a generated
/// class cannot express "this capacity is outside what the pack can hold".
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'packages/telemetry_core/lib/generated/telemetry_wire.g.dart',
    dartPackageName: 'telemetry_core',
    // One literal: pigeon reads this annotation from the AST and does not
    // evaluate adjacent string concatenation.
    kotlinOut:
        'android/app/src/main/kotlin/com/timhss/capyenergy/bridge/generated/TelemetryWire.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.timhss.capyenergy.bridge.generated',
      errorClassName: 'TelemetryWireError',
    ),
  ),
)
/// One interval of the energy integral.
///
/// The width is not here: it belongs to the series, and repeating it per bucket
/// would let one bucket in a series disagree with the rest.
class EnergyBucketWire {
  EnergyBucketWire({
    required this.startUtcMillis,
    required this.tractionWh,
    required this.regeneratedWh,
    required this.auxiliaryWh,
    required this.integratedSeconds,
    required this.speedDistanceKm,
    required this.odometerDistanceKm,
    required this.speedIntegratedSeconds,
    required this.climateWh,
    required this.climateIntegratedSeconds,
    required this.deliveredWh,
    this.startSoc,
    this.endSoc,
    this.startVoltage,
    this.endVoltage,
  });

  int startUtcMillis;
  double tractionWh;
  double regeneratedWh;
  double auxiliaryWh;
  double integratedSeconds;
  double speedDistanceKm;
  double odometerDistanceKm;
  double speedIntegratedSeconds;
  double climateWh;
  double climateIntegratedSeconds;
  double deliveredWh;
  double? startSoc;
  double? endSoc;
  double? startVoltage;
  double? endVoltage;
}

/// The minutes over a stretch of clock, across whatever trips fell in it.
class EnergyWindowBucketsWire {
  EnergyWindowBucketsWire({
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.sessionCount,
    required this.resampledSessionCount,
    required this.buckets,
    this.lastChargeCostPerKwh,
    this.lastChargeCostCurrency,
  });

  int startUtcMillis;
  int endUtcMillis;
  int sessionCount;
  int resampledSessionCount;
  List<EnergyBucketWire> buckets;
  double? lastChargeCostPerKwh;
  String? lastChargeCostCurrency;
}

/// The interval in progress plus the last few closed ones, from memory.
class LiveEnergyBucketsWire {
  LiveEnergyBucketsWire({
    required this.bucketMillis,
    required this.buckets,
    this.sessionId,
    this.startedAtUtcMillis,
    this.timeUnsynced,
  });

  /// The cut the accumulator used. The live series and the efficiency series
  /// are the same integral at two widths, so the reader is told which.
  int bucketMillis;
  List<EnergyBucketWire> buckets;

  /// Null when no trip is running: `currentDrive` then has nothing to show,
  /// which is not the same as a failed read.
  String? sessionId;
  int? startedAtUtcMillis;

  /// True while the boot's clock anchor is still unlearned: the stamps above
  /// are the car's birth clock, so Dart grids on the buckets themselves and
  /// counts relative minutes. Null from an older native side reads as synced.
  bool? timeUnsynced;
}

/// The vehicle's remaining range and the app's SOC-based estimate, side by side.
///
/// Raw as the native side computed it. Every gate — plausible capacity, a
/// known source, a quality the app accepts — is applied in Dart, because those
/// are decisions about what may be shown, not about how a number is spelled.
class RangeEstimateWire {
  RangeEstimateWire({
    required this.timestampMillis,
    required this.carRangeQuality,
    required this.carRangePropertyId,
    required this.capacityKwh,
    required this.capacitySource,
    required this.efficiencyTripCount,
    required this.ownRangeQuality,
    this.carRangeKm,
    this.carRangeReason,
    this.carRangeSignalSource,
    this.carRangeReceivedAtUtcMillis,
    this.carRangeSourceTimestampNanos,
    this.socPercent,
    this.efficiencyKmPerKwh,
    this.efficiencySource,
    this.efficiencyWindowDays,
    this.efficiencyDistanceKm,
    this.efficiencyNetEnergyKwh,
    this.efficiencyUpdatedAtUtcMillis,
    this.fullRangeKm,
    this.ownRangeKm,
    this.ownRangeReason,
  });

  int timestampMillis;
  String carRangeQuality;
  int carRangePropertyId;
  double capacityKwh;
  String capacitySource;
  int efficiencyTripCount;
  String ownRangeQuality;
  double? carRangeKm;
  String? carRangeReason;
  String? carRangeSignalSource;
  int? carRangeReceivedAtUtcMillis;
  int? carRangeSourceTimestampNanos;
  double? socPercent;
  double? efficiencyKmPerKwh;
  String? efficiencySource;
  int? efficiencyWindowDays;
  double? efficiencyDistanceKm;
  double? efficiencyNetEnergyKwh;
  int? efficiencyUpdatedAtUtcMillis;
  double? fullRangeKm;
  double? ownRangeKm;
  String? ownRangeReason;
}

/// The GNSS course over ground.
///
/// This car has no usable magnetometer, so a heading exists only while the
/// vehicle moves. `availability` names the reason when `bearingDeg` is null,
/// because a stopped car and a receiver with no sky are different facts and
/// only one of them is a fault.
///
/// `speedMps` and `bearingAccuracyDeg` describe the fix, not the course, so
/// they can be present while `bearingDeg` is not.
class HeadingWire {
  HeadingWire({
    required this.timestampMillis,
    required this.availability,
    this.bearingDeg,
    this.bearingAccuracyDeg,
    this.speedMps,
    this.fixAgeMillis,
  });

  int timestampMillis;
  String availability;
  double? bearingDeg;
  double? bearingAccuracyDeg;
  double? speedMps;
  int? fixAgeMillis;
}

/// One trip, as the list shows it.
///
/// The boot counts the database keeps are absent on purpose. They exist so the
/// native side can reconcile a session that spans a reboot; the app never reads
/// them, and a field on the wire that nobody reads is a field two sides have to
/// keep agreeing about for nothing.
class TripSessionWire {
  TripSessionWire({
    required this.id,
    required this.status,
    required this.startedAtUtcMillis,
    required this.startedAtElapsedNanos,
    required this.createdAtUtcMillis,
    required this.updatedAtUtcMillis,
    this.movementStartedAtUtcMillis,
    this.movementStartedAtElapsedNanos,
    this.endedAtUtcMillis,
    this.endedAtElapsedNanos,
    this.durationMillis,
    this.startSoc,
    this.endSoc,
    this.startOdometerKm,
    this.endOdometerKm,
    this.startGear,
    this.endReason,
    this.capacityWh,
  });

  String id;
  String status;
  int startedAtUtcMillis;
  int startedAtElapsedNanos;
  int createdAtUtcMillis;

  /// Moves with the newest frame while the trip is open, so a list that polls
  /// can tell a row that changed from one that did not.
  int updatedAtUtcMillis;
  int? movementStartedAtUtcMillis;
  int? movementStartedAtElapsedNanos;
  int? endedAtUtcMillis;
  int? endedAtElapsedNanos;

  /// Reconciled across reboots natively; never end minus start on the wall
  /// clock, which a clock correction alone can make wrong.
  int? durationMillis;
  double? startSoc;
  double? endSoc;
  double? startOdometerKm;
  double? endOdometerKm;
  int? startGear;
  String? endReason;
  double? capacityWh;
}

/// One charge, as the list shows it.
class ChargeSessionWire {
  ChargeSessionWire({
    required this.id,
    required this.status,
    required this.plugConnectedAtUtcMillis,
    required this.plugConnectedAtElapsedNanos,
    required this.createdAtUtcMillis,
    required this.updatedAtUtcMillis,
    this.chargeStartedAtUtcMillis,
    this.chargeStartedAtElapsedNanos,
    this.chargeEndedAtUtcMillis,
    this.chargeEndedAtElapsedNanos,
    this.plugDisconnectedAtUtcMillis,
    this.plugDisconnectedAtElapsedNanos,
    this.durationMillis,
    this.startSoc,
    this.endSoc,
    this.startOdometerKm,
    this.endOdometerKm,
    this.plugType,
    this.startPowerKw,
    this.estimatedEnergyKwh,
    this.costPerKwh,
    this.paidAmount,
    this.costCurrency,
    this.startAmbientTempC,
    this.endAmbientTempC,
    this.startLatitude,
    this.startLongitude,
    this.startAltitudeM,
    this.startGpsAccuracyM,
    this.startLocationProvider,
    this.startLocationElapsedRealtimeNanos,
    this.chargeEndReason,
    this.endReason,
  });

  String id;
  String status;
  int plugConnectedAtUtcMillis;
  int plugConnectedAtElapsedNanos;
  int createdAtUtcMillis;
  int updatedAtUtcMillis;
  int? chargeStartedAtUtcMillis;
  int? chargeStartedAtElapsedNanos;
  int? chargeEndedAtUtcMillis;
  int? chargeEndedAtElapsedNanos;
  int? plugDisconnectedAtUtcMillis;
  int? plugDisconnectedAtElapsedNanos;
  int? durationMillis;
  double? startSoc;
  double? endSoc;
  double? startOdometerKm;
  double? endOdometerKm;

  /// The connector the car reported, as its raw enum ordinal. It is vehicle
  /// data, so it crosses untranslated.
  int? plugType;
  double? startPowerKw;

  /// Integrated from DC power, which is the reliable signal while charging.
  /// Trips do not use this route; theirs is SOC-based.
  double? estimatedEnergyKwh;
  double? costPerKwh;
  double? paidAmount;
  String? costCurrency;
  double? startAmbientTempC;
  double? endAmbientTempC;
  double? startLatitude;
  double? startLongitude;
  double? startAltitudeM;
  double? startGpsAccuracyM;
  String? startLocationProvider;
  int? startLocationElapsedRealtimeNanos;
  String? chargeEndReason;
  String? endReason;
}

/// What separates two charges the detector split but a driver would call one.
class ChargeMergeBreakWire {
  ChargeMergeBreakWire({
    required this.previousSessionId,
    required this.nextSessionId,
    required this.gapMillis,
    this.socDelta,
    this.odometerDeltaKm,
  });

  String previousSessionId;
  String nextSessionId;
  int gapMillis;
  double? socDelta;
  double? odometerDeltaKm;
}

/// A run of charges that look like one session, with the evidence for saying so.
class ChargeMergeCandidateWire {
  ChargeMergeCandidateWire({
    required this.sessionIds,
    required this.sessions,
    required this.breaks,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.durationMillis,
    required this.totalFrames,
    this.startSoc,
    this.endSoc,
    this.startOdometerKm,
    this.endOdometerKm,
  });

  List<String> sessionIds;
  List<ChargeSessionWire> sessions;

  /// The gaps, so the reader can judge the suggestion instead of trusting it.
  List<ChargeMergeBreakWire> breaks;
  int startUtcMillis;
  int endUtcMillis;
  int durationMillis;
  int totalFrames;
  double? startSoc;
  double? endSoc;
  double? startOdometerKm;
  double? endOdometerKm;
}

class ChargeMergeCandidatesWire {
  ChargeMergeCandidatesWire({
    required this.candidates,
    required this.totalCount,
    required this.limit,
  });

  List<ChargeMergeCandidateWire> candidates;
  int totalCount;
  int limit;
}

class ChargeMergeResultWire {
  ChargeMergeResultWire({
    required this.ok,
    required this.mergedCount,
    required this.framesReassigned,
    required this.deletedSessions,
    this.error,
    this.mergedSessionId,
  });

  bool ok;
  int mergedCount;
  int framesReassigned;
  int deletedSessions;
  String? error;
  String? mergedSessionId;
}

class ChargeSessionCostUpdateWire {
  ChargeSessionCostUpdateWire({
    required this.ok,
    required this.updatedRows,
    this.session,
  });

  bool ok;
  int updatedRows;

  /// The row as it stands after the write, so the screen shows what was stored
  /// rather than what was asked for.
  ChargeSessionWire? session;
}

/// One battery cycle, as the list shows it.
///
/// A cycle is one equivalent full cycle: it closes when the SOC removed by
/// trips reaches 100 %. The boundary is in SOC percent, never in kWh;
/// parked SOC loss counts but does not move the boundary.
///
/// The pack blend a cycle opened with is absent on purpose. It exists so a
/// refresh can resume the fold at any cycle; no reader shows it, and a field on
/// the wire that nobody reads is a field two sides have to keep agreeing about
/// for nothing.
class BatteryCycleWire {
  BatteryCycleWire({
    required this.ordinal,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.dischargePercent,
    required this.distanceKm,
    required this.tripEnergyKwh,
    required this.parkedEnergyKwh,
    required this.parkedSocPercent,
    required this.pricedEnergyKwh,
    required this.unpricedEnergyKwh,
    required this.isOpen,
    required this.isPartial,
    required this.energyIncomplete,
    required this.mixedCurrency,
    required this.updatedAtUtcMillis,
    this.cost,
    this.costCurrency,
    this.frozenAtUtcMillis,
  });

  /// The identity, counting from 1 at the oldest cycle.
  int ordinal;
  int startUtcMillis;
  int endUtcMillis;

  /// How full the bar is, 0 to 100. Below 100 only for the open cycle.
  double dischargePercent;
  double distanceKm;
  double tripEnergyKwh;

  /// Counted against the money ledger, but it never moved the boundary, so the
  /// bar keeps answering how far one full battery goes.
  double parkedEnergyKwh;
  double parkedSocPercent;
  double pricedEnergyKwh;
  double unpricedEnergyKwh;
  bool isOpen;

  /// Collection began in the middle of this battery, so it is not a whole one.
  bool isPartial;

  /// Some interval had no trustworthy capacity, so the energy is a floor and
  /// not a total.
  bool energyIncomplete;

  /// Charges of two currencies fed this cycle, so it has no cost: adding them
  /// would invent a number.
  bool mixedCurrency;
  int updatedAtUtcMillis;
  double? cost;
  String? costCurrency;

  /// When the sessions behind this cycle were found to be gone.
  ///
  /// A frozen cycle cannot be folded again, so its cost is final rather than
  /// current. The reader needs the two apart before it adds them together.
  int? frozenAtUtcMillis;
}

/// What kind of session one cycle member is.
enum BatteryCycleSessionKindWire { trip, charge, parked }

/// One session's part in one battery cycle.
///
/// The membership is written by the fold, not recovered from the clock: a trip
/// that crosses the 100 % mark belongs to **two** cycles, and by how much is a
/// fact only the ledger knows.
class BatteryCycleSessionWire {
  BatteryCycleSessionWire({
    required this.kind,
    required this.sessionId,
    required this.share,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.deleted,
    this.trip,
    this.charge,
  });

  BatteryCycleSessionKindWire kind;
  String sessionId;

  /// How much of the session this cycle took, 0 to 1. It is below 1 only for a
  /// trip split across a cycle boundary, and the shares of one session over its
  /// cycles sum to 1.
  double share;

  /// The session's own window, copied when the cycle was folded. It is what is
  /// left when the session itself is deleted.
  int startUtcMillis;
  int endUtcMillis;

  /// The session row is gone: retention deleted it and the cycle outlived it.
  /// The member stays, because it is part of what the cycle counted.
  bool deleted;

  /// The session itself, for the kind it is. A parked session has no list row,
  /// so both stay null for one and [deleted] is all there is to read.
  TripSessionWire? trip;
  ChargeSessionWire? charge;
}

class BatteryCycleSessionsWire {
  BatteryCycleSessionsWire({required this.ordinal, required this.sessions});

  int ordinal;

  /// Oldest first. Empty for a frozen cycle: its sessions were deleted before
  /// the membership was recorded, and nothing can reconstruct them.
  List<BatteryCycleSessionWire> sessions;
}

class BatteryCyclesWire {
  BatteryCyclesWire({
    required this.cycles,
    required this.totalCount,
    required this.limit,
  });

  List<BatteryCycleWire> cycles;
  int totalCount;
  int limit;
}

/// The raw session fields the Insights engine receives for one trip.
///
/// Native Room session aggregates plus minute bucket presence and segments.
/// There is no frame list and no GPS: retention must not be able to change an insight.
class InsightTripWire {
  InsightTripWire({
    required this.id,
    required this.hasMinuteBuckets,
    this.endedAtUtcMillis,
    this.rollupDistanceKm,
    this.startOdometerKm,
    this.endOdometerKm,
    this.rollupTractionWh,
    this.rollupRegenWh,
    this.rollupAuxiliaryWh,
    this.socAgreesWithIntegral,
    this.startLatitude,
    this.startLongitude,
    this.endLatitude,
    this.endLongitude,
    this.path,
    this.meanAmbientTempC,
  });

  String id;
  int? endedAtUtcMillis;
  double? rollupDistanceKm;
  double? startOdometerKm;
  double? endOdometerKm;
  double? rollupTractionWh;
  double? rollupRegenWh;
  double? rollupAuxiliaryWh;
  String? socAgreesWithIntegral;
  bool hasMinuteBuckets;

  /// Trip ends from persisted segments, never from frames.
  double? startLatitude;
  double? startLongitude;
  double? endLatitude;
  double? endLongitude;

  /// `lat,lon;lat,lon` from the segments.
  String? path;

  /// Mean outside temperature from the session aggregate.
  double? meanAmbientTempC;
}

/// A place the driver named.
///
/// [name] is the user's label; [autoName] is the companion suggestion and
/// never overwrites [name] on display. Both travel over the Pigeon wire so
/// the car can show the suggestion as read-only.
class InsightPlaceWire {
  InsightPlaceWire({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusM,
    this.autoName,
    this.autoNameUpdatedAtUtcMillis,
    this.autoNameSource,
  });

  String id;
  String name;
  double latitude;
  double longitude;
  double radiusM;
  String? autoName;
  int? autoNameUpdatedAtUtcMillis;
  String? autoNameSource;
}

class InsightPlacesWire {
  InsightPlacesWire({required this.places});

  List<InsightPlaceWire> places;
}

/// Closed trips for one comparison, including [subjectId] when it is set.
class InsightTripsWire {
  InsightTripsWire({required this.trips, this.subjectId});

  List<InsightTripWire> trips;
  String? subjectId;
}

/// A change to the recorded sessions.
///
// --- Layer 3 TelemetryStore Wire Models -------------------------------------

class SessionFilterWire {
  SessionFilterWire({
    this.kind,
    this.fromUtcMillis,
    this.toUtcMillis,
    this.status,
  });
  String? kind;
  int? fromUtcMillis;
  int? toUtcMillis;
  String? status;
}

class PageRequestWire {
  PageRequestWire({required this.limit, required this.offset});
  int limit;
  int offset;
}

class MeasurementWire {
  MeasurementWire({
    this.value,
    required this.unit,
    required this.validity,
    required this.note,
  });
  double? value;
  String unit;
  String validity;
  String note;
}

class SessionRollupWire {
  SessionRollupWire({
    required this.distance,
    required this.traction,
    required this.regen,
    required this.auxiliary,
    required this.climate,
    required this.delivered,
    required this.integratedSeconds,
  });
  MeasurementWire distance;
  MeasurementWire traction;
  MeasurementWire regen;
  MeasurementWire auxiliary;
  MeasurementWire climate;
  MeasurementWire delivered;
  MeasurementWire integratedSeconds;
}

class SessionRecordWire {
  SessionRecordWire({
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
    required this.noLongerReducible,
    required this.createdAtUtcMillis,
    required this.updatedAtUtcMillis,
    this.climbM,
    this.descentM,
    this.fixCount,
    this.sleepSeconds,
    this.sleepSocDeltaPercent,
    this.sleepEnergyWhEstimate,
  });
  String id;
  String vehicleId;
  String kind;
  String status;
  int startedAtUtcMillis;
  int startedAtElapsedNanos;
  int? startedAtBootCount;
  int? endedAtUtcMillis;
  int? endedAtElapsedNanos;
  int? endedAtBootCount;
  int? durationMillis;
  SessionRollupWire rollup;
  MeasurementWire startOdometer;
  MeasurementWire endOdometer;
  MeasurementWire startSoc;
  MeasurementWire endSoc;
  MeasurementWire minSoc;
  MeasurementWire maxSoc;
  String? socAgreesWithIntegral;
  MeasurementWire startAmbientTemp;
  MeasurementWire endAmbientTemp;
  MeasurementWire meanAmbientTemp;
  int? plugType;
  double? costPerKwh;
  double? paidAmount;
  String? costCurrency;
  int? chargeStartedAtUtcMillis;
  int? chargeEndedAtUtcMillis;
  int? plugDisconnectedAtUtcMillis;
  int? movementStartedAtUtcMillis;
  String? chargeEndReason;
  String? endReason;
  double? startLatitude;
  double? startLongitude;
  double? startAltitudeM;
  double? startGpsAccuracyM;

  /// The gear the drive started in, as the car's own code. A count, not a name.
  int? startGear;

  /// The charge power at the first reading of a charge, kW.
  double? startPowerKw;
  int? movementStartedAtElapsedNanos;
  int? movementStartedAtBootCount;
  int? chargeStartedAtElapsedNanos;
  int? chargeStartedAtBootCount;
  int? chargeEndedAtElapsedNanos;
  int? chargeEndedAtBootCount;
  int? plugDisconnectedAtElapsedNanos;
  int? plugDisconnectedAtBootCount;
  bool noLongerReducible;
  int createdAtUtcMillis;
  int updatedAtUtcMillis;

  /// The climb and the descent, summed once from the Track at session close.
  /// Null on a session recorded before this column existed.
  double? climbM;
  double? descentM;

  /// How many position fixes the drive holds. Null before this column
  /// existed.
  int? fixCount;

  /// The reconstructed overnight-drain estimate a `PARKED` session carries
  /// behind five sanity gates, or null when none applies.
  int? sleepSeconds;
  double? sleepSocDeltaPercent;
  double? sleepEnergyWhEstimate;
}

class SessionListPageWire {
  SessionListPageWire({
    required this.sessions,
    required this.totalCount,
    required this.limit,
    required this.offset,
    required this.hasMore,
  });
  List<SessionRecordWire> sessions;
  int totalCount;
  int limit;
  int offset;
  bool hasMore;
}

class TelemetryEventRecordWire {
  TelemetryEventRecordWire({
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
    required this.details,
  });
  int id;
  String? sessionId;
  String type;
  int occurredAtUtcMillis;
  int occurredAtElapsedNanos;
  String? signalKey;
  String? value;
  String? previousValue;
  String? quality;
  String? source;
  String details;
}

class TrackRowWire {
  TrackRowWire({
    required this.encodingVersion,
    required this.pointCount,
    required this.path,
    required this.t,
    required this.speed,
    required this.alt,
  });
  int encodingVersion;
  int pointCount;
  String path;
  String t;
  String speed;
  String alt;
}

class SessionDetailWire {
  SessionDetailWire({required this.session, required this.events, this.track});
  SessionRecordWire session;
  List<TelemetryEventRecordWire> events;
  TrackRowWire? track;
}

class IntervalRecordWire {
  IntervalRecordWire({
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
    this.startSoc,
    this.endSoc,
    this.startVoltage,
    this.endVoltage,
    this.startElapsedNanos,
    this.startBootCount,
    this.timeState,
  });
  String sessionId;
  int startUtcMillis;
  int widthMillis;
  MeasurementWire traction;
  MeasurementWire regen;
  MeasurementWire auxiliary;
  MeasurementWire climate;
  MeasurementWire delivered;
  MeasurementWire distance;
  double coveredSeconds;
  double climateCoveredSeconds;
  double speedCoveredSeconds;
  double deliveredCoveredSeconds;
  MeasurementWire? startSoc;
  MeasurementWire? endSoc;
  MeasurementWire? startVoltage;
  MeasurementWire? endVoltage;
  int? startElapsedNanos;
  int? startBootCount;
  String? timeState;
}

class SamplePointWire {
  SamplePointWire({
    required this.tUtcMillis,
    required this.tElapsedNanos,
    this.bootCount,
    required this.value,
    this.groupId,
  });
  int tUtcMillis;
  int tElapsedNanos;
  int? bootCount;
  MeasurementWire value;
  String? groupId;
}

class SampleSeriesWire {
  SampleSeriesWire({required this.key, required this.points});
  String key;
  List<SamplePointWire> points;
}

class TelemetrySeriesWire {
  TelemetrySeriesWire({
    required this.sessionId,
    required this.intervals,
    required this.sampleSeries,
  });
  String sessionId;
  List<IntervalRecordWire> intervals;
  List<SampleSeriesWire> sampleSeries;
}

/// This says *that* something changed, not what it now is. The reader re-reads
/// the list it is showing; pushing the rows here would be a second route to the
/// same data, and the two would answer differently the first time one of them
/// was changed alone.
class SessionChangeWire {
  SessionChangeWire({
    required this.revision,
    required this.trips,
    required this.charges,
    required this.parked,
  });

  /// Rises on every change. A reader that missed an event can tell.
  int revision;

  /// A trip row was written, closed or removed.
  bool trips;

  /// A charge row was written, closed, merged or priced.
  bool charges;

  /// A parked row was written or closed.
  bool parked;
}

class AnnotationChangeWire {
  AnnotationChangeWire({
    required this.revision,
    required this.places,
    required this.preferences,
    required this.sessionCosts,
    required this.proposals,
    required this.journeys,
  });

  /// Rises on every annotation change. A reader that missed an event can tell.
  int revision;

  /// A place row was written or deleted.
  bool places;

  /// A preference row was written or deleted.
  bool preferences;

  /// A charge cost row was written.
  bool sessionCosts;

  /// A preference proposal was created or decided.
  bool proposals;

  /// A journey row was written or deleted.
  bool journeys;
}

/// Pushes from the car, rather than answers to a question.
@EventChannelApi()
abstract class TelemetryWireEvents {
  /// Fires when a session is written, closed, merged or priced.
  ///
  /// It does **not** fire per frame. The values an open row shows — its newest
  /// SOC and odometer — come from frames at about 1 Hz, so a list with an open
  /// session still polls for those. A list with nothing open has nothing to
  /// poll for and waits here instead.
  SessionChangeWire sessionsChanged();

  /// Fires when an annotation row — a place, a preference, a charge cost or a
  /// proposal — was written, merged or deleted. The reader re-reads the
  /// surface it shows.
  AnnotationChangeWire annotationsChanged();
}

@HostApi()
abstract class TelemetryWireApi {
  /// The per-minute series over a window of clock.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  EnergyWindowBucketsWire getEnergyBucketsInWindow(int minutes);

  /// The same window, over parked sessions instead of trips.
  ///
  /// A separate call rather than a flag on the one above, because the two are
  /// answers to different questions and a screen shows one or the other. An
  /// empty reply means the car was not parked in that window; it never means
  /// the car was parked and drew nothing.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  EnergyWindowBucketsWire getParkedEnergyBucketsInWindow(int minutes);

  /// The minute in progress and the last few closed ones. Memory only, so this
  /// is cheap enough to poll every second.
  LiveEnergyBucketsWire getLiveEnergyBuckets();

  /// The same integral cut ten seconds wide, for the efficiency card.
  LiveEnergyBucketsWire getLiveEfficiencyBuckets();

  /// The open charge's climate minutes, in memory.
  ///
  /// A charge integrates climate power alone, so these buckets carry
  /// `climateWh` and nothing else — during a charge the pack term is the
  /// charging current, and the `pack - drive` remainder that names the
  /// auxiliary load on a trip does not exist. A reader must not treat a zero
  /// `tractionWh` here as a measurement.
  LiveEnergyBucketsWire getLiveChargeEnergyBuckets();

  /// The `CONTINUOUS` session's newest minutes, in memory.
  ///
  /// Empty with the mode off. Otherwise the same shape as
  /// [getLiveEnergyBuckets]: the minute in progress plus a few closed ones,
  /// cheap enough to poll every second.
  LiveEnergyBucketsWire getLiveContinuousEnergyBuckets();

  /// The car's range and the app's estimate. Read from the signal store and an
  /// in-memory efficiency cache, never from the database.
  RangeEstimateWire getRangeEstimate();

  /// The GNSS course over ground, from the last fix held in memory. It reads
  /// no database and no vehicle property, so it stays on the platform thread.
  HeadingWire getHeading();

  /// The battery cycles, newest first.
  ///
  /// The read folds any session closed since the last one, so the open cycle is
  /// current. It blocks on the database and on that fold.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  BatteryCyclesWire getBatteryCycles(int limit);

  /// The sessions one cycle counted, oldest first.
  ///
  /// It does not fold first: the membership is written with the cycle, so
  /// asking about a cycle already on screen cannot need a fold. It still reads
  /// the session tables to resolve each member, so it blocks.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  BatteryCycleSessionsWire getBatteryCycleSessions(int ordinal);

  /// Closed trips the comparison engine may read.
  ///
  /// The last 30 days, plus [subjectId] when it is set and not already in
  /// that window. The reply is session aggregates and whether each trip has
  /// minute buckets. It never reads a frame, so retention cannot change it.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  InsightTripsWire getInsightTrips(String? subjectId);

  /// Places the driver has named. The app never invents these.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  InsightPlacesWire getInsightPlaces();

  /// Names a place at a coordinate. [id] is set when renaming an existing one.
  ///
  /// [autoName] is nullable and additive: existing rows without it stay valid,
  /// and the car's display falls back to it when [name] is empty.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  InsightPlaceWire saveInsightPlace(
    String? id,
    String name,
    double latitude,
    double longitude,
    double radiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  );

  /// Removes a named place. Trips are not deleted.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void deleteInsightPlace(String id);

  /// Runs of charges that look like one session.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ChargeMergeCandidatesWire getChargeMergeCandidates(int limit);

  /// Merges a run into one session.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ChargeMergeResultWire mergeChargeSessions(List<String> sessionIds);

  /// Prices a charge. The reply is the stored row, not the request.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ChargeSessionCostUpdateWire updateChargeSessionCost(
    String sessionId,
    double? costPerKwh,
    double? paidAmount,
    String currency,
  );

  /// Layer 3 Store: Question 1 — listSessions.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  SessionListPageWire storeListSessions(
    SessionFilterWire? filter,
    PageRequestWire? page,
  );

  /// Layer 3 Store: Question 2 — session(id).
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  SessionDetailWire? storeGetSession(String id);

  /// Layer 3 Store: Question 3 — series(id, keys, width).
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  TelemetrySeriesWire storeGetSeries(
    String id,
    List<String>? keys,
    int? widthMillis,
  );

  /// The synced preference rows the car holds, live and tombstones apart.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<PreferenceRowWire> getPreferenceRows();

  /// Writes one preference row from the car's own edit. Only a synced key may
  /// be written this way; an unknown key answers null.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  PreferenceRowWire? savePreferenceRow(String scope, String key, String? value);

  /// The pending preference proposals the settings show as prompts.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<PreferenceProposalWire> getPreferenceProposals();

  /// Proposes a value for a car-only preference key. The proposal is inert
  /// until a person on the car accepts it.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  PreferenceProposalWire? proposePreference(String key, String? value);

  /// The car decides. Acceptance runs the normal write path; a write that
  /// cannot run becomes a refusal.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  PreferenceProposalWire? decidePreferenceProposal(String id, bool accept);
}

class PreferenceRowWire {
  PreferenceRowWire({
    required this.scope,
    required this.key,
    this.value,
    required this.updatedAtUtcMillis,
    required this.origin,
    this.deletedAtUtcMillis,
  });
  String scope;
  String key;
  String? value;
  int updatedAtUtcMillis;
  String origin;
  int? deletedAtUtcMillis;
}

class PreferenceProposalWire {
  PreferenceProposalWire({
    required this.id,
    required this.key,
    this.value,
    required this.status,
    required this.proposedAtUtcMillis,
    required this.updatedAtUtcMillis,
    required this.origin,
    this.decidedAtUtcMillis,
  });
  String id;
  String key;
  String? value;
  String status;
  int proposedAtUtcMillis;
  int updatedAtUtcMillis;
  String origin;
  int? decidedAtUtcMillis;
}
