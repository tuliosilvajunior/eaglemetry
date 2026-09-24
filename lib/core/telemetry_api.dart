import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'channel_telemetry_source.dart';
import 'mock_telemetry_source.dart';
import 'mock_telemetry_data.dart';
import 'mock_telemetry_store.dart';
import 'room_store.dart';

export 'package:telemetry_core/telemetry_core.dart';

/// The source this build talks to.
///
/// [useMockTelemetry] is a compile-time constant, so on an Android release
/// build this is `ChannelTelemetrySource()` before the program runs and
/// [MockTelemetrySource] — with the mock data behind it — is unreachable.
TelemetrySource defaultTelemetrySource() =>
    useMockTelemetry ? MockTelemetrySource() : const ChannelTelemetrySource();

/// The store that goes with [source].
///
/// The store and the source answer for the same car, so one choice decides
/// both: a mock source is a mock car, and a mock car's history is the mock
/// store. Defaulting to [RoomStore] beside a mock source would send a screen's
/// list read to a Pigeon channel with nothing behind it — which on the car is
/// right and in a test is a read that never answers.
TelemetryStore defaultTelemetryStore(TelemetrySource source) =>
    source is MockTelemetrySource
    ? buildMockTelemetryStore(MockTelemetryData())
    : RoomStore();

class TelemetryApi {
  TelemetryApi({TelemetrySource? source, TelemetryStore? store})
    : this._(source ?? defaultTelemetrySource(), store);

  TelemetryApi._(TelemetrySource source, TelemetryStore? store)
    : _source = source,
      store = store ?? defaultTelemetryStore(source);

  /// The api the app runs on.
  ///
  /// Reach it through `TelemetryScope.of(context)` from a widget, so a test or
  /// a harness can put a different instance under a subtree. Controllers with
  /// no context take this directly, through their `telemetryApi` parameter.
  static final TelemetryApi shared = TelemetryApi();

  final TelemetrySource _source;
  final TelemetryStore store;

  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) => store.listSessions(filter: filter, page: page);

  Future<SessionDetail?> getSession(String id) => store.session(id);

  Future<TelemetrySeries> getSeries(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) => store.series(id, keys: keys, widthMillis: widthMillis);

  /// Invokes [method] and parses the reply.
  Future<T> _invoke<T>(
    String method,
    T Function(Map<String, Object?>) parse, {
    Map<String, Object?>? arguments,
  }) async => parse(await _source.call(method, arguments));

  Future<PlatformStatus> getPlatformStatus() =>
      _invoke('getPlatformStatus', PlatformStatus.fromMap);

  Future<TelemetrySnapshot> getTelemetrySnapshot() =>
      _invoke('getTelemetrySnapshot', TelemetrySnapshot.fromMap);

  Future<CollectorStatus> startTelemetryCollection() =>
      _invoke('startTelemetryCollection', CollectorStatus.fromMap);

  Future<CollectorStatus> stopTelemetryCollection() =>
      _invoke('stopTelemetryCollection', CollectorStatus.fromMap);

  Future<CollectorStatus> getCollectorStatus() =>
      _invoke('getCollectorStatus', CollectorStatus.fromMap);

  /// What this vehicle can do. A profile fact, read once, not a status.
  Future<VehicleCapabilities> getVehicleCapabilities() =>
      _invoke('getVehicleCapabilities', VehicleCapabilities.fromMap);

  Future<RoadcastStatus> getRoadcastStatus() =>
      _invoke('getRoadcastStatus', RoadcastStatus.fromMap);

  Future<AppUpdateStatus> getAppUpdateStatus() =>
      _invoke('getAppUpdateStatus', AppUpdateStatus.fromMap);

  Future<AppUpdateStatus> checkAppUpdate() =>
      _invoke('checkAppUpdate', AppUpdateStatus.fromMap);

  Future<AppUpdateStatus> installAppUpdate() =>
      _invoke('installAppUpdate', AppUpdateStatus.fromMap);

  Future<RoadcastUpdateStatus> getRoadcastUpdateStatus() =>
      _invoke('getRoadcastUpdateStatus', RoadcastUpdateStatus.fromMap);

  Future<RoadcastUpdateStatus> checkRoadcastUpdate() =>
      _invoke('checkRoadcastUpdate', RoadcastUpdateStatus.fromMap);

  Future<RoadcastUpdateStatus> updateRoadcastDaemon() =>
      _invoke('updateRoadcastDaemon', RoadcastUpdateStatus.fromMap);

  /// Derruba e sobe o daemon. Ação manual: o caminho automático nunca reinicia um
  /// daemon saudável, porque isso interromperia o registro de uma viagem em curso.
  Future<RoadcastStatus> restartRoadcastDaemon() =>
      _invoke('restartRoadcastDaemon', RoadcastStatus.fromMap);

  Future<LiveTelemetryFrame> getLiveTelemetrySnapshot() =>
      _invoke('getLiveTelemetrySnapshot', LiveTelemetryFrame.fromMap);

  Future<HvacCommandResult> getHvacControlStatus() =>
      _invoke('getHvacControlStatus', HvacCommandResult.fromMap);

  Future<HvacCommandResult> stepHvacTemperature(double delta) => _invoke(
    'stepHvacTemperature',
    HvacCommandResult.fromMap,
    arguments: {'delta': delta},
  );

  Future<HvacCommandResult> stepHvacFanSpeed(int delta) => _invoke(
    'stepHvacFanSpeed',
    HvacCommandResult.fromMap,
    arguments: {'delta': delta},
  );

  /// Writes an absolute cabin temperature.
  ///
  /// The reply reports what the controller applied after it clamped the request
  /// to the range the car accepts and rounded it to the half degree, so a
  /// request outside that range shows the applied value rather than the asked
  /// one.
  Future<HvacCommandResult> setHvacTemperature(double temperatureC) => _invoke(
    'setHvacTemperature',
    HvacCommandResult.fromMap,
    arguments: {'temperatureC': temperatureC},
  );

  /// Writes an absolute fan speed. Clamped by the controller, same as above.
  Future<HvacCommandResult> setHvacFanSpeed(int fanSpeed) => _invoke(
    'setHvacFanSpeed',
    HvacCommandResult.fromMap,
    arguments: {'fanSpeed': fanSpeed},
  );

  Future<TelemetryEventsResult> getTelemetryEvents({int limit = 100}) =>
      _invoke(
        'getTelemetryEvents',
        TelemetryEventsResult.fromMap,
        arguments: {'limit': limit},
      );

  Future<ChargeMergeCandidatesResult> getChargeMergeCandidates({
    int limit = 10,
  }) => _source.chargeMergeCandidates(limit);

  Future<ChargeMergeResult> mergeChargeSessions({
    required List<String> sessionIds,
  }) => _source.mergeChargeSessions(sessionIds);

  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    double? costPerKwh,
    double? paidAmount,
    String currency = 'BRL',
  }) => _source.updateChargeSessionCost(
    sessionId: sessionId,
    costPerKwh: costPerKwh,
    paidAmount: paidAmount,
    currency: currency,
  );

  /// The battery cycles, newest first. One cycle is one equivalent full cycle.
  Future<BatteryCyclesResult> getBatteryCycles({int limit = 50}) =>
      _source.batteryCycles(limit);

  /// The sessions one cycle is made of, oldest first.
  ///
  /// A member whose session retention has deleted stays in the list, marked
  /// deleted, because it is part of what the cycle counted.
  Future<BatteryCycleSessionsResult> getBatteryCycleSessions({
    required int ordinal,
  }) => _source.batteryCycleSessions(ordinal);

  /// Closed trips the Insights engine may compare.
  ///
  /// The last 30 days, plus [subjectId] when it is set. The native read is
  /// session aggregates and minute-bucket presence. It never reads a frame.
  Future<InsightTripsResult> getInsightTrips({String? subjectId}) =>
      _source.insightTrips(subjectId);

  /// Places the driver named. The app never invents these.
  Future<InsightPlacesResult> getInsightPlaces() => _source.insightPlaces();

  /// Names a place at a coordinate. [id] is set when renaming.
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = kInsightPlaceRadiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) => _source.saveInsightPlace(
    id: id,
    name: name,
    latitude: latitude,
    longitude: longitude,
    radiusM: radiusM,
    autoName: autoName,
    autoNameUpdatedAtUtcMillis: autoNameUpdatedAtUtcMillis,
    autoNameSource: autoNameSource,
  );

  Future<void> deleteInsightPlace({required String id}) =>
      _source.deleteInsightPlace(id);

  /// The synced preference rows this side holds. The reader decides what
  /// each key means; an unknown value renders as the default, never as an
  /// overwrite of the stored row.
  Future<List<PreferenceRow>> getPreferenceRows() => _source.preferenceRows();

  /// Writes one preference row from a car-side edit. Only a synced key may
  /// be written this way.
  Future<PreferenceRow?> savePreferenceRow({
    required String scope,
    required String key,
    String? value,
  }) => _source.savePreferenceRow(scope: scope, key: key, value: value);

  /// The pending preference proposals the settings show as prompts.
  Future<List<PreferenceProposal>> getPreferenceProposals() =>
      _source.preferenceProposals();

  /// Proposes a value for a car-only preference key. The proposal is inert
  /// until a person on the car accepts it.
  Future<PreferenceProposal?> proposePreference({
    required String key,
    String? value,
  }) => _source.proposePreference(key: key, value: value);

  /// Decides a proposal. Acceptance runs the car's normal write path.
  Future<PreferenceProposal?> decidePreferenceProposal({
    required String id,
    required bool accept,
  }) => _source.decidePreferenceProposal(id: id, accept: accept);

  /// Fires when an annotation row was written, merged or deleted.
  Stream<AnnotationChange> annotationsChanged() => _source.annotationsChanged();

  /// Per-minute energy over the last [window] of clock, across whatever trips
  /// fell inside it.
  ///
  /// [EnergyWindow.currentDrive] has no span of its own — it is bounded by the
  /// trip — so it is served by the store's series instead.
  Future<EnergyWindowBucketsResult> getEnergyBucketsInWindow(
    EnergyWindow window,
  ) {
    final minutes = window.minutes;
    assert(minutes != null, 'currentDrive is a session, not a clock window');
    return _source.energyBucketsInWindow(minutes!);
  }

  /// The same window, over parked sessions instead of trips.
  ///
  /// [EnergyWindow.currentDrive] has no answer here and must not be passed. It
  /// is bounded by a trip, and a trip is the one thing a parked session is not.
  Future<EnergyWindowBucketsResult> getParkedEnergyBucketsInWindow(
    EnergyWindow window,
  ) {
    final minutes = window.minutes;
    assert(minutes != null, 'currentDrive is a trip, so it is never parked');
    return _source.parkedEnergyBucketsInWindow(minutes!);
  }

  /// The minute in progress, plus the last few closed ones, from memory.
  ///
  /// Cheap enough to poll every second: it never touches the database. Merge it
  /// onto the stored series with `mergeEnergyBuckets`.
  Future<LiveEnergyBucketsResult> getLiveEnergyBuckets() =>
      _source.liveEnergyBuckets();

  /// The last fifteen minutes of driving, cut ten seconds wide, from memory.
  ///
  /// The same power integral as [getLiveEnergyBuckets], sliced finer so the
  /// efficiency card can show a ratio per interval instead of per minute. Read
  /// it with `readEfficiency`.
  Future<LiveEnergyBucketsResult> getLiveEfficiencyBuckets() =>
      _source.liveEfficiencyBuckets();

  /// The open charge's climate minutes, in memory.
  ///
  /// Climate is the only term a charge integrates: during a charge the pack
  /// reading is the charging current, so the `pack - traction` remainder that
  /// names the auxiliary load on a trip does not exist here. Read the rate with
  /// `readChargeClimateShare`.
  Future<LiveEnergyBucketsResult> getLiveChargeEnergyBuckets() =>
      _source.liveChargeEnergyBuckets();

  /// The `CONTINUOUS` session's newest minutes, in memory. Empty with the
  /// mode off.
  Future<LiveEnergyBucketsResult> getLiveContinuousEnergyBuckets() =>
      _source.liveContinuousEnergyBuckets();

  Future<RangeEstimate> getRangeEstimate() => _source.rangeEstimate();

  /// The GNSS course over ground.
  ///
  /// The car has no usable magnetometer, so this is the direction of travel and
  /// it exists only while the vehicle moves. A reading with no bearing states
  /// why in [HeadingReading.availability]; a stopped car is the normal case,
  /// not a fault.
  Future<HeadingReading> getHeading() => _source.heading();

  Future<StorageUsage> getStorageUsage() =>
      _invoke('getStorageUsage', StorageUsage.fromMap);

  Future<ClearTelemetryDatabaseResult> clearTelemetryDatabase() =>
      _invoke('clearTelemetryDatabase', ClearTelemetryDatabaseResult.fromMap);

  Future<TelemetryRetentionResult> runTelemetryRetention() =>
      _invoke('runTelemetryRetention', TelemetryRetentionResult.fromMap);

  Future<TelemetrySettingsResult> getTelemetrySettings() =>
      _invoke('getTelemetrySettings', TelemetrySettingsResult.fromMap);

  Future<TelemetrySettingsResult> setAutoStartOnBoot(bool enabled) => _invoke(
    'setAutoStartOnBoot',
    TelemetrySettingsResult.fromMap,
    arguments: {'enabled': enabled},
  );

  Future<TelemetrySettingsResult> setKeepBluetoothOnEnabled(bool enabled) =>
      _invoke(
        'setKeepBluetoothOnEnabled',
        TelemetrySettingsResult.fromMap,
        arguments: {'enabled': enabled},
      );

  Future<TelemetrySettingsResult> setGpsEnabled(bool enabled) => _invoke(
    'setGpsEnabled',
    TelemetrySettingsResult.fromMap,
    arguments: {'enabled': enabled},
  );

  Future<TelemetrySettingsResult> setContinuousModeEnabled(bool enabled) =>
      _invoke(
        'setContinuousModeEnabled',
        TelemetrySettingsResult.fromMap,
        arguments: {'enabled': enabled},
      );

  Future<TelemetrySettingsResult> setDebugEventFileEnabled(bool enabled) =>
      _invoke(
        'setDebugEventFileEnabled',
        TelemetrySettingsResult.fromMap,
        arguments: {'enabled': enabled},
      );

  Future<TelemetrySettingsResult> setTemperatureModeHelperEnabled(
    bool enabled,
  ) => _invoke(
    'setTemperatureModeHelperEnabled',
    TelemetrySettingsResult.fromMap,
    arguments: {'enabled': enabled},
  );

  Future<TelemetrySettingsResult> setReplaceOemChargingEnabled(bool enabled) =>
      _invoke(
        'setReplaceOemChargingEnabled',
        TelemetrySettingsResult.fromMap,
        arguments: {'enabled': enabled},
      );

  Future<TelemetrySettingsResult> setExternalChargeControlEnabled(
    bool enabled,
  ) => _invoke(
    'setExternalChargeControlEnabled',
    TelemetrySettingsResult.fromMap,
    arguments: {'enabled': enabled},
  );

  Future<ChargeControlAppStatus> getChargeControlAppStatus() =>
      _invoke('getChargeControlAppStatus', ChargeControlAppStatus.fromMap);

  Future<ChargeControlAppStatus> checkChargeControlAppUpdate() =>
      _invoke('checkChargeControlAppUpdate', ChargeControlAppStatus.fromMap);

  Future<ChargeControlAppStatus> installChargeControlApp() =>
      _invoke('installChargeControlApp', ChargeControlAppStatus.fromMap);

  Stream<double> chargeControlDownloadProgress() {
    final source = _source;
    if (source is ChannelTelemetrySource) {
      return ChannelTelemetrySource.chargeControlDownloadProgress;
    }
    if (source is MockTelemetrySource) {
      return source.chargeControlDownloadProgress;
    }
    return const Stream.empty();
  }

  Stream<int> chargeTargetSocChanges() {
    final source = _source;
    if (source is ChannelTelemetrySource) {
      return ChannelTelemetrySource.chargeTargetSocChanges;
    }
    if (source is MockTelemetrySource) {
      return source.chargeTargetSocChanges;
    }
    return const Stream.empty();
  }

  Stream<ChargeControlState> chargeControlStateChanges() {
    final source = _source;
    if (source is ChannelTelemetrySource) {
      return ChannelTelemetrySource.chargeControlStateChanges;
    }
    if (source is MockTelemetrySource) {
      return source.chargeControlStateChanges;
    }
    return const Stream.empty();
  }

  Future<ChargeControlState> getChargeControlState() =>
      _invoke('getChargeControlState', ChargeControlState.fromMap);

  Future<ChargeControlState> setChargingAmperage(int amps) => _invoke(
    'setChargingAmperage',
    ChargeControlState.fromMap,
    arguments: {'amps': amps},
  );

  Future<ChargeControlState> setForceCharging(bool force) => _invoke(
    'setForceCharging',
    ChargeControlState.fromMap,
    arguments: {'force': force},
  );

  Future<bool> stopCharging() async {
    final result = await _source.call('stopCharging');
    return result['ok'] == true;
  }

  Future<TelemetrySettingsResult> setChargeTargetSoc(int percent) => _invoke(
    'setChargeTargetSoc',
    TelemetrySettingsResult.fromMap,
    arguments: {'targetSoc': percent},
  );

  Future<int> getChargeTargetSoc() async {
    final result = await _source.call('getChargeTargetSoc');
    return (result['targetSoc'] as num?)?.toInt() ?? 80;
  }

  Future<bool> launchChargeControlApp() async {
    final result = await _source.call('launchChargeControlApp');
    return result['ok'] == true;
  }

  Future<Map<String, Object?>> setProjectionBetaEnabled(bool enabled) =>
      _source.call('setProjectionBetaEnabled', {'enabled': enabled});

  /// The screen something outside the app asked for, cleared as it is read.
  ///
  /// It is a *take*: the launch opens one screen, so a second reader — the
  /// other shell, or a restarted one — must not open it again.
  Future<String?> takePendingDestination() async {
    final result = await _source.call('takePendingDestination');
    return result['destination'] as String?;
  }

  Future<TelemetrySettingsResult> setDefaultChargeCostPerKwh(double? value) =>
      _invoke(
        'setDefaultChargeCostPerKwh',
        TelemetrySettingsResult.fromMap,
        arguments: {'value': value},
      );

  Future<TelemetrySettingsResult> setPackCapacityWh(double? value) => _invoke(
    'setPackCapacityWh',
    TelemetrySettingsResult.fromMap,
    arguments: {'value': value},
  );

  /// Puts the default rate on every past charge that carries no price.
  ///
  /// The rate is written into each session, so the record states what the
  /// reader decided instead of a total changing the day the default changes.
  Future<DefaultChargeCostApplication> applyDefaultChargeCostToUnpriced() =>
      _invoke(
        'applyDefaultChargeCostToUnpriced',
        DefaultChargeCostApplication.fromMap,
      );

  Future<DevicePairingState> startDevicePairing() async {
    final res = await _source.call('startDevicePairing');
    final state = DevicePairingState.fromMap(res);
    if (state == null) {
      throw StateError('startDevicePairing returned an invalid state: $res');
    }
    return state;
  }

  Future<DevicePairingState?> getDevicePairingState() async {
    final res = await _source.callOrNull('getDevicePairingState');
    if (res == null) return null;
    final state = DevicePairingState.fromMap(res);
    if (state == null) {
      throw StateError('getDevicePairingState returned an invalid state: $res');
    }
    return state;
  }

  Future<DevicePairingState?> cancelDevicePairing() async {
    final res = await _source.callOrNull('cancelDevicePairing');
    if (res == null) return null;
    final state = DevicePairingState.fromMap(res);
    if (state == null) {
      throw StateError('cancelDevicePairing returned an invalid state: $res');
    }
    return state;
  }

  Future<List<CompanionDevice>> getPairedCompanionDevices() async {
    final res = await _source.callOrNull('getPairedCompanionDevices');
    final list = res?['devices'] as List<Object?>?;
    if (list == null) return const [];
    return list
        .whereType<Map<Object?, Object?>>()
        .map((m) => CompanionDevice.fromMap(m.cast<String, Object?>()))
        .whereType<CompanionDevice>()
        .toList();
  }

  /// Runs one cloud upload pass right now, and says what the car did.
  ///
  /// The car call blocks on the network; the screen shows a busy state while
  /// it runs. The report names the rows that moved, or the failure — and it
  /// says plainly when cloud sync is off for this build instead of
  /// pretending to sync.
  Future<CloudSyncResult> forceCloudSync() async {
    final res = await _source.callOrNull('forceCloudSync');
    return CloudSyncResult.fromMap(res);
  }

  /// Marks the whole local telemetry history for upload again, and returns
  /// the number of rows the car marked.
  ///
  /// A developer tool: it lets a test resend history after the cloud copy was
  /// wiped. The rows move on the next upload pass, not in this call.
  Future<int> markCloudHistoryDirty() => _invoke(
    'markCloudHistoryDirty',
    (map) => (map['markedRows'] as num?)?.toInt() ?? 0,
  );

  /// Returns the current cloud synchronization progress across all tracked tables,
  /// derived from dirty vs clean counts in the local database.
  Future<SyncProgressData> getCloudSyncProgress() async {
    final res = await _source.callOrNull('getCloudSyncProgress');
    return SyncProgressData.fromMap(res?.cast<String, Object?>());
  }

  /// Whether the car is actively streaming live telemetry to any connected BLE peer.
  Future<bool> isBleStreamActive() async {
    final res = await _source.callOrNull('isBleStreamActive');
    return res?['active'] as bool? ?? false;
  }

  Future<bool> revokeCompanionDevice(String deviceId) async {
    final res = await _source.callOrNull('revokeCompanionDevice', {
      'deviceId': deviceId,
    });
    return res?['revoked'] as bool? ?? false;
  }

  /// Fires when a session is written, closed, merged or priced.
  ///
  /// A list can read on this instead of on a tick. It does not fire per frame,
  /// so a list showing an open session still needs its own poll for that row's
  /// live values.
  Stream<SessionChange> sessionChanges() => _source.sessionChanges();

  Stream<LiveTelemetryFrame> liveTelemetryStream() {
    // Drop intermediate raw maps before parse when bursts/backpressure queue.
    return coalesceLatest(_source.liveFrames()).map(LiveTelemetryFrame.fromMap);
  }
}

/// Cloud device-pairing state, as returned by the Kotlin method-channel bridge.
///
/// Mirrors `PairingStateMapper` on the car: one sealed type that the screen
/// can `switch` on. Six distinguishable statuses: two live (`idle`, `pending`)
/// and four terminal (`approved`, `expired`, `rejected`, `invalidCode`).
/// `rejected` is intentionally distinct from `expired` and `invalidCode`.
/// Follows the style of [DevicePairingState] in this file: `@immutable`,
/// `const` constructors, `fromMap` returning `null` on a malformed map, value
/// equality, and a concise `toString`.
@immutable
sealed class DevicePairingState {
  const DevicePairingState();

  /// Wire `status` value (`idle` | `pending` | `registered` | `approved` |
  /// `expired` | `rejected` | `invalidCode`).
  String get status;

  /// Parses the Kotlin bridge map. Returns `null` when the map is malformed
  /// (missing `status`, wrong type, or missing required field for that status).
  static DevicePairingState? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final statusRaw = map['status'];
    if (statusRaw is! String) return null;
    final status = statusRaw;
    switch (status) {
      case 'idle':
        return DevicePairingIdle.fromMap(map);
      case 'pending':
        return DevicePairingPending.fromMap(map);
      case 'registered':
        return DevicePairingRegistered.fromMap(map);
      case 'approved':
        return DevicePairingApproved.fromMap(map);
      case 'expired':
        return DevicePairingExpired.fromMap(map);
      case 'rejected':
        return DevicePairingRejected.fromMap(map);
      case 'invalidCode':
        return DevicePairingInvalidCode.fromMap(map);
      case 'revoked':
        return DevicePairingRevoked.fromMap(map);
      default:
        return null;
    }
  }
}

@immutable
class DevicePairingIdle extends DevicePairingState {
  const DevicePairingIdle({this.cancelled = false});

  @override
  String get status => 'idle';

  /// `true` when returned by `cancelDevicePairing` after clearing a pending
  /// session; `false` for a plain `idle` from `getDevicePairingState`.
  final bool cancelled;

  static DevicePairingIdle? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'idle') return null;
    final cancelledRaw = map['cancelled'];
    final cancelled = cancelledRaw is bool ? cancelledRaw : false;
    return DevicePairingIdle(cancelled: cancelled);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePairingIdle &&
          runtimeType == other.runtimeType &&
          cancelled == other.cancelled;

  @override
  int get hashCode => cancelled.hashCode;

  @override
  String toString() => 'DevicePairingIdle(cancelled: $cancelled)';
}

@immutable
class DevicePairingPending extends DevicePairingState {
  const DevicePairingPending({
    required this.vehicleId,
    this.userCode,
    this.expiresAt,
  });

  @override
  String get status => 'pending';

  final String vehicleId;
  final String? userCode;
  final String? expiresAt;

  static DevicePairingPending? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'pending') return null;
    final vehicleIdRaw = map['vehicleId'];
    if (vehicleIdRaw is! String || vehicleIdRaw.isEmpty) return null;
    final userCodeRaw = map['userCode'];
    final expiresAtRaw = map['expiresAt'];
    // userCode / expiresAt may be absent (null) for a recovered pending
    // without a memory-cached start result; when present they must be strings.
    if (userCodeRaw != null && userCodeRaw is! String) return null;
    if (expiresAtRaw != null && expiresAtRaw is! String) return null;
    final userCode = userCodeRaw as String?;
    final expiresAt = expiresAtRaw as String?;
    if (userCode != null && userCode.isEmpty) return null;
    if (expiresAt != null && expiresAt.isEmpty) return null;
    return DevicePairingPending(
      vehicleId: vehicleIdRaw,
      userCode: userCode,
      expiresAt: expiresAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePairingPending &&
          runtimeType == other.runtimeType &&
          vehicleId == other.vehicleId &&
          userCode == other.userCode &&
          expiresAt == other.expiresAt;

  @override
  int get hashCode => Object.hash(vehicleId, userCode, expiresAt);

  @override
  String toString() =>
      'DevicePairingPending(vehicleId: $vehicleId, userCode: $userCode, expiresAt: $expiresAt)';
}

@immutable
class DevicePairingApproved extends DevicePairingState {
  const DevicePairingApproved({
    required this.vehicleId,
    required this.accountId,
    this.cancelled = false,
  });

  @override
  String get status => 'approved';

  final String vehicleId;
  final String accountId;
  final bool cancelled;

  static DevicePairingApproved? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'approved') return null;
    final vehicleIdRaw = map['vehicleId'];
    final accountIdRaw = map['accountId'];
    if (vehicleIdRaw is! String || vehicleIdRaw.isEmpty) return null;
    if (accountIdRaw is! String || accountIdRaw.isEmpty) return null;
    final cancelledRaw = map['cancelled'];
    final cancelled = cancelledRaw is bool ? cancelledRaw : false;
    return DevicePairingApproved(
      vehicleId: vehicleIdRaw,
      accountId: accountIdRaw,
      cancelled: cancelled,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePairingApproved &&
          runtimeType == other.runtimeType &&
          vehicleId == other.vehicleId &&
          accountId == other.accountId &&
          cancelled == other.cancelled;

  @override
  int get hashCode => Object.hash(vehicleId, accountId, cancelled);

  @override
  String toString() =>
      'DevicePairingApproved(vehicleId: $vehicleId, accountId: $accountId, cancelled: $cancelled)';
}

/// A car that registered itself pre-claim (issue #236 P2-T6): it holds a
/// device token but has no owner yet. The sync screen shows this instead of
/// offering a pairing code, since registration already happened.
@immutable
class DevicePairingRegistered extends DevicePairingState {
  const DevicePairingRegistered();

  @override
  String get status => 'registered';

  static DevicePairingRegistered? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'registered') return null;
    return const DevicePairingRegistered();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DevicePairingRegistered;

  @override
  int get hashCode => 'registered'.hashCode;

  @override
  String toString() => 'DevicePairingRegistered()';
}

@immutable
class DevicePairingExpired extends DevicePairingState {
  const DevicePairingExpired({required this.reason});

  @override
  String get status => 'expired';

  final String reason;

  static DevicePairingExpired? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'expired') return null;
    final reasonRaw = map['reason'];
    if (reasonRaw is! String || reasonRaw.isEmpty) return null;
    return DevicePairingExpired(reason: reasonRaw);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePairingExpired &&
          runtimeType == other.runtimeType &&
          reason == other.reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'DevicePairingExpired(reason: $reason)';
}

@immutable
class DevicePairingRejected extends DevicePairingState {
  const DevicePairingRejected({required this.reason});

  @override
  String get status => 'rejected';

  final String reason;

  static DevicePairingRejected? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'rejected') return null;
    final reasonRaw = map['reason'];
    if (reasonRaw is! String || reasonRaw.isEmpty) return null;
    return DevicePairingRejected(reason: reasonRaw);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePairingRejected &&
          runtimeType == other.runtimeType &&
          reason == other.reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'DevicePairingRejected(reason: $reason)';
}

@immutable
class DevicePairingInvalidCode extends DevicePairingState {
  const DevicePairingInvalidCode({required this.reason});

  @override
  String get status => 'invalidCode';

  final String reason;

  static DevicePairingInvalidCode? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'invalidCode') return null;
    final reasonRaw = map['reason'];
    if (reasonRaw is! String || reasonRaw.isEmpty) return null;
    return DevicePairingInvalidCode(reason: reasonRaw);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePairingInvalidCode &&
          runtimeType == other.runtimeType &&
          reason == other.reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'DevicePairingInvalidCode(reason: $reason)';
}

@immutable
class DevicePairingRevoked extends DevicePairingState {
  const DevicePairingRevoked({this.reason = 'revoked'});

  @override
  String get status => 'revoked';

  final String reason;

  static DevicePairingRevoked? fromMap(Map<String, Object?> map) {
    if (map['status'] != 'revoked') return null;
    final reasonRaw = map['reason'];
    final reason = (reasonRaw is String && reasonRaw.isNotEmpty)
        ? reasonRaw
        : 'revoked';
    return DevicePairingRevoked(reason: reason);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePairingRevoked &&
          runtimeType == other.runtimeType &&
          reason == other.reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'DevicePairingRevoked(reason: $reason)';
}

/// Emits at most the newest value per event-loop turn.
///
/// Used so expensive [LiveTelemetryFrame.fromMap] runs once for a burst
/// instead of for every intermediate platform event.
///
/// The returned stream is single-subscription: call
/// [TelemetryApi.liveTelemetryStream] again for each additional listener.
@visibleForTesting
Stream<T> coalesceLatest<T>(Stream<T> source) {
  late StreamController<T> controller;
  StreamSubscription<T>? subscription;
  Timer? flushTimer;
  T? pending;
  var hasPending = false;

  void flush() {
    flushTimer = null;
    if (!hasPending || controller.isClosed) return;
    final value = pending as T;
    pending = null;
    hasPending = false;
    controller.add(value);
  }

  void scheduleFlush() {
    // Timer (event queue) runs after StreamController's microtask deliveries,
    // so a burst of source events collapses to the latest map before parse.
    flushTimer ??= Timer(Duration.zero, flush);
  }

  controller = StreamController<T>(
    onListen: () {
      subscription = source.listen(
        (event) {
          pending = event;
          hasPending = true;
          scheduleFlush();
        },
        onError: controller.addError,
        onDone: () {
          flushTimer?.cancel();
          flushTimer = null;
          if (hasPending && !controller.isClosed) {
            flush();
          }
          if (!controller.isClosed) {
            controller.close();
          }
        },
        cancelOnError: false,
      );
    },
    onCancel: () async {
      flushTimer?.cancel();
      flushTimer = null;
      await subscription?.cancel();
      subscription = null;
    },
  );

  return controller.stream;
}
