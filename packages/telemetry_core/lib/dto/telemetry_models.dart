part of 'telemetry_dto.dart';

class HvacCommandResult {
  const HvacCommandResult({
    required this.ok,
    required this.action,
    required this.currentValue,
    required this.requestedValue,
    required this.appliedValue,
    required this.temperatureC,
    required this.fanSpeed,
    required this.propertyIdHex,
    required this.areaId,
    required this.details,
    required this.timestampMillis,
  });

  factory HvacCommandResult.fromMap(Map<String, Object?> map) {
    return HvacCommandResult(
      ok: map['ok'] == true,
      action: _asString(map['action'], 'unknown'),
      currentValue: _asDouble(map['currentValue']),
      requestedValue: _asDouble(map['requestedValue']),
      appliedValue: _asDouble(map['appliedValue']),
      temperatureC: _asDouble(map['temperatureC']),
      fanSpeed: _asInt(map['fanSpeed']),
      propertyIdHex: _asStringOrNull(map['propertyIdHex']),
      areaId: _asInt(map['areaId']),
      details: _asStringList(map['details']),
      timestampMillis: _asInt(map['timestampMillis']) ?? 0,
    );
  }

  final bool ok;
  final String action;
  final double? currentValue;
  final double? requestedValue;
  final double? appliedValue;
  final double? temperatureC;
  final int? fanSpeed;
  final String? propertyIdHex;
  final int? areaId;
  final List<String> details;
  final int timestampMillis;
}

class HistoryTimelineDay {
  const HistoryTimelineDay({
    required this.dayStartUtcMillis,
    required this.label,
    required this.blocks,
  });

  factory HistoryTimelineDay.fromMap(Map<String, Object?> map) {
    return HistoryTimelineDay(
      dayStartUtcMillis: _asInt(map['dayStartUtcMillis']) ?? 0,
      label: _asString(map['label'], '--'),
      blocks: _asMapList(
        map['blocks'],
      ).map(HistoryTimelineBlock.fromMap).toList(growable: false),
    );
  }

  final int dayStartUtcMillis;
  final String label;
  final List<HistoryTimelineBlock> blocks;
}

class HistoryTimelineBlock {
  const HistoryTimelineBlock({
    required this.type,
    required this.sessionId,
    required this.startFraction,
    required this.endFraction,
    required this.startUtcMillis,
    required this.endUtcMillis,
  });

  factory HistoryTimelineBlock.fromMap(Map<String, Object?> map) {
    return HistoryTimelineBlock(
      type: _asString(map['type'], 'UNKNOWN'),
      sessionId: _asString(map['sessionId']),
      startFraction: _asDouble(map['startFraction']) ?? 0,
      endFraction: _asDouble(map['endFraction']) ?? 0,
      startUtcMillis: _asInt(map['startUtcMillis']) ?? 0,
      endUtcMillis: _asInt(map['endUtcMillis']) ?? 0,
    );
  }

  final String type;
  final String sessionId;
  final double startFraction;
  final double endFraction;
  final int startUtcMillis;
  final int endUtcMillis;
}

class HistorySessionRow {
  const HistorySessionRow({
    required this.id,
    required this.type,
    required this.status,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.durationMillis,
    required this.socStart,
    required this.socEnd,
    required this.socDeltaPercent,
    required this.distanceKm,
    required this.energyKwh,
    required this.efficiencyWhPerKm,
    required this.reason,
  });

  factory HistorySessionRow.fromMap(Map<String, Object?> map) {
    return HistorySessionRow(
      id: _asString(map['id']),
      type: _asString(map['type'], 'UNKNOWN'),
      status: _asString(map['status'], 'UNKNOWN'),
      startUtcMillis: _asInt(map['startUtcMillis']) ?? 0,
      endUtcMillis: _asInt(map['endUtcMillis']) ?? 0,
      durationMillis: _asInt(map['durationMillis']) ?? 0,
      socStart: _asDouble(map['socStart']),
      socEnd: _asDouble(map['socEnd']),
      socDeltaPercent: _asDouble(map['socDeltaPercent']),
      distanceKm: _asDouble(map['distanceKm']),
      energyKwh: _asDouble(map['energyKwh']),
      efficiencyWhPerKm: _asDouble(map['efficiencyWhPerKm']),
      reason: _asStringOrNull(map['reason']),
    );
  }

  final String id;
  final String type;
  final String status;
  final int startUtcMillis;
  final int endUtcMillis;
  final int durationMillis;
  final double? socStart;
  final double? socEnd;
  final double? socDeltaPercent;
  final double? distanceKm;
  final double? energyKwh;
  final double? efficiencyWhPerKm;
  final String? reason;
}

class TelemetryRetentionResult {
  const TelemetryRetentionResult({
    required this.ok,
    required this.skipped,
    required this.reason,
    required this.retentionDays,
    required this.cutoffUtcMillis,
    required this.aggregatesUpserted,
    required this.telemetryFramesDeleted,
    required this.telemetryEventsDeleted,
    required this.lastRunUtcMillis,
    required this.timestampMillis,
  });

  factory TelemetryRetentionResult.fromMap(Map<String, Object?> map) {
    return TelemetryRetentionResult(
      ok: map['ok'] == true,
      skipped: map['skipped'] == true,
      reason: _asStringOrNull(map['reason']),
      retentionDays: _asInt(map['retentionDays']) ?? 0,
      cutoffUtcMillis: _asInt(map['cutoffUtcMillis']) ?? 0,
      aggregatesUpserted: _asInt(map['aggregatesUpserted']) ?? 0,
      telemetryFramesDeleted: _asInt(map['telemetryFramesDeleted']) ?? 0,
      telemetryEventsDeleted: _asInt(map['telemetryEventsDeleted']) ?? 0,
      lastRunUtcMillis: _asInt(map['lastRunUtcMillis']) ?? 0,
      timestampMillis: _asInt(map['timestampMillis']) ?? 0,
    );
  }

  final bool ok;
  final bool skipped;
  final String? reason;
  final int retentionDays;
  final int cutoffUtcMillis;
  final int aggregatesUpserted;
  final int telemetryFramesDeleted;
  final int telemetryEventsDeleted;
  final int lastRunUtcMillis;
  final int timestampMillis;
}

class TelemetrySettingsResult {
  const TelemetrySettingsResult({
    required this.autoStartOnBoot,
    required this.gpsEnabled,
    required this.keepBluetoothOn,
    required this.debugEventFileEnabled,
    required this.temperatureModeHelperEnabled,
    required this.replaceOemChargingEnabled,
    this.externalChargeControlEnabled = false,
    this.chargeTargetSoc = 80,
    this.continuousModeEnabled = false,
    required this.defaultChargeCostPerKwh,
    required this.packCapacityWh,
    required this.chargeCostCurrency,
  });

  factory TelemetrySettingsResult.fromMap(Map<String, Object?> map) {
    return TelemetrySettingsResult(
      autoStartOnBoot: _asBool(map['autoStartOnBoot'], orElse: true),
      gpsEnabled: _asBool(map['gpsEnabled'], orElse: false),
      keepBluetoothOn: _asBool(map['keepBluetoothOnEnabled'], orElse: false),
      debugEventFileEnabled: _asBool(
        map['debugEventFileEnabled'],
        orElse: false,
      ),
      temperatureModeHelperEnabled: _asBool(
        map['temperatureModeHelperEnabled'],
        orElse: false,
      ),
      replaceOemChargingEnabled: _asBool(
        map['replaceOemChargingEnabled'],
        orElse: false,
      ),
      externalChargeControlEnabled: _asBool(
        map['externalChargeControlEnabled'],
        orElse: false,
      ),
      chargeTargetSoc: (map['chargeTargetSoc'] as num?)?.toInt() ?? 80,
      continuousModeEnabled: _asBool(
        map['continuousModeEnabled'],
        orElse: false,
      ),
      defaultChargeCostPerKwh: _asDouble(map['defaultChargeCostPerKwh']),
      packCapacityWh:
          _asDouble(map['packCapacityWh']) ?? kDefaultPackCapacityWh,
      chargeCostCurrency: _asString(map['chargeCostCurrency'], 'BRL'),
    );
  }

  final bool autoStartOnBoot;
  final bool gpsEnabled;

  /// The car keeps its Bluetooth radio on for the companion live stream.
  ///
  /// The head unit switches the radio off on its own, and the BLE stream dies
  /// with it. Off by default: an app does not take a car radio unasked.
  final bool keepBluetoothOn;
  final bool debugEventFileEnabled;
  final bool temperatureModeHelperEnabled;
  final bool replaceOemChargingEnabled;
  final bool externalChargeControlEnabled;
  final int chargeTargetSoc;

  /// Opt-in CONTINUOUS recording: one minute of energy for every minute the
  /// car is awake, gated on nothing. Off by default.
  final bool continuousModeEnabled;
  final double? defaultChargeCostPerKwh;

  /// The pack the app computes every energy figure against, in Wh.
  ///
  /// It is never null. The car publishes no capacity that can be believed, so
  /// the reader states one and an unset setting means the default pack rather
  /// than an unknown pack.
  final double packCapacityWh;

  final String chargeCostCurrency;
}

class ChargeControlAppStatus {
  const ChargeControlAppStatus({
    required this.installed,
    this.installedVersionName,
    this.installedVersionCode,
    this.availableVersionName,
    this.availableVersionCode,
    this.updateAvailable = false,
    this.installScheduled = false,
    this.error,
  });

  factory ChargeControlAppStatus.fromMap(Map<String, Object?> map) {
    return ChargeControlAppStatus(
      installed: _asBool(map['installed'], orElse: false),
      installedVersionName: _asStringOrNull(map['installedVersionName']),
      installedVersionCode: _asInt(map['installedVersionCode']),
      availableVersionName: _asStringOrNull(map['availableVersionName']),
      availableVersionCode: _asInt(map['availableVersionCode']),
      updateAvailable: _asBool(map['updateAvailable'], orElse: false),
      installScheduled: _asBool(map['installScheduled'], orElse: false),
      error: _asStringOrNull(map['error']),
    );
  }

  final bool installed;
  final String? installedVersionName;
  final int? installedVersionCode;
  final String? availableVersionName;
  final int? availableVersionCode;
  final bool updateAvailable;
  final bool installScheduled;
  final String? error;
}

/// What the external charge control app reports the car holds.
///
/// [amps] is a read-back, never a request. It stays null until the vehicle
/// reports a current, so a value the car refused is never shown as if it had
/// been applied.
class ChargeControlState {
  const ChargeControlState({
    this.targetSoc = 80,
    this.amps,
    this.minAmps = 5,
    this.maxAmps = 32,
    this.forceCharging = false,
    this.lastCommandOk = true,
    this.lastError,
  });

  factory ChargeControlState.fromMap(Map<String, Object?> map) {
    return ChargeControlState(
      targetSoc: _asInt(map['targetSoc']) ?? 80,
      amps: _asInt(map['amps']),
      minAmps: _asInt(map['minAmps']) ?? 5,
      maxAmps: _asInt(map['maxAmps']) ?? 32,
      forceCharging: _asBool(map['forceCharging'], orElse: false),
      lastCommandOk: _asBool(map['lastCommandOk'], orElse: true),
      lastError: map['lastError'] as String?,
    );
  }

  final int targetSoc;
  final int? amps;
  final int minAmps;
  final int maxAmps;
  final bool forceCharging;

  /// Whether the last command the control app answered was applied.
  final bool lastCommandOk;

  /// Why the last command failed, in the control app's own words.
  final String? lastError;

  Map<String, Object?> toMap() => {
    'targetSoc': targetSoc,
    'amps': amps,
    'minAmps': minAmps,
    'maxAmps': maxAmps,
    'forceCharging': forceCharging,
    'lastCommandOk': lastCommandOk,
    'lastError': lastError,
  };
}

/// The pack the app assumes when the reader has stated none, in Wh.
///
/// It is the specification of the car this app was written for. Kotlin holds
/// the same number in `VehicleBatterySpec.DEFAULT_CAPACITY_WH`; this copy
/// exists so a screen can show the default before the collector answers.
const double kDefaultPackCapacityWh = 39600;

/// The band a stated capacity must fall in. Wide on purpose: this is the one
/// setting that lets another car use the app.
const double kMinPackCapacityWh = 5000;
const double kMaxPackCapacityWh = 200000;

/// What the "price the unpriced charges" action did.
///
/// [updatedRows] is zero both when nothing needed a price and when the write
/// failed; [ok] separates the two.
class DefaultChargeCostApplication {
  const DefaultChargeCostApplication({
    required this.ok,
    required this.updatedRows,
    required this.costPerKwh,
    required this.currency,
    required this.error,
  });

  factory DefaultChargeCostApplication.fromMap(Map<String, Object?> map) {
    return DefaultChargeCostApplication(
      ok: _asBool(map['ok'], orElse: false),
      updatedRows: _asInt(map['updatedRows']) ?? 0,
      costPerKwh: _asDouble(map['costPerKwh']),
      currency: _asString(map['currency'], 'BRL'),
      error: map['error'] as String?,
    );
  }

  final bool ok;
  final int updatedRows;
  final double? costPerKwh;
  final String currency;
  final String? error;
}

class ClearTelemetryDatabaseResult {
  const ClearTelemetryDatabaseResult({
    required this.ok,
    required this.telemetryEventsDeleted,
    required this.tripSessionsDeleted,
    required this.chargeSessionsDeleted,
    required this.telemetryFramesDeleted,
    required this.sessionAggregatesDeleted,
    required this.timestampMillis,
  });

  factory ClearTelemetryDatabaseResult.fromMap(Map<String, Object?> map) {
    return ClearTelemetryDatabaseResult(
      ok: map['ok'] == true,
      telemetryEventsDeleted: _asInt(map['telemetryEventsDeleted']) ?? 0,
      tripSessionsDeleted: _asInt(map['tripSessionsDeleted']) ?? 0,
      chargeSessionsDeleted: _asInt(map['chargeSessionsDeleted']) ?? 0,
      telemetryFramesDeleted: _asInt(map['telemetryFramesDeleted']) ?? 0,
      sessionAggregatesDeleted: _asInt(map['sessionAggregatesDeleted']) ?? 0,
      timestampMillis: _asInt(map['timestampMillis']) ?? 0,
    );
  }

  final bool ok;
  final int telemetryEventsDeleted;
  final int tripSessionsDeleted;
  final int chargeSessionsDeleted;
  final int telemetryFramesDeleted;
  final int sessionAggregatesDeleted;
  final int timestampMillis;

  int get totalRowsDeleted =>
      telemetryEventsDeleted +
      tripSessionsDeleted +
      chargeSessionsDeleted +
      telemetryFramesDeleted +
      sessionAggregatesDeleted;
}

class PlatformStatus {
  const PlatformStatus({
    required this.ok,
    required this.platform,
    required this.bridge,
    required this.timestampMillis,
  });

  factory PlatformStatus.fromMap(Map<String, Object?> map) {
    return PlatformStatus(
      ok: map['ok'] == true,
      platform: _asString(map['platform'], 'unknown'),
      bridge: _asString(map['bridge'], 'unknown'),
      timestampMillis: _asInt(map['timestampMillis']) ?? 0,
    );
  }

  final bool ok;
  final String platform;
  final String bridge;
  final int timestampMillis;
}

class CollectorStatus {
  const CollectorStatus({
    required this.running,
    required this.collectorStatus,
    required this.vehicleActivity,
    required this.tripState,
    required this.chargeState,
    required this.callbackSignals,
    required this.pollingSignals,
    required this.lastUpdateMillis,
    required this.signalCount,
    required this.persistence,
  });

  factory CollectorStatus.fromMap(Map<String, Object?> map) {
    return CollectorStatus(
      running: map['running'] == true,
      collectorStatus: _asString(map['collectorStatus'], 'unknown'),
      vehicleActivity: _asString(map['vehicleActivity'], 'UNKNOWN'),
      tripState: _asString(map['tripState'], 'IDLE'),
      chargeState: _asString(map['chargeState'], 'DISCONNECTED'),
      callbackSignals: _asInt(map['callbackSignals']) ?? 0,
      pollingSignals: _asInt(map['pollingSignals']) ?? 0,
      lastUpdateMillis: _asInt(map['lastUpdateMillis']) ?? 0,
      signalCount: _asInt(map['signalCount']) ?? 0,
      persistence: map['persistence'] is Map
          ? _castMap(map['persistence'])
          : const <String, Object?>{},
    );
  }

  final bool running;
  final String collectorStatus;
  final String vehicleActivity;
  final String tripState;
  final String chargeState;
  final int callbackSignals;
  final int pollingSignals;
  final int lastUpdateMillis;
  final int signalCount;
  final Map<String, Object?> persistence;
}

class LiveTelemetryFrame {
  const LiveTelemetryFrame({
    required this.timestampMillis,
    required this.updatedSignalId,
    required this.signals,
    required this.status,
    required this.trip,
    required this.charge,
    required this.location,
    required this.sessions,
    required this.frames,
    required this.helpers,
    required this.recentEvents,
  });

  factory LiveTelemetryFrame.fromMap(Map<String, Object?> map) {
    return LiveTelemetryFrame(
      timestampMillis: _asInt(map['timestampMillis']) ?? 0,
      updatedSignalId: _asStringOrNull(map['updatedSignalId']),
      signals: _liveSignals(map['signals']),
      status: _collectorStatusOrNull(map['status']),
      trip: _castMap(map['trip']),
      charge: _castMap(map['charge']),
      location: _castMap(map['location']),
      sessions: _castMap(map['sessions']),
      frames: _castMap(map['frames']),
      helpers: _castMap(map['helpers']),
      recentEvents: _asEventList(map['recentEvents']),
    );
  }

  final int timestampMillis;
  final String? updatedSignalId;
  final List<LiveSignalSample> signals;
  final CollectorStatus? status;

  /// Raw diagnostic payloads rendered as key-value dumps by the debug screen;
  /// intentionally left untyped.
  final Map<String, Object?> trip;
  final Map<String, Object?> charge;
  final Map<String, Object?> location;
  final Map<String, Object?> sessions;
  final Map<String, Object?> frames;
  final Map<String, Object?> helpers;
  final List<TelemetryEvent> recentEvents;
}

class LiveSignalSample {
  const LiveSignalSample({
    required this.signalId,
    required this.value,
    required this.unit,
    required this.quality,
    required this.source,
    required this.propertyId,
    required this.propertyIdHex,
    required this.areaId,
    required this.timestampMillis,
    required this.sourceTimestampNanos,
    required this.timestamp,
    required this.details,
  });

  factory LiveSignalSample.fromMap(Map<String, Object?> map) {
    return LiveSignalSample(
      signalId: _asString(map['signalId']),
      value: map['value'],
      unit: _asString(map['unit']),
      quality: _asString(map['quality'], 'UNAVAILABLE'),
      source: _asString(map['source'], 'unknown'),
      propertyId: _asInt(map['propertyId']) ?? 0,
      propertyIdHex: _asString(map['propertyIdHex']),
      areaId: _asInt(map['areaId']) ?? 0,
      timestampMillis: _asInt(map['timestampMillis']) ?? 0,
      sourceTimestampNanos: _asInt(map['sourceTimestampNanos']),
      timestamp: _signalTimestampOrNull(map['timestamp']),
      details: _asString(map['details']),
    );
  }

  final String signalId;
  final Object? value;
  final String unit;
  final String quality;
  final String source;
  final int propertyId;
  final String propertyIdHex;
  final int areaId;
  final int timestampMillis;
  final int? sourceTimestampNanos;
  final SignalTimestamp? timestamp;
  final String details;
}

class SignalTimestamp {
  const SignalTimestamp({
    required this.receivedAtUtcMillis,
    required this.receivedAtElapsedNanos,
    required this.sourceTimestampNanos,
    required this.accuracy,
    required this.uncertaintyMillis,
  });

  factory SignalTimestamp.fromMap(Map<String, Object?> map) {
    return SignalTimestamp(
      receivedAtUtcMillis: _asInt(map['receivedAtUtcMillis']) ?? 0,
      receivedAtElapsedNanos: _asInt(map['receivedAtElapsedNanos']) ?? 0,
      sourceTimestampNanos: _asInt(map['sourceTimestampNanos']),
      accuracy: _asString(map['accuracy'], 'RECEIVED_EVENT'),
      uncertaintyMillis: _asInt(map['uncertaintyMillis']) ?? 0,
    );
  }

  final int receivedAtUtcMillis;
  final int receivedAtElapsedNanos;
  final int? sourceTimestampNanos;
  final String accuracy;
  final int uncertaintyMillis;
}

class TelemetryEvent {
  const TelemetryEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.signalId,
    required this.value,
    required this.previousValue,
    required this.quality,
    required this.source,
    required this.details,
  });

  factory TelemetryEvent.fromMap(Map<String, Object?> map) {
    return TelemetryEvent(
      id: _asString(map['id']),
      type: _asString(map['type']),
      timestamp: _signalTimestampOrNull(map['timestamp']),
      signalId: _asStringOrNull(map['signalId']),
      value: map['value'],
      previousValue: map['previousValue'],
      quality: _asStringOrNull(map['quality']),
      source: _asStringOrNull(map['source']),
      details: _asString(map['details']),
    );
  }

  final String id;
  final String type;
  final SignalTimestamp? timestamp;
  final String? signalId;
  final Object? value;
  final Object? previousValue;
  final String? quality;
  final String? source;
  final String details;
}

class TelemetryEventsResult {
  const TelemetryEventsResult({
    required this.events,
    required this.eventFile,
    required this.database,
    required this.databaseInsertedThisRun,
  });

  factory TelemetryEventsResult.fromMap(Map<String, Object?> map) {
    return TelemetryEventsResult(
      events: _asEventList(map['events']),
      eventFile: _asString(map['eventFile']),
      database: _asString(map['database']),
      databaseInsertedThisRun: _asInt(map['databaseInsertedThisRun']) ?? 0,
    );
  }

  final List<TelemetryEvent> events;
  final String eventFile;
  final String database;
  final int databaseInsertedThisRun;
}

class ChargeMergeCandidatesResult {
  const ChargeMergeCandidatesResult({
    required this.candidates,
    required this.totalCount,
    required this.limit,
  });

  factory ChargeMergeCandidatesResult.fromMap(Map<String, Object?> map) {
    return ChargeMergeCandidatesResult(
      candidates: _asMapList(
        map['candidates'],
      ).map(ChargeMergeCandidate.fromMap).toList(growable: false),
      totalCount: _asInt(map['totalCount']) ?? 0,
      limit: _asInt(map['limit']) ?? 0,
    );
  }

  /// From the generated wire class.
  factory ChargeMergeCandidatesResult.fromWire(ChargeMergeCandidatesWire wire) {
    return ChargeMergeCandidatesResult(
      candidates: List.unmodifiable(
        wire.candidates.map(ChargeMergeCandidate.fromWire),
      ),
      totalCount: wire.totalCount,
      limit: wire.limit,
    );
  }

  final List<ChargeMergeCandidate> candidates;
  final int totalCount;
  final int limit;
}

class ChargeMergeCandidate {
  const ChargeMergeCandidate({
    required this.sessionIds,
    required this.sessions,
    required this.breaks,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.durationMillis,
    required this.startSoc,
    required this.endSoc,
    required this.startOdometerKm,
    required this.endOdometerKm,
    required this.totalFrames,
  });

  factory ChargeMergeCandidate.fromMap(Map<String, Object?> map) {
    return ChargeMergeCandidate(
      sessionIds: _asStringList(map['sessionIds']),
      sessions: _asMapList(
        map['sessions'],
      ).map(ChargeSessionSummary.fromMap).toList(growable: false),
      breaks: _asMapList(
        map['breaks'],
      ).map(ChargeMergeBreak.fromMap).toList(growable: false),
      startUtcMillis: _asInt(map['startUtcMillis']) ?? 0,
      endUtcMillis: _asInt(map['endUtcMillis']) ?? 0,
      durationMillis: _asInt(map['durationMillis']) ?? 0,
      startSoc: _asDouble(map['startSoc']),
      endSoc: _asDouble(map['endSoc']),
      startOdometerKm: _asDouble(map['startOdometerKm']),
      endOdometerKm: _asDouble(map['endOdometerKm']),
      totalFrames: _asInt(map['totalFrames']) ?? 0,
    );
  }

  /// From the generated wire class.
  factory ChargeMergeCandidate.fromWire(ChargeMergeCandidateWire wire) {
    return ChargeMergeCandidate(
      sessionIds: List.unmodifiable(wire.sessionIds),
      sessions: List.unmodifiable(
        wire.sessions.map(ChargeSessionSummary.fromWire),
      ),
      breaks: List.unmodifiable(wire.breaks.map(ChargeMergeBreak.fromWire)),
      startUtcMillis: wire.startUtcMillis,
      endUtcMillis: wire.endUtcMillis,
      durationMillis: wire.durationMillis,
      startSoc: wire.startSoc,
      endSoc: wire.endSoc,
      startOdometerKm: wire.startOdometerKm,
      endOdometerKm: wire.endOdometerKm,
      totalFrames: wire.totalFrames,
    );
  }

  final List<String> sessionIds;
  final List<ChargeSessionSummary> sessions;
  final List<ChargeMergeBreak> breaks;
  final int startUtcMillis;
  final int endUtcMillis;
  final int durationMillis;
  final double? startSoc;
  final double? endSoc;
  final double? startOdometerKm;
  final double? endOdometerKm;
  final int totalFrames;
}

class ChargeMergeBreak {
  const ChargeMergeBreak({
    required this.previousSessionId,
    required this.nextSessionId,
    required this.gapMillis,
    required this.socDelta,
    required this.odometerDeltaKm,
  });

  factory ChargeMergeBreak.fromMap(Map<String, Object?> map) {
    return ChargeMergeBreak(
      previousSessionId: _asString(map['previousSessionId']),
      nextSessionId: _asString(map['nextSessionId']),
      gapMillis: _asInt(map['gapMillis']) ?? 0,
      socDelta: _asDouble(map['socDelta']),
      odometerDeltaKm: _asDouble(map['odometerDeltaKm']),
    );
  }

  /// From the generated wire class.
  factory ChargeMergeBreak.fromWire(ChargeMergeBreakWire wire) {
    return ChargeMergeBreak(
      previousSessionId: wire.previousSessionId,
      nextSessionId: wire.nextSessionId,
      gapMillis: wire.gapMillis,
      socDelta: wire.socDelta,
      odometerDeltaKm: wire.odometerDeltaKm,
    );
  }

  final String previousSessionId;
  final String nextSessionId;
  final int gapMillis;
  final double? socDelta;
  final double? odometerDeltaKm;
}

class ChargeMergeResult {
  const ChargeMergeResult({
    required this.ok,
    required this.error,
    required this.mergedSessionId,
    required this.mergedCount,
    required this.framesReassigned,
    required this.deletedSessions,
  });

  factory ChargeMergeResult.fromMap(Map<String, Object?> map) {
    return ChargeMergeResult(
      ok: map['ok'] == true,
      error: _asStringOrNull(map['error']),
      mergedSessionId: _asStringOrNull(map['mergedSessionId']),
      mergedCount: _asInt(map['mergedCount']) ?? 0,
      framesReassigned: _asInt(map['framesReassigned']) ?? 0,
      deletedSessions: _asInt(map['deletedSessions']) ?? 0,
    );
  }

  /// From the generated wire class.
  factory ChargeMergeResult.fromWire(ChargeMergeResultWire wire) {
    return ChargeMergeResult(
      ok: wire.ok,
      error: wire.error,
      mergedSessionId: wire.mergedSessionId,
      mergedCount: wire.mergedCount,
      framesReassigned: wire.framesReassigned,
      deletedSessions: wire.deletedSessions,
    );
  }

  final bool ok;
  final String? error;
  final String? mergedSessionId;
  final int mergedCount;
  final int framesReassigned;
  final int deletedSessions;
}

class ChargeSessionCostUpdateResult {
  const ChargeSessionCostUpdateResult({
    required this.ok,
    required this.updatedRows,
    required this.session,
  });

  factory ChargeSessionCostUpdateResult.fromMap(Map<String, Object?> map) {
    final sessionMap = map['session'];
    return ChargeSessionCostUpdateResult(
      ok: map['ok'] == true,
      updatedRows: _asInt(map['updatedRows']) ?? 0,
      session: sessionMap is Map
          ? ChargeSessionSummary.fromMap(_castMap(sessionMap))
          : null,
    );
  }

  /// From the generated wire class.
  factory ChargeSessionCostUpdateResult.fromWire(
    ChargeSessionCostUpdateWire wire,
  ) {
    final session = wire.session;
    return ChargeSessionCostUpdateResult(
      ok: wire.ok,
      updatedRows: wire.updatedRows,
      session: session == null ? null : ChargeSessionSummary.fromWire(session),
    );
  }

  final bool ok;
  final int updatedRows;
  final ChargeSessionSummary? session;
}

class ChargeSessionSummary {
  const ChargeSessionSummary({
    required this.id,
    required this.status,
    required this.plugConnectedAtUtcMillis,
    required this.plugConnectedAtElapsedNanos,
    required this.chargeStartedAtUtcMillis,
    required this.chargeStartedAtElapsedNanos,
    required this.chargeEndedAtUtcMillis,
    required this.chargeEndedAtElapsedNanos,
    required this.plugDisconnectedAtUtcMillis,
    required this.plugDisconnectedAtElapsedNanos,
    required this.durationMillis,
    required this.startSoc,
    required this.endSoc,
    required this.startOdometerKm,
    required this.endOdometerKm,
    required this.plugType,
    required this.startPowerKw,
    required this.estimatedEnergyKwh,
    required this.costPerKwh,
    required this.paidAmount,
    required this.costCurrency,
    required this.startAmbientTempC,
    required this.endAmbientTempC,
    required this.startLatitude,
    required this.startLongitude,
    required this.startAltitudeM,
    required this.startGpsAccuracyM,
    required this.startLocationProvider,
    required this.startLocationElapsedRealtimeNanos,
    required this.chargeEndReason,
    required this.endReason,
    required this.createdAtUtcMillis,
    required this.updatedAtUtcMillis,
  });

  factory ChargeSessionSummary.fromMap(Map<String, Object?> map) {
    return ChargeSessionSummary(
      id: _asString(map['id']),
      status: _asString(map['status'], 'UNKNOWN'),
      plugConnectedAtUtcMillis:
          _asInt(map['plugConnectedAtUtcMillis']) ??
          _asInt(map['startedAtUtcMillis']) ??
          0,
      plugConnectedAtElapsedNanos:
          _asInt(map['plugConnectedAtElapsedNanos']) ??
          _asInt(map['startedAtElapsedNanos']) ??
          0,
      chargeStartedAtUtcMillis: _asInt(map['chargeStartedAtUtcMillis']),
      chargeStartedAtElapsedNanos: _asInt(map['chargeStartedAtElapsedNanos']),
      chargeEndedAtUtcMillis: _asInt(map['chargeEndedAtUtcMillis']),
      chargeEndedAtElapsedNanos: _asInt(map['chargeEndedAtElapsedNanos']),
      plugDisconnectedAtUtcMillis:
          _asInt(map['plugDisconnectedAtUtcMillis']) ??
          _asInt(map['endedAtUtcMillis']),
      plugDisconnectedAtElapsedNanos:
          _asInt(map['plugDisconnectedAtElapsedNanos']) ??
          _asInt(map['endedAtElapsedNanos']),
      // Same reason as the trip row: a synced charge carries its endpoints,
      // not its duration.
      durationMillis:
          _asInt(map['durationMillis']) ?? _chargeDurationFromRow(map),
      startSoc: _asDouble(map['startSoc']) ?? _asDouble(map['startSocPercent']),
      endSoc: _asDouble(map['endSoc']) ?? _asDouble(map['endSocPercent']),
      startOdometerKm: _asDouble(map['startOdometerKm']),
      endOdometerKm: _asDouble(map['endOdometerKm']),
      plugType: _asInt(map['plugType']),
      startPowerKw: _asDouble(map['startPowerKw']),
      estimatedEnergyKwh:
          _asDouble(map['estimatedEnergyKwh']) ??
          (map['rollupDeliveredWh'] != null
              ? (_asDouble(map['rollupDeliveredWh'])! / 1000.0)
              : null),
      costPerKwh: _asDouble(map['costPerKwh']),
      paidAmount: _asDouble(map['paidAmount']),
      costCurrency: _asStringOrNull(map['costCurrency']) ?? 'BRL',
      startAmbientTempC: _asDouble(map['startAmbientTempC']),
      endAmbientTempC: _asDouble(map['endAmbientTempC']),
      startLatitude: _asDouble(map['startLatitude']),
      startLongitude: _asDouble(map['startLongitude']),
      startAltitudeM: _asDouble(map['startAltitudeM']),
      startGpsAccuracyM: _asDouble(map['startGpsAccuracyM']),
      startLocationProvider: _asStringOrNull(map['startLocationProvider']),
      startLocationElapsedRealtimeNanos: _asInt(
        map['startLocationElapsedRealtimeNanos'],
      ),
      chargeEndReason: _asStringOrNull(map['chargeEndReason']),
      endReason: _asStringOrNull(map['endReason']),
      createdAtUtcMillis: _asInt(map['createdAtUtcMillis']) ?? 0,
      updatedAtUtcMillis: _asInt(map['updatedAtUtcMillis']) ?? 0,
    );
  }

  /// From the generated wire class.
  factory ChargeSessionSummary.fromWire(ChargeSessionWire wire) {
    return ChargeSessionSummary(
      id: wire.id,
      status: wire.status,
      plugConnectedAtUtcMillis: wire.plugConnectedAtUtcMillis,
      plugConnectedAtElapsedNanos: wire.plugConnectedAtElapsedNanos,
      chargeStartedAtUtcMillis: wire.chargeStartedAtUtcMillis,
      chargeStartedAtElapsedNanos: wire.chargeStartedAtElapsedNanos,
      chargeEndedAtUtcMillis: wire.chargeEndedAtUtcMillis,
      chargeEndedAtElapsedNanos: wire.chargeEndedAtElapsedNanos,
      plugDisconnectedAtUtcMillis: wire.plugDisconnectedAtUtcMillis,
      plugDisconnectedAtElapsedNanos: wire.plugDisconnectedAtElapsedNanos,
      durationMillis: wire.durationMillis,
      startSoc: wire.startSoc,
      endSoc: wire.endSoc,
      startOdometerKm: wire.startOdometerKm,
      endOdometerKm: wire.endOdometerKm,
      plugType: wire.plugType,
      startPowerKw: wire.startPowerKw,
      estimatedEnergyKwh: wire.estimatedEnergyKwh,
      costPerKwh: wire.costPerKwh,
      paidAmount: wire.paidAmount,
      // The database column is nullable; the app's default stands in, the same
      // way the map path does it.
      costCurrency: wire.costCurrency ?? 'BRL',
      startAmbientTempC: wire.startAmbientTempC,
      endAmbientTempC: wire.endAmbientTempC,
      startLatitude: wire.startLatitude,
      startLongitude: wire.startLongitude,
      startAltitudeM: wire.startAltitudeM,
      startGpsAccuracyM: wire.startGpsAccuracyM,
      startLocationProvider: wire.startLocationProvider,
      startLocationElapsedRealtimeNanos: wire.startLocationElapsedRealtimeNanos,
      chargeEndReason: wire.chargeEndReason,
      endReason: wire.endReason,
      createdAtUtcMillis: wire.createdAtUtcMillis,
      updatedAtUtcMillis: wire.updatedAtUtcMillis,
    );
  }

  final String id;
  final String status;
  final int plugConnectedAtUtcMillis;
  final int plugConnectedAtElapsedNanos;
  final int? chargeStartedAtUtcMillis;
  final int? chargeStartedAtElapsedNanos;
  final int? chargeEndedAtUtcMillis;
  final int? chargeEndedAtElapsedNanos;
  final int? plugDisconnectedAtUtcMillis;
  final int? plugDisconnectedAtElapsedNanos;
  final int? durationMillis;
  final double? startSoc;
  final double? endSoc;
  final double? startOdometerKm;
  final double? endOdometerKm;
  final int? plugType;
  final double? startPowerKw;
  final double? estimatedEnergyKwh;
  final double? costPerKwh;
  final double? paidAmount;
  final String costCurrency;
  final double? startAmbientTempC;
  final double? endAmbientTempC;
  final double? startLatitude;
  final double? startLongitude;
  final double? startAltitudeM;
  final double? startGpsAccuracyM;
  final String? startLocationProvider;
  final int? startLocationElapsedRealtimeNanos;

  /// Why the charge stopped: a `ChargeEndReason` name.
  final String? chargeEndReason;

  /// How the session ended: how the plug came out.
  final String? endReason;
  final int createdAtUtcMillis;
  final int updatedAtUtcMillis;
}

class TripSessionSummary {
  const TripSessionSummary({
    required this.id,
    required this.status,
    required this.startedAtUtcMillis,
    required this.startedAtElapsedNanos,
    required this.movementStartedAtUtcMillis,
    required this.movementStartedAtElapsedNanos,
    required this.endedAtUtcMillis,
    required this.endedAtElapsedNanos,
    required this.durationMillis,
    this.startedAtBootCount,
    this.endedAtBootCount,
    required this.startSoc,
    required this.endSoc,
    required this.startOdometerKm,
    required this.endOdometerKm,
    required this.startGear,
    required this.endReason,
    required this.capacityWh,
    required this.createdAtUtcMillis,
    required this.updatedAtUtcMillis,
  });

  factory TripSessionSummary.fromMap(Map<String, Object?> map) {
    return TripSessionSummary(
      id: _asString(map['id']),
      status: _asString(map['status'], 'UNKNOWN'),
      startedAtUtcMillis: _asInt(map['startedAtUtcMillis']) ?? 0,
      startedAtElapsedNanos: _asInt(map['startedAtElapsedNanos']) ?? 0,
      movementStartedAtUtcMillis: _asInt(map['movementStartedAtUtcMillis']),
      movementStartedAtElapsedNanos: _asInt(
        map['movementStartedAtElapsedNanos'],
      ),
      endedAtUtcMillis: _asInt(map['endedAtUtcMillis']),
      endedAtElapsedNanos: _asInt(map['endedAtElapsedNanos']),
      startedAtBootCount: _asInt(map['startedAtBootCount']),
      endedAtBootCount: _asInt(map['endedAtBootCount']),
      // The car states the duration. A synced row does not: the stored row
      // holds the endpoints, and the duration is derived from them by the
      // repository that answers Flutter. Deriving it here is what keeps a
      // phone from printing a dash for every drive it holds.
      durationMillis:
          _asInt(map['durationMillis']) ?? _tripDurationFromRow(map),
      startSoc: _asDouble(map['startSoc']) ?? _asDouble(map['startSocPercent']),
      endSoc: _asDouble(map['endSoc']) ?? _asDouble(map['endSocPercent']),
      startOdometerKm: _asDouble(map['startOdometerKm']),
      endOdometerKm: _asDouble(map['endOdometerKm']),
      startGear: _asInt(map['startGear']),
      endReason: _asStringOrNull(map['endReason']),
      capacityWh: _asDouble(map['capacityWh']),
      createdAtUtcMillis: _asInt(map['createdAtUtcMillis']) ?? 0,
      updatedAtUtcMillis: _asInt(map['updatedAtUtcMillis']) ?? 0,
    );
  }

  /// From the generated wire class.
  factory TripSessionSummary.fromWire(TripSessionWire wire) {
    return TripSessionSummary(
      id: wire.id,
      status: wire.status,
      startedAtUtcMillis: wire.startedAtUtcMillis,
      startedAtElapsedNanos: wire.startedAtElapsedNanos,
      movementStartedAtUtcMillis: wire.movementStartedAtUtcMillis,
      movementStartedAtElapsedNanos: wire.movementStartedAtElapsedNanos,
      endedAtUtcMillis: wire.endedAtUtcMillis,
      endedAtElapsedNanos: wire.endedAtElapsedNanos,
      durationMillis: wire.durationMillis,
      startSoc: wire.startSoc,
      endSoc: wire.endSoc,
      startOdometerKm: wire.startOdometerKm,
      endOdometerKm: wire.endOdometerKm,
      startGear: wire.startGear,
      endReason: wire.endReason,
      capacityWh: wire.capacityWh,
      createdAtUtcMillis: wire.createdAtUtcMillis,
      updatedAtUtcMillis: wire.updatedAtUtcMillis,
    );
  }

  final String id;
  final String status;
  final int startedAtUtcMillis;
  final int startedAtElapsedNanos;
  final int? movementStartedAtUtcMillis;
  final int? movementStartedAtElapsedNanos;
  final int? endedAtUtcMillis;
  final int? endedAtElapsedNanos;
  final int? durationMillis;

  /// Which boot each end was stamped in.
  ///
  /// Elapsed realtime restarts at a reboot, so a span across two boots is not a
  /// span: it is the second boot's clock minus the first's, which measures
  /// nothing. These are what tell that case apart from an ordinary one.
  final int? startedAtBootCount;
  final int? endedAtBootCount;
  final double? startSoc;
  final double? endSoc;
  final double? startOdometerKm;
  final double? endOdometerKm;
  final int? startGear;
  final String? endReason;
  final double? capacityWh;
  final int createdAtUtcMillis;
  final int updatedAtUtcMillis;
}

/// Cover an integral must reach before it may be shown at all.
///
/// Not a completeness test — see [ChargeSessionDetailResult.climateEnergyKwhOver]
/// for why completeness is reported rather than enforced. This only rules out a
/// figure that watched so little of the charge that calling it the session's
/// load, even as a minimum, would mislead.
const double kChargeClimateSanityFloor = 0.5;

/// Slack on the completeness test, for the gap between two clocks.
const double kChargeClimateCompleteTolerance = 0.02;

/// What the climate package drew over a charge, and whether that is the whole
/// of it.
///
/// The two travel together because the number cannot be shown honestly without
/// the flag: incomplete, it is a floor, and the screen must say so.
class ChargeClimateEnergy {
  const ChargeClimateEnergy({required this.kwh, required this.complete});

  final double kwh;

  /// False when the bus was quiet for part of the charge. The value is then a
  /// minimum, and the reader must mark it as one.
  final bool complete;
}

/// Per-minute energy over a stretch of clock rather than one session.
///
/// Backs the chart's wider windows, so it takes in whatever trips fell inside
/// the window and the parked gaps between them. Charge sessions are left out:
/// energy taken *in* is a different question with its own screen.
class EnergyWindowBucketsResult {
  const EnergyWindowBucketsResult({
    required this.start,
    required this.end,
    required this.buckets,
    this.resampledSessionCount = 0,
    this.sessionCount = 0,
    this.costPerKwh,
    this.costCurrency,
  });

  factory EnergyWindowBucketsResult.fromMap(Map<String, Object?> map) {
    final raw = map['buckets'];
    return EnergyWindowBucketsResult(
      start: DateTime.fromMillisecondsSinceEpoch(
        (map['startUtcMillis'] as num?)?.toInt() ?? 0,
      ),
      end: DateTime.fromMillisecondsSinceEpoch(
        (map['endUtcMillis'] as num?)?.toInt() ?? 0,
      ),
      costPerKwh: _asDouble(map['lastChargeCostPerKwh']),
      costCurrency: _asStringOrNull(map['lastChargeCostCurrency']),
      resampledSessionCount:
          (map['resampledSessionCount'] as num?)?.toInt() ?? 0,
      sessionCount: (map['sessionCount'] as num?)?.toInt() ?? 0,
      buckets: raw is List
          ? List.unmodifiable(
              raw.whereType<Map>().map(
                (entry) => EnergyBucket.fromMap(entry.cast<String, Object?>()),
              ),
            )
          : const <EnergyBucket>[],
    );
  }

  /// From the generated wire class.
  factory EnergyWindowBucketsResult.fromWire(EnergyWindowBucketsWire wire) {
    return EnergyWindowBucketsResult(
      start: DateTime.fromMillisecondsSinceEpoch(wire.startUtcMillis),
      end: DateTime.fromMillisecondsSinceEpoch(wire.endUtcMillis),
      costPerKwh: wire.lastChargeCostPerKwh,
      costCurrency: wire.lastChargeCostCurrency,
      resampledSessionCount: wire.resampledSessionCount,
      sessionCount: wire.sessionCount,
      buckets: List.unmodifiable(wire.buckets.map(EnergyBucket.fromWire)),
    );
  }

  /// Floored to a bucket boundary natively, so the first bar is a whole minute
  /// on the clock like every other one.
  final DateTime start;
  final DateTime end;

  /// Chronological, one minute wide, gaps omitted rather than zero-filled.
  final List<EnergyBucket> buckets;

  /// How many of the trips in this window were rebuilt from 1 Hz frames.
  ///
  /// A count rather than a flag because a window can span both kinds: the drive
  /// from this morning was measured at CAN rate, the one from last month was
  /// not. The rebuilt minutes came from the frame table, which slice 4 retired,
  /// so on a database recorded since then this is always zero.
  final int resampledSessionCount;

  /// Trips the window covers, so [resampledSessionCount] can be read as a share.
  final int sessionCount;
  final double? costPerKwh;
  final String? costCurrency;

  bool get isEmpty => buckets.isEmpty;

  /// True when every trip in the window carries measured minutes.
  bool get isFullyMeasured => resampledSessionCount == 0;
}

/// Recent minutes of the trip in progress, folded in memory natively.
///
/// Polled about once a second so the chart's open bar keeps filling. It carries
/// a few already-closed minutes too, which is what lets a caller watch a minute
/// roll over without going back to the database for a value it just watched
/// being accumulated.
class LiveEnergyBucketsResult {
  const LiveEnergyBucketsResult({
    required this.sessionId,
    required this.startedAt,
    required this.buckets,
    this.width = EnergyBucket.oneMinute,
    this.timeUnsynced = false,
  });

  factory LiveEnergyBucketsResult.fromMap(Map<String, Object?> map) {
    final raw = map['buckets'];
    final startedAtMillis = (map['startedAtUtcMillis'] as num?)?.toInt();
    final bucketMillis = (map['bucketMillis'] as num?)?.toInt();
    final width = bucketMillis == null || bucketMillis <= 0
        ? EnergyBucket.oneMinute
        : Duration(milliseconds: bucketMillis);
    return LiveEnergyBucketsResult(
      sessionId: _asStringOrNull(map['sessionId']),
      timeUnsynced: map['timeUnsynced'] == true,
      startedAt: startedAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startedAtMillis),
      width: width,
      buckets: raw is List
          ? List.unmodifiable(
              raw.whereType<Map>().map(
                (entry) => EnergyBucket.fromMap(
                  entry.cast<String, Object?>(),
                  width: width,
                ),
              ),
            )
          : const <EnergyBucket>[],
    );
  }

  /// From the generated wire class.
  factory LiveEnergyBucketsResult.fromWire(LiveEnergyBucketsWire wire) {
    final width = wire.bucketMillis > 0
        ? Duration(milliseconds: wire.bucketMillis)
        : EnergyBucket.oneMinute;
    final startedAtMillis = wire.startedAtUtcMillis;
    return LiveEnergyBucketsResult(
      sessionId: wire.sessionId,
      timeUnsynced: wire.timeUnsynced ?? false,
      startedAt: startedAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startedAtMillis),
      width: width,
      buckets: List.unmodifiable(
        wire.buckets.map(
          (bucket) => EnergyBucket.fromWire(bucket, width: width),
        ),
      ),
    );
  }

  /// Null when no trip is running, which is not the same as a trip at rest.
  final String? sessionId;

  /// When the native monitor began seeing this trip. Minutes before it are
  /// partial there and complete in the database.
  final DateTime? startedAt;

  /// Cut the native side used. The minute for the energy chart, ten seconds for
  /// the efficiency window.
  final Duration width;
  final List<EnergyBucket> buckets;

  /// The boot's clock anchor is still unlearned, so the stamps above are the
  /// car's birth clock, not wall time. Grids must anchor on the buckets
  /// themselves and axes must count relative minutes, as on the energy chart.
  final bool timeUnsynced;

  bool get isActive => sessionId != null;
}

class TelemetrySeriesPoint {
  const TelemetrySeriesPoint({required this.x, required this.y});

  factory TelemetrySeriesPoint.fromMap(Map<String, Object?> map) {
    return TelemetrySeriesPoint(
      x: _asDouble(map['x']) ?? 0,
      y: _asDouble(map['y']) ?? 0,
    );
  }

  final double x;
  final double y;
}

class TelemetryRoutePoint {
  const TelemetryRoutePoint({
    required this.latitude,
    required this.longitude,
    this.altitudeM,
    this.accuracyM,
    this.speedKmh,
  });

  factory TelemetryRoutePoint.fromMap(Map<String, Object?> map) {
    return TelemetryRoutePoint(
      latitude: _asDouble(map['latitude']) ?? 0,
      longitude: _asDouble(map['longitude']) ?? 0,
      altitudeM: _asDouble(map['altitudeM']),
      accuracyM: _asDouble(map['accuracyM']),
      speedKmh: _asDouble(map['speedKmh']),
    );
  }

  final double latitude;
  final double longitude;
  final double? altitudeM;
  final double? accuracyM;
  final double? speedKmh;
}

class TelemetryFrame {
  const TelemetryFrame({
    required this.id,
    required this.sessionId,
    required this.sessionType,
    required this.wallTimeUtcMillis,
    required this.elapsedRealtimeNanos,
    required this.timestampAccuracy,
    required this.uncertaintyMillis,
    required this.speedKmh,
    required this.socPercent,
    required this.odometerKm,
    required this.voltageV,
    required this.currentA,
    required this.powerKw,
    this.canDrivePowerKw,
    this.canPackVoltageV,
    this.canPackCurrentA,
    this.canPackCurrentRaw,
    this.canPackCurrentEstimated,
    this.canSampleElapsedNanos,
    required this.gear,
    required this.chargeState,
    required this.chargePlugType,
    this.canDriveMode,
    this.canClimateOn,
    this.canClimateCompressorOn,
    this.canBlowerLevel,
    this.canCabinSetpointC,
    required this.ambientTempC,
    required this.latitude,
    required this.longitude,
    required this.altitudeM,
    required this.gpsAccuracyM,
    required this.locationProvider,
    required this.locationElapsedRealtimeNanos,
    required this.sampleCount,
    required this.freshnessMask,
    required this.qualityMask,
  });

  factory TelemetryFrame.fromMap(Map<String, Object?> map) {
    return TelemetryFrame(
      id: _asString(map['id']),
      sessionId: _asStringOrNull(map['sessionId']),
      sessionType: _asStringOrNull(map['sessionType']),
      wallTimeUtcMillis: _asInt(map['wallTimeUtcMillis']) ?? 0,
      elapsedRealtimeNanos: _asInt(map['elapsedRealtimeNanos']) ?? 0,
      timestampAccuracy: _asString(map['timestampAccuracy'], 'UNKNOWN'),
      uncertaintyMillis: _asInt(map['uncertaintyMillis']) ?? 0,
      speedKmh: _asDouble(map['speedKmh']),
      socPercent: _asDouble(map['socPercent']),
      odometerKm: _asDouble(map['odometerKm']),
      voltageV: _asDouble(map['voltageV']),
      currentA: _asDouble(map['currentA']),
      powerKw: _asDouble(map['powerKw']),
      canDrivePowerKw: _asDouble(map['canDrivePowerKw']),
      canPackVoltageV: _asDouble(map['canPackVoltageV']),
      canPackCurrentA: _asDouble(map['canPackCurrentA']),
      canPackCurrentRaw: _asInt(map['canPackCurrentRaw']),
      canPackCurrentEstimated: _asNullableBool(map['canPackCurrentEstimated']),
      canSampleElapsedNanos: _asInt(map['canSampleElapsedNanos']),
      gear: _asInt(map['gear']),
      chargeState: _asInt(map['chargeState']),
      chargePlugType: _asInt(map['chargePlugType']),
      canDriveMode: _asInt(map['canDriveMode']),
      canClimateOn: _asNullableBool(map['canClimateOn']),
      canClimateCompressorOn: _asNullableBool(map['canClimateCompressorOn']),
      canBlowerLevel: _asInt(map['canBlowerLevel']),
      canCabinSetpointC: _asDouble(map['canCabinSetpointC']),
      ambientTempC: _asDouble(map['ambientTempC']),
      latitude: _asDouble(map['latitude']),
      longitude: _asDouble(map['longitude']),
      altitudeM: _asDouble(map['altitudeM']),
      gpsAccuracyM: _asDouble(map['gpsAccuracyM']),
      locationProvider: _asStringOrNull(map['locationProvider']),
      locationElapsedRealtimeNanos: _asInt(map['locationElapsedRealtimeNanos']),
      sampleCount: _asInt(map['sampleCount']) ?? 0,
      freshnessMask: _asInt(map['freshnessMask']) ?? 0,
      qualityMask: _asInt(map['qualityMask']) ?? 0,
    );
  }

  final String id;
  final String? sessionId;
  final String? sessionType;
  final int wallTimeUtcMillis;
  final int elapsedRealtimeNanos;
  final String timestampAccuracy;
  final int uncertaintyMillis;
  final double? speedKmh;
  final double? socPercent;
  final double? odometerKm;
  final double? voltageV;
  final double? currentA;
  final double? powerKw;
  final double? canDrivePowerKw;
  final double? canPackVoltageV;
  final double? canPackCurrentA;
  final int? canPackCurrentRaw;
  final bool? canPackCurrentEstimated;
  final int? canSampleElapsedNanos;
  final int? gear;
  final int? chargeState;
  final int? chargePlugType;

  /// How the driver had the car set, as the count the bus reports: 0 NORMAL,
  /// 1 ECO, 2 SPORT.
  ///
  /// A count, never a name. The mapping is kept out of storage on purpose, so
  /// a correction to it does not invalidate recorded drives — which also means
  /// a reader must not print this number, and must not treat an unknown count
  /// as one of the three it knows.
  ///
  /// Trip-gated on the car: null on a frame that is not part of a drive, and
  /// null on every frame of a drive the daemon did not publish it for.
  final int? canDriveMode;

  /// What the driver asked the climate system for.
  ///
  /// These are demand, not energy. They say *why* a heavy minute was heavy, and
  /// none of them can be turned into watt-hours: the calibrated climate power
  /// never becomes a column, so nothing that syncs carries the amount.
  ///
  /// Written on trip **and** charge frames, unlike every other CAN column: the
  /// climate system runs while the car is plugged in, so that load belongs to
  /// the charge it lands in.
  ///
  /// [canBlowerLevel] is a count, 0 to 15, and not a rate of airflow.
  /// [canCabinSetpointC] is the one climate signal with a verified scale, so it
  /// holds degrees; the head unit offers 15.5 to 28.5.
  final bool? canClimateOn;
  final bool? canClimateCompressorOn;
  final int? canBlowerLevel;
  final double? canCabinSetpointC;

  final double? ambientTempC;
  final double? latitude;
  final double? longitude;
  final double? altitudeM;
  final double? gpsAccuracyM;
  final String? locationProvider;
  final int? locationElapsedRealtimeNanos;
  final int sampleCount;
  final int freshnessMask;
  final int qualityMask;
}

class TelemetrySnapshot {
  const TelemetrySnapshot({
    required this.timestampMillis,
    required this.batteryPercent,
    required this.speedKmh,
    required this.odometerKm,
    required this.charging,
    required this.gear,
  });

  factory TelemetrySnapshot.fromMap(Map<String, Object?> map) {
    return TelemetrySnapshot(
      timestampMillis: _asInt(map['timestampMillis']) ?? 0,
      batteryPercent: NumericReading.fromMap(_asMap(map['batteryPercent'])),
      speedKmh: NumericReading.fromMap(_asMap(map['speedKmh'])),
      odometerKm: NumericReading.fromMap(_asMap(map['odometerKm'])),
      charging: ChargingReading.fromMap(_asMap(map['charging'])),
      gear: NumericReading.fromMap(_asMap(map['gear'])),
    );
  }

  final int timestampMillis;
  final NumericReading batteryPercent;
  final NumericReading speedKmh;
  final NumericReading odometerKm;
  final ChargingReading charging;
  final NumericReading gear;
}

class NumericReading {
  const NumericReading({
    required this.ok,
    required this.value,
    required this.source,
    required this.details,
  });

  factory NumericReading.fromMap(Map<String, Object?> map) {
    return NumericReading(
      ok: map['ok'] == true,
      value: _asDouble(map['value']),
      source: _asString(map['source'], 'unknown'),
      details: _asString(map['details']),
    );
  }

  final bool ok;
  final double? value;
  final String source;
  final String details;
}

class ChargingReading {
  const ChargingReading({
    required this.ok,
    required this.isCharging,
    required this.stateRaw,
    required this.stateLabel,
    required this.plugRaw,
    required this.plugLabel,
    required this.acPowerKw,
    required this.dcPowerKw,
    required this.currentA,
    required this.voltageV,
    required this.estimatedTimeMinutes,
    required this.workTimeMinutes,
    required this.source,
    required this.details,
  });

  factory ChargingReading.fromMap(Map<String, Object?> map) {
    return ChargingReading(
      ok: map['ok'] == true,
      isCharging: map['isCharging'] as bool?,
      stateRaw: _asInt(map['stateRaw']),
      stateLabel: _asStringOrNull(map['stateLabel']),
      plugRaw: _asInt(map['plugRaw']),
      plugLabel: _asStringOrNull(map['plugLabel']),
      acPowerKw: _asDouble(map['acPowerKw']),
      dcPowerKw: _asDouble(map['dcPowerKw']),
      currentA: _asDouble(map['currentA']),
      voltageV: _asDouble(map['voltageV']),
      estimatedTimeMinutes: _asDouble(map['estimatedTimeMinutes']),
      workTimeMinutes: _asDouble(map['workTimeMinutes']),
      source: _asString(map['source'], 'unknown'),
      details: _asString(map['details']),
    );
  }

  final bool ok;
  final bool? isCharging;
  final int? stateRaw;
  final String? stateLabel;
  final int? plugRaw;
  final String? plugLabel;
  final double? acPowerKw;
  final double? dcPowerKw;
  final double? currentA;
  final double? voltageV;
  final double? estimatedTimeMinutes;
  final double? workTimeMinutes;
  final String source;
  final String details;
}

Map<String, Object?> _asMap(Object? value) => _castMap(value);

/// Zero-copy when already a typed string-key map; otherwise a cheap cast/copy.
Map<String, Object?> _castMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map<String, dynamic>) return value.cast<String, Object?>();
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((key, val) {
      out[key is String ? key : key.toString()] = val;
    });
    return out;
  }
  return const {};
}

/// Live stream events must be maps; empty on bad payloads.
///
/// Public because the transport calls it on every event channel payload, and
/// the DTO library is where "what a wire map may be" is decided.
Map<String, Object?> castTelemetryEventMap(Object? value) {
  if (value is Map) return _castMap(value);
  return const {};
}

List<Map<String, Object?>> _asMapList(Object? value) {
  if (value is! List || value.isEmpty) return const [];
  final out = <Map<String, Object?>>[];
  for (final entry in value) {
    if (entry is Map) out.add(_castMap(entry));
  }
  return out;
}

List<String> _asStringList(Object? value) {
  if (value is! List || value.isEmpty) return const [];
  return value.map((entry) => entry.toString()).toList(growable: false);
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// Parses a platform-channel boolean, falling back to [orElse] for missing or
/// unrecognized payloads. Explicit so default-on and default-off flags don't
/// read as `!= false` vs `== true` in adjacent lines.
bool _asBool(Object? value, {required bool orElse}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
    }
  }
  return orElse;
}

bool? _asNullableBool(Object? value) {
  if (value == null) return null;
  return _asBool(value, orElse: false);
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

String _asString(Object? value, [String fallback = '']) {
  if (value is String) return value;
  if (value == null) return fallback;
  return value.toString();
}

String? _asStringOrNull(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

List<LiveSignalSample> _liveSignals(Object? value) {
  if (value is! List || value.isEmpty) return const [];
  final out = <LiveSignalSample>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    out.add(LiveSignalSample.fromMap(_castMap(entry)));
  }
  return out;
}

CollectorStatus? _collectorStatusOrNull(Object? value) {
  if (value is! Map) return null;
  return CollectorStatus.fromMap(_castMap(value));
}

SignalTimestamp? _signalTimestampOrNull(Object? value) {
  if (value is! Map) return null;
  return SignalTimestamp.fromMap(_castMap(value));
}

List<TelemetryEvent> _asEventList(Object? value) {
  if (value is! List || value.isEmpty) return const [];
  final out = <TelemetryEvent>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    out.add(TelemetryEvent.fromMap(_castMap(entry)));
  }
  return out;
}

/// Roadcast daemon and native client status.
class RoadcastStatus {
  const RoadcastStatus({
    required this.running,
    required this.signalCount,
    required this.frameCount,
    required this.hz,
    required this.startedByApp,
    required this.error,
  });

  factory RoadcastStatus.fromMap(Map<String, Object?> map) {
    return RoadcastStatus(
      running: map['running'] == true,
      signalCount: _asInt(map['signalCount']) ?? 0,
      frameCount: _asInt(map['frameCount']) ?? 0,
      hz: _asInt(map['hz']) ?? 0,
      startedByApp: map['startedByApp'] == true,
      error: _asStringOrNull(map['error']),
    );
  }

  final bool running;
  final int signalCount;
  final int frameCount;
  final int hz;
  final bool startedByApp;
  final String? error;
}

/// State of the APK updater backed by the public GitHub releases repository.
class AppUpdateStatus {
  const AppUpdateStatus({
    required this.checked,
    required this.updateAvailable,
    required this.compatible,
    required this.installedVersionName,
    required this.installedVersionCode,
    required this.availableVersionName,
    required this.availableVersionCode,
    required this.requiresReflash,
    required this.installScheduled,
    required this.changelog,
    required this.error,
  });

  factory AppUpdateStatus.fromMap(Map<String, Object?> map) {
    return AppUpdateStatus(
      checked: map['checked'] == true,
      updateAvailable: map['updateAvailable'] == true,
      compatible: map['compatible'] != false,
      installedVersionName: _asString(map['installedVersionName']),
      installedVersionCode: _asInt(map['installedVersionCode']) ?? 0,
      availableVersionName: _asStringOrNull(map['availableVersionName']),
      availableVersionCode: _asInt(map['availableVersionCode']),
      requiresReflash: map['requiresReflash'] == true,
      installScheduled: map['installScheduled'] == true,
      changelog: _asMapList(
        map['changelog'],
      ).map(AppChangelogEntry.fromMap).toList(growable: false),
      error: _asStringOrNull(map['error']),
    );
  }

  final bool checked;
  final bool updateAvailable;
  final bool compatible;
  final String installedVersionName;
  final int installedVersionCode;
  final String? availableVersionName;
  final int? availableVersionCode;
  final bool requiresReflash;
  final bool installScheduled;
  final List<AppChangelogEntry> changelog;
  final String? error;
}

class AppChangelogEntry {
  const AppChangelogEntry({
    required this.versionName,
    required this.versionCode,
    required this.notes,
  });

  factory AppChangelogEntry.fromMap(Map<String, Object?> map) {
    final notesMap = _asMap(map['notes']);
    return AppChangelogEntry(
      versionName: _asString(map['versionName']),
      versionCode: _asInt(map['versionCode']) ?? 0,
      notes: {
        for (final locale in const ['en', 'pt', 'ru'])
          locale: _asStringList(notesMap[locale]),
      },
    );
  }

  final String versionName;
  final int versionCode;
  final Map<String, List<String>> notes;

  List<String> notesForLanguage(String languageCode) {
    final localized = notes[languageCode];
    if (localized != null && localized.isNotEmpty) return localized;
    return notes['en'] ?? const [];
  }
}

/// State of the manual Roadcast edge daemon updater.
class RoadcastUpdateStatus {
  const RoadcastUpdateStatus({
    required this.checked,
    required this.channel,
    required this.updateAvailable,
    required this.compatible,
    required this.installedSha256,
    required this.installedVersion,
    required this.installedCommit,
    required this.availableVersion,
    required this.availableCommit,
    required this.availableSha256,
    required this.error,
  });

  factory RoadcastUpdateStatus.fromMap(Map<String, Object?> map) {
    return RoadcastUpdateStatus(
      checked: map['checked'] == true,
      channel: _asStringOrNull(map['channel']) ?? 'edge',
      updateAvailable: map['updateAvailable'] == true,
      compatible: map['compatible'] == true,
      installedSha256: _asStringOrNull(map['installedSha256']),
      installedVersion: _asStringOrNull(map['installedVersion']),
      installedCommit: _asStringOrNull(map['installedCommit']),
      availableVersion: _asStringOrNull(map['availableVersion']),
      availableCommit: _asStringOrNull(map['availableCommit']),
      availableSha256: _asStringOrNull(map['availableSha256']),
      error: _asStringOrNull(map['error']),
    );
  }

  final bool checked;
  final String channel;
  final bool updateAvailable;
  final bool compatible;
  final String? installedSha256;
  final String? installedVersion;
  final String? installedCommit;
  final String? availableVersion;
  final String? availableCommit;
  final String? availableSha256;
  final String? error;
}

/// The vehicle's remaining range and the app's SOC-based estimate, side by side.
///
/// The two values are independent by contract: the vehicle value is never used
/// to train the app estimate and neither is copied into the other. Unknown
/// quality/source/reason strings parse safely into unavailable values, and a
/// non-finite number is treated as missing rather than trusted.
class RangeEstimate {
  const RangeEstimate({
    required this.timestampMillis,
    required this.carRangeKm,
    required this.carRangeQuality,
    required this.carRangeReason,
    required this.carRangePropertyId,
    required this.carRangeSignalSource,
    required this.carRangeReceivedAtUtcMillis,
    required this.carRangeSourceTimestampNanos,
    required this.socPercent,
    required this.capacityKwh,
    required this.capacitySource,
    required this.efficiencyKmPerKwh,
    required this.efficiencySource,
    required this.efficiencyWindowDays,
    required this.efficiencyTripCount,
    required this.efficiencyDistanceKm,
    required this.efficiencyNetEnergyKwh,
    required this.efficiencyUpdatedAtUtcMillis,
    required this.fullRangeKm,
    required this.ownRangeKm,
    required this.ownRangeQuality,
    required this.ownRangeReason,
  });

  factory RangeEstimate.fromMap(Map<String, Object?> map) => RangeEstimate._raw(
    timestampMillis: _asInt(map['timestampMillis']) ?? 0,
    carRangeKm: _finiteOrNull(_asDouble(map['carRangeKm'])),
    carRangeQuality: _asString(map['carRangeQuality'], ''),
    carRangeReason: _asStringOrNull(map['carRangeReason']),
    carRangePropertyId: _asInt(map['carRangePropertyId']) ?? 0,
    carRangeSignalSource: _asStringOrNull(map['carRangeSignalSource']),
    carRangeReceivedAtUtcMillis: _asInt(map['carRangeReceivedAtUtcMillis']),
    carRangeSourceTimestampNanos: _asInt(map['carRangeSourceTimestampNanos']),
    socPercent: _finiteOrNull(_asDouble(map['socPercent'])),
    capacityKwh: _finiteOrNull(_asDouble(map['capacityKwh'])),
    capacitySource: _asString(map['capacitySource'], ''),
    efficiencyKmPerKwh: _finiteOrNull(_asDouble(map['efficiencyKmPerKwh'])),
    efficiencySource: _asStringOrNull(map['efficiencySource']),
    efficiencyWindowDays: _asInt(map['efficiencyWindowDays']),
    efficiencyTripCount: _asInt(map['efficiencyTripCount']) ?? 0,
    efficiencyDistanceKm: _nonNegativeOrNull(map['efficiencyDistanceKm']),
    efficiencyNetEnergyKwh: _nonNegativeOrNull(map['efficiencyNetEnergyKwh']),
    efficiencyUpdatedAtUtcMillis: _asInt(map['efficiencyUpdatedAtUtcMillis']),
    fullRangeKm: _finiteOrNull(_asDouble(map['fullRangeKm'])),
    ownRangeKm: _finiteOrNull(_asDouble(map['ownRangeKm'])),
    ownRangeQuality: _asString(map['ownRangeQuality'], ''),
    ownRangeReason: _asStringOrNull(map['ownRangeReason']),
  );

  /// From the generated wire class.
  ///
  /// The fields arrive typed, so nothing is parsed here. They still go through
  /// [RangeEstimate._raw]: the gates it applies are decisions about what the
  /// app may show — a capacity outside what the pack can hold, a source the app
  /// does not recognise — and a generated class cannot express those.
  factory RangeEstimate.fromWire(RangeEstimateWire wire) => RangeEstimate._raw(
    timestampMillis: wire.timestampMillis,
    carRangeKm: _finiteOrNull(wire.carRangeKm),
    carRangeQuality: wire.carRangeQuality,
    carRangeReason: wire.carRangeReason,
    carRangePropertyId: wire.carRangePropertyId,
    carRangeSignalSource: wire.carRangeSignalSource,
    carRangeReceivedAtUtcMillis: wire.carRangeReceivedAtUtcMillis,
    carRangeSourceTimestampNanos: wire.carRangeSourceTimestampNanos,
    socPercent: _finiteOrNull(wire.socPercent),
    capacityKwh: _finiteOrNull(wire.capacityKwh),
    capacitySource: wire.capacitySource,
    efficiencyKmPerKwh: _finiteOrNull(wire.efficiencyKmPerKwh),
    efficiencySource: wire.efficiencySource,
    efficiencyWindowDays: wire.efficiencyWindowDays,
    efficiencyTripCount: wire.efficiencyTripCount,
    efficiencyDistanceKm: _nonNegativeOrNull(wire.efficiencyDistanceKm),
    efficiencyNetEnergyKwh: _nonNegativeOrNull(wire.efficiencyNetEnergyKwh),
    efficiencyUpdatedAtUtcMillis: wire.efficiencyUpdatedAtUtcMillis,
    fullRangeKm: _finiteOrNull(wire.fullRangeKm),
    ownRangeKm: _finiteOrNull(wire.ownRangeKm),
    ownRangeQuality: wire.ownRangeQuality,
    ownRangeReason: wire.ownRangeReason,
  );

  /// Every gate the app applies to a range reading, in one place.
  ///
  /// Unknown quality, source and reason strings resolve to unavailable values,
  /// and a number outside its plausible span is treated as missing rather than
  /// trusted. Both constructors above go through this, so the map path and the
  /// typed path cannot drift on what the app is willing to show.
  factory RangeEstimate._raw({
    required int timestampMillis,
    required double? carRangeKm,
    required String carRangeQuality,
    required String? carRangeReason,
    required int carRangePropertyId,
    required String? carRangeSignalSource,
    required int? carRangeReceivedAtUtcMillis,
    required int? carRangeSourceTimestampNanos,
    required double? socPercent,
    required double? capacityKwh,
    required String capacitySource,
    required double? efficiencyKmPerKwh,
    required String? efficiencySource,
    required int? efficiencyWindowDays,
    required int efficiencyTripCount,
    required double? efficiencyDistanceKm,
    required double? efficiencyNetEnergyKwh,
    required int? efficiencyUpdatedAtUtcMillis,
    required double? fullRangeKm,
    required double? ownRangeKm,
    required String ownRangeQuality,
    required String? ownRangeReason,
  }) {
    final carSource = _carSources.contains(carRangeSignalSource)
        ? carRangeSignalSource
        : null;
    final carUsable =
        carRangeQuality == 'AVAILABLE' &&
        carSource != null &&
        carRangePropertyId == rangeRemainingPropertyId &&
        carRangeKm != null &&
        carRangeKm >= 0 &&
        carRangeKm <= maxCarRangeKm;

    final validCapacitySource = _capacitySources.contains(capacitySource)
        ? capacitySource
        : '';
    final capacity =
        capacityKwh != null &&
            capacityKwh > 0 &&
            capacityKwh >= minCapacityKwh &&
            capacityKwh <= maxCapacityKwh &&
            validCapacitySource.isNotEmpty
        ? capacityKwh
        : null;

    final soc = socPercent != null && socPercent >= 0 && socPercent <= 100
        ? socPercent
        : null;
    final validEfficiencySource = _efficiencySources.contains(efficiencySource)
        ? efficiencySource
        : null;
    final efficiency =
        efficiencyKmPerKwh != null &&
            efficiencyKmPerKwh >= minEfficiencyKmPerKwh &&
            efficiencyKmPerKwh <= maxEfficiencyKmPerKwh &&
            validEfficiencySource != null
        ? efficiencyKmPerKwh
        : null;

    final ownUsable =
        _ownQualities.contains(ownRangeQuality) &&
        soc != null &&
        capacity != null &&
        efficiency != null &&
        fullRangeKm != null &&
        fullRangeKm >= 0 &&
        ownRangeKm != null &&
        ownRangeKm >= 0;

    return RangeEstimate(
      timestampMillis: timestampMillis,
      carRangeKm: carUsable ? carRangeKm : null,
      carRangeQuality: carUsable ? 'AVAILABLE' : 'UNAVAILABLE',
      carRangeReason: carRangeReason,
      carRangePropertyId: carRangePropertyId,
      carRangeSignalSource: carSource,
      carRangeReceivedAtUtcMillis: carRangeReceivedAtUtcMillis,
      carRangeSourceTimestampNanos: carRangeSourceTimestampNanos,
      socPercent: soc,
      capacityKwh: capacity ?? 0,
      capacitySource: validCapacitySource,
      efficiencyKmPerKwh: efficiency,
      efficiencySource: validEfficiencySource,
      efficiencyWindowDays: efficiencyWindowDays,
      efficiencyTripCount: efficiencyTripCount < 0 ? 0 : efficiencyTripCount,
      efficiencyDistanceKm: efficiencyDistanceKm,
      efficiencyNetEnergyKwh: efficiencyNetEnergyKwh,
      efficiencyUpdatedAtUtcMillis: efficiencyUpdatedAtUtcMillis,
      fullRangeKm: ownUsable ? fullRangeKm : null,
      ownRangeKm: ownUsable ? ownRangeKm : null,
      ownRangeQuality: ownUsable ? ownRangeQuality : 'UNAVAILABLE',
      ownRangeReason: ownRangeReason,
    );
  }

  static const rangeRemainingPropertyId = 0x11400308;
  static const maxCarRangeKm = 2000.0;
  static const minCapacityKwh = 5.0;
  static const maxCapacityKwh = 200.0;
  static const minEfficiencyKmPerKwh = 0.5;
  static const maxEfficiencyKmPerKwh = 20.0;
  static const _carSources = {'VHAL_CALLBACK', 'VHAL_POLLING'};

  /// The one capacity source the native side states, and thus the only one the
  /// app accepts. It was three vehicle-read names until 2026-08-15; those are
  /// gone, and an unrecognised source here makes the whole app estimate
  /// unavailable, so this set must follow
  /// `RangeEstimateMonitor.CAPACITY_SOURCE_*`.
  /// `range_estimate_source_parity_test.dart` holds the two together.
  static const _capacitySources = {'SETTINGS'};
  static const _efficiencySources = {'CLOSED_TRIPS_7D', 'CLOSED_TRIPS_30D'};
  static const _ownQualities = {'AVAILABLE', 'DEGRADED'};

  final int timestampMillis;

  /// The distance-to-empty the car reports, or null when unavailable.
  final double? carRangeKm;
  final String carRangeQuality;
  final String? carRangeReason;
  final int carRangePropertyId;
  final String? carRangeSignalSource;
  final int? carRangeReceivedAtUtcMillis;
  final int? carRangeSourceTimestampNanos;

  /// Current SOC after validation, or null while unavailable.
  final double? socPercent;

  /// The validated capacity. A malformed bridge reply maps this value to zero.
  final double capacityKwh;
  final String capacitySource;

  final double? efficiencyKmPerKwh;
  final String? efficiencySource;
  final int? efficiencyWindowDays;
  final int efficiencyTripCount;
  final double? efficiencyDistanceKm;
  final double? efficiencyNetEnergyKwh;
  final int? efficiencyUpdatedAtUtcMillis;

  final double? fullRangeKm;
  final double? ownRangeKm;
  final String ownRangeQuality;
  final String? ownRangeReason;

  bool get carRangeAvailable =>
      carRangeKm != null && carRangeQuality == 'AVAILABLE';

  bool get ownRangeAvailable =>
      ownRangeKm != null && ownRangeQuality == 'AVAILABLE';

  bool get ownRangeDegraded =>
      ownRangeKm != null && ownRangeQuality == 'DEGRADED';

  bool get efficiencyAvailable => efficiencyKmPerKwh != null;
}

double? _finiteOrNull(double? value) {
  if (value == null || !value.isFinite || value.isNaN) return null;
  return value;
}

double? _nonNegativeOrNull(Object? value) {
  final number = _finiteOrNull(_asDouble(value));
  return number != null && number >= 0 ? number : null;
}

/// A change to the recorded sessions, from the native push.
///
/// It says *that* something changed, never what it now is: the reader re-reads
/// the list it is showing. A payload here would be a second route to the same
/// data, and the two would disagree the first time one was changed alone.
@immutable
class SessionChange {
  const SessionChange({
    required this.revision,
    required this.trips,
    required this.charges,
    this.parked = false,
  });

  factory SessionChange.fromWire(SessionChangeWire wire) => SessionChange(
    revision: wire.revision,
    trips: wire.trips,
    charges: wire.charges,
    parked: wire.parked,
  );

  /// Rises on every change, so a reader that missed an event can tell.
  final int revision;

  /// A trip row was written, closed or removed.
  final bool trips;

  /// A charge row was written, closed, merged or priced.
  final bool charges;

  /// A parked row was written, closed or given a sleep estimate.
  final bool parked;

  @override
  bool operator ==(Object other) =>
      other is SessionChange &&
      other.revision == revision &&
      other.trips == trips &&
      other.charges == charges &&
      other.parked == parked;

  @override
  int get hashCode => Object.hash(revision, trips, charges, parked);

  @override
  String toString() =>
      'SessionChange(revision: $revision, trips: $trips, charges: $charges, '
      'parked: $parked)';
}

/// Why the vehicle heading is, or is not, a number.
///
/// This car has no usable magnetometer, so the only heading source is the GNSS
/// course over ground, and that course exists only while the vehicle moves. A
/// standstill is therefore a normal state, not a fault. [noBearing] is a
/// stopped car, [noFix] is a receiver that sees nothing, and
/// [permissionMissing] is this app: the three print the same dash and must not
/// be explained to the reader in the same words.
enum HeadingAvailability {
  /// The fix carries a course.
  ok,

  /// The user turned GPS collection off in the app settings.
  gpsDisabled,

  /// Android did not grant a location permission.
  permissionMissing,

  /// No provider is enabled, or no fix has arrived yet.
  noFix,

  /// The last fix is older than the age limit the native side applies.
  fixStale,

  /// There is a fresh fix, but it carries no course. A stopped vehicle looks
  /// like this.
  noBearing,

  /// The native side named a state this build does not know.
  unknown;

  /// Resolves the wire name. An unrecognised name is [unknown], never a guess.
  static HeadingAvailability fromWireName(String name) => switch (name) {
    'OK' => HeadingAvailability.ok,
    'GPS_DISABLED' => HeadingAvailability.gpsDisabled,
    'PERMISSION_MISSING' => HeadingAvailability.permissionMissing,
    'NO_FIX' => HeadingAvailability.noFix,
    'FIX_STALE' => HeadingAvailability.fixStale,
    'NO_BEARING' => HeadingAvailability.noBearing,
    _ => HeadingAvailability.unknown,
  };
}

/// The GNSS course over ground, as the car's receiver reported it.
///
/// [bearingDeg] is the direction of travel, not the direction the vehicle
/// points. The two differ in reverse and during a manoeuvre, and nothing in
/// this app can tell them apart, so nothing here claims to.
///
/// No movement floor and no smoothing are applied. Both need memory of earlier
/// readings, so they belong to the compass that draws these, not to one
/// reading. [speedMps] is here for exactly that reason: it is what such a
/// reader needs to judge whether a held heading is still believable.
class HeadingReading {
  const HeadingReading({
    required this.timestampMillis,
    required this.availability,
    required this.bearingDeg,
    required this.bearingAccuracyDeg,
    required this.speedMps,
    required this.fixAgeMillis,
  });

  factory HeadingReading.fromMap(Map<String, Object?> map) =>
      HeadingReading._raw(
        timestampMillis: _asInt(map['timestampMillis']) ?? 0,
        availability: _asString(map['availability'], ''),
        bearingDeg: _finiteOrNull(_asDouble(map['bearingDeg'])),
        bearingAccuracyDeg: _finiteOrNull(_asDouble(map['bearingAccuracyDeg'])),
        speedMps: _finiteOrNull(_asDouble(map['speedMps'])),
        fixAgeMillis: _asInt(map['fixAgeMillis']),
      );

  /// From the generated wire class. The fields arrive typed, so nothing is
  /// parsed, but both paths still meet in [HeadingReading._raw] so the mock and
  /// the car cannot disagree about what the app is willing to show.
  factory HeadingReading.fromWire(HeadingWire wire) => HeadingReading._raw(
    timestampMillis: wire.timestampMillis,
    availability: wire.availability,
    bearingDeg: _finiteOrNull(wire.bearingDeg),
    bearingAccuracyDeg: _finiteOrNull(wire.bearingAccuracyDeg),
    speedMps: _finiteOrNull(wire.speedMps),
    fixAgeMillis: wire.fixAgeMillis,
  );

  /// Every gate the app applies to a heading, in one place.
  ///
  /// A course outside 0-360 degrees is not a course, and a state that says [ok]
  /// with no number is not a reading. Both are demoted to
  /// [HeadingAvailability.noBearing] instead of being shown, because the app
  /// must never print a direction the receiver did not report.
  factory HeadingReading._raw({
    required int timestampMillis,
    required String availability,
    required double? bearingDeg,
    required double? bearingAccuracyDeg,
    required double? speedMps,
    required int? fixAgeMillis,
  }) {
    final state = HeadingAvailability.fromWireName(availability);
    final usable =
        state == HeadingAvailability.ok &&
        bearingDeg != null &&
        bearingDeg >= 0 &&
        bearingDeg < 360;
    return HeadingReading(
      timestampMillis: timestampMillis,
      availability: usable ? state : _refusal(state),
      bearingDeg: usable ? bearingDeg : null,
      // The accuracy and the speed describe the fix, not the course, so they
      // survive a refused bearing.
      bearingAccuracyDeg: bearingAccuracyDeg != null && bearingAccuracyDeg >= 0
          ? bearingAccuracyDeg
          : null,
      speedMps: speedMps != null && speedMps >= 0 ? speedMps : null,
      fixAgeMillis: fixAgeMillis != null && fixAgeMillis >= 0
          ? fixAgeMillis
          : null,
    );
  }

  /// The state to report when a bearing was refused here. A state that already
  /// explains itself is kept; only a broken [HeadingAvailability.ok] is
  /// rewritten.
  static HeadingAvailability _refusal(HeadingAvailability state) =>
      state == HeadingAvailability.ok ? HeadingAvailability.noBearing : state;

  final int timestampMillis;

  /// Why the heading is present or absent.
  final HeadingAvailability availability;

  /// The course over ground, 0 up to but not including 360 degrees, or null.
  final double? bearingDeg;

  /// The receiver's own estimate of the course error, in degrees.
  final double? bearingAccuracyDeg;

  /// The speed of the fix. It can be present while [bearingDeg] is not.
  final double? speedMps;

  /// How old the fix behind this reading is.
  final int? fixAgeMillis;

  /// True when the app may draw a direction.
  bool get hasBearing => bearingDeg != null;

  @override
  String toString() =>
      'HeadingReading(availability: ${availability.name}, '
      'bearingDeg: $bearingDeg, speedMps: $speedMps, '
      'fixAgeMillis: $fixAgeMillis)';
}
