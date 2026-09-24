import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'mock_telemetry_data.dart';

/// The mock, for the web build and for `CAPY_MOCK_TELEMETRY`.
///
/// One switch over the method names, so what the mock answers is readable in
/// one place instead of being spread over 42 closures beside the real calls.
/// A method with no case throws by name, which is the failure a missing mock
/// should produce: loud, and pointing at the method that has no answer.
class MockTelemetrySource implements TelemetrySource {
  MockTelemetrySource({this.answer});

  /// Replaces the answer for one method. Return null to fall through.
  ///
  /// Every method, typed or not, resolves through [_answer], so this one hook
  /// covers the whole surface — including the methods that now travel over
  /// generated channels, which a test cannot stub by name.
  @visibleForTesting
  final Map<String, Object?>? Function(
    String method,
    Map<String, Object?> arguments,
  )?
  answer;

  final MockTelemetryData _mock = MockTelemetryData();

  final _downloadProgressController = StreamController<double>.broadcast();
  Stream<double> get chargeControlDownloadProgress =>
      _downloadProgressController.stream;

  final _chargeTargetSocController = StreamController<int>.broadcast();
  Stream<int> get chargeTargetSocChanges => _chargeTargetSocController.stream;

  final _chargeControlStateController =
      StreamController<ChargeControlState>.broadcast();
  Stream<ChargeControlState> get chargeControlStateChanges =>
      _chargeControlStateController.stream;

  final bool _chargingActive = const bool.fromEnvironment('CAPY_MOCK_CHARGING');

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => _answer(method, arguments ?? const {});

  @override
  Future<Map<String, Object?>?> callOrNull(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => _answer(method, arguments ?? const {});

  @override
  Stream<Map<String, Object?>> liveFrames() => _mock.liveTelemetryStream();

  /// The mock writes no sessions, so nothing ever changes. An empty stream is
  /// the honest answer; a periodic fake event would make the web build refresh
  /// for a write that did not happen.
  @override
  Stream<SessionChange> sessionChanges() => const Stream<SessionChange>.empty();

  @override
  Future<StorageUsage> storageUsage() async {
    final map = _answer('getStorageUsage', const {});
    if (map.isEmpty) {
      return const StorageUsage(
        bytes: 0,
        databaseBytes: 0,
        walBytes: 0,
        shmBytes: 0,
      );
    }
    return StorageUsage.fromMap(map);
  }

  @override
  Future<List<Map<String, Object?>>> eventsForSession(String sessionId) async =>
      const [];

  @override
  Future<EnergyWindowBucketsResult> energyBucketsInWindow(int minutes) async =>
      EnergyWindowBucketsResult.fromMap(
        _answer('getEnergyBucketsInWindow', {'minutes': minutes}),
      );

  @override
  Future<EnergyWindowBucketsResult> parkedEnergyBucketsInWindow(
    int minutes,
  ) async => EnergyWindowBucketsResult.fromMap(
    _answer('getParkedEnergyBucketsInWindow', {'minutes': minutes}),
  );

  @override
  Future<LiveEnergyBucketsResult> liveEnergyBuckets() async =>
      LiveEnergyBucketsResult.fromMap(
        _answer('getLiveEnergyBuckets', const {}),
      );

  @override
  Future<LiveEnergyBucketsResult> liveEfficiencyBuckets() async =>
      LiveEnergyBucketsResult.fromMap(
        _answer('getLiveEfficiencyBuckets', const {}),
      );

  @override
  Future<LiveEnergyBucketsResult> liveChargeEnergyBuckets() async =>
      LiveEnergyBucketsResult.fromMap(
        _answer('getLiveChargeEnergyBuckets', const {}),
      );

  @override
  Future<LiveEnergyBucketsResult> liveContinuousEnergyBuckets() async =>
      LiveEnergyBucketsResult.fromMap(
        _answer('getLiveContinuousEnergyBuckets', const {}),
      );

  @override
  Future<RangeEstimate> rangeEstimate() async =>
      RangeEstimate.fromMap(_answer('getRangeEstimate', const {}));

  @override
  Future<HeadingReading> heading() async =>
      HeadingReading.fromMap(_answer('getHeading', const {}));

  @override
  Future<BatteryCyclesResult> batteryCycles(int limit) async =>
      BatteryCyclesResult.fromMap(
        _answer('getBatteryCycles', {'limit': limit}),
      );

  @override
  Future<BatteryCycleSessionsResult> batteryCycleSessions(int ordinal) async =>
      BatteryCycleSessionsResult.fromMap(
        _answer('getBatteryCycleSessions', {'ordinal': ordinal}),
      );

  @override
  Future<InsightTripsResult> insightTrips(String? subjectId) async =>
      InsightTripsResult.fromMap(
        _answer('getInsightTrips', {'subjectId': subjectId}),
      );

  @override
  Future<InsightPlacesResult> insightPlaces() async =>
      InsightPlacesResult.fromMap(_answer('getInsightPlaces', const {}));

  @override
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = kInsightPlaceRadiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) async {
    final map = _answer('saveInsightPlace', {
      'id': id,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'radiusM': radiusM,
      'autoName': autoName,
      'autoNameUpdatedAtUtcMillis': autoNameUpdatedAtUtcMillis,
      'autoNameSource': autoNameSource,
    });
    return InsightPlacesResult.fromMap({
      'places': [map],
    }).places.first;
  }

  @override
  Future<void> deleteInsightPlace(String id) async {
    _answer('deleteInsightPlace', {'id': id});
  }

  @override
  Future<ChargeMergeCandidatesResult> chargeMergeCandidates(int limit) async =>
      ChargeMergeCandidatesResult.fromMap(
        _answer('getChargeMergeCandidates', {'limit': limit}),
      );

  @override
  Future<ChargeMergeResult> mergeChargeSessions(
    List<String> sessionIds,
  ) async => ChargeMergeResult.fromMap(
    _answer('mergeChargeSessions', {'sessionIds': sessionIds}),
  );

  @override
  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    required double? costPerKwh,
    required double? paidAmount,
    required String currency,
  }) async => ChargeSessionCostUpdateResult.fromMap(
    _answer('updateChargeSessionCost', {
      'sessionId': sessionId,
      'costPerKwh': costPerKwh,
      'paidAmount': paidAmount,
      'currency': currency,
    }),
  );

  @override
  Stream<AnnotationChange> annotationsChanged() =>
      const Stream<AnnotationChange>.empty();

  @override
  Future<List<PreferenceRow>> preferenceRows() async => [
    for (final row
        in (_answer('getPreferenceRows', const {})['rows'] as List<Object?>? ??
            const []))
      PreferenceRow.fromMap(row as Map<String, Object?>)!,
  ];

  @override
  Future<PreferenceRow?> savePreferenceRow({
    required String scope,
    required String key,
    String? value,
  }) async {
    final answer = _answer('savePreferenceRow', {
      'scope': scope,
      'key': key,
      'value': value,
    });
    if (answer['ok'] == false) return null;
    return PreferenceRow.fromMap(answer);
  }

  @override
  Future<List<PreferenceProposal>> preferenceProposals() async => [
    for (final row
        in (_answer('getPreferenceProposals', const {})['proposals']
                as List<Object?>? ??
            const []))
      PreferenceProposal.fromMap(row as Map<String, Object?>)!,
  ];

  @override
  Future<PreferenceProposal?> proposePreference({
    required String key,
    String? value,
  }) async {
    final map = _answer('proposePreference', {'key': key, 'value': value});
    return PreferenceProposal.fromMap(map);
  }

  @override
  Future<PreferenceProposal?> decidePreferenceProposal({
    required String id,
    required bool accept,
  }) async {
    final map = _answer('decidePreferenceProposal', {
      'id': id,
      'accept': accept,
    });
    return PreferenceProposal.fromMap(map);
  }

  Map<String, Object?> _answer(String method, Map<String, Object?> args) =>
      answer?.call(method, args) ?? _builtIn(method, args);

  Map<String, Object?> _builtIn(String method, Map<String, Object?> args) =>
      switch (method) {
        'getPlatformStatus' => _mock.platformStatus(),
        'getTelemetrySnapshot' => _mock.telemetrySnapshot(
          isCharging: _chargingActive,
        ),
        'startTelemetryCollection' => _mock.collectorStatus(),
        'stopTelemetryCollection' => _mock.collectorStatus(running: false),
        'getCollectorStatus' => _mock.collectorStatus(),
        // The mock stands in for the shipped vehicle, so it claims what that
        // profile claims. A mock that reported no capability would hide every
        // destination on the web build.
        'getVehicleCapabilities' => <String, dynamic>{
          'profileId': 'geely-ex2-flyme',
          'capabilities': VehicleCapabilities.knownNames.toList()..sort(),
        },
        'getRoadcastStatus' => _mock.roadcastStatus(),
        'restartRoadcastDaemon' => _mock.roadcastStatus(),
        'getAppUpdateStatus' => _mock.appUpdateStatus(),
        'checkAppUpdate' => _mock.appUpdateStatus(checked: true),
        'installAppUpdate' => _mock.appUpdateStatus(
          checked: true,
          updateAvailable: false,
          installScheduled: true,
        ),
        'getRoadcastUpdateStatus' => _mock.roadcastUpdateStatus(),
        'checkRoadcastUpdate' => _mock.roadcastUpdateStatus(checked: true),
        'updateRoadcastDaemon' => _mock.roadcastUpdateStatus(
          checked: true,
          installed: true,
        ),
        'getLiveTelemetrySnapshot' => _mock.liveFrame(),
        'getHvacControlStatus' => const {
          'ok': true,
          'action': 'status',
          'temperatureC': 22.0,
          'fanSpeed': 3,
          'details': ['mock HVAC status'],
        },
        'stepHvacTemperature' => _stepTemperature(_double(args['delta'])),
        'stepHvacFanSpeed' => _stepFanSpeed(_int(args['delta'])),
        'setHvacTemperature' => _mock.hvacSetTemperature(
          _double(args['temperatureC']),
        ),
        'setHvacFanSpeed' => _mock.hvacSetFanSpeed(_int(args['fanSpeed'])),
        'getTelemetryEvents' => _mock.events(limit: _int(args['limit'])),
        'getChargeMergeCandidates' => const {
          'candidates': <Object?>[],
          'totalCount': 0,
          'limit': 10,
        },
        'mergeChargeSessions' => _merge(_strings(args['sessionIds'])),
        'updateChargeSessionCost' => _updateCost(args),
        'getBatteryCycles' => _mock.batteryCycles(limit: _int(args['limit'])),
        'getBatteryCycleSessions' => _mock.batteryCycleSessions(
          ordinal: _int(args['ordinal']),
        ),
        'getInsightTrips' => _mock.insightTrips(
          subjectId: args['subjectId'] as String?,
        ),
        'getInsightPlaces' => _mock.insightPlaces(),
        'saveInsightPlace' => _mock.saveInsightPlace(
          id: args['id'] as String?,
          name: _string(args['name']),
          latitude: (args['latitude'] as num?)?.toDouble() ?? 0,
          longitude: (args['longitude'] as num?)?.toDouble() ?? 0,
          radiusM: (args['radiusM'] as num?)?.toDouble() ?? 150,
          autoName: args['autoName'] as String?,
          autoNameUpdatedAtUtcMillis:
              (args['autoNameUpdatedAtUtcMillis'] as num?)?.toInt(),
          autoNameSource: args['autoNameSource'] as String?,
        ),
        'deleteInsightPlace' => _mock.deleteInsightPlace(_string(args['id'])),
        'getPreferenceRows' => _mock.preferenceRows(),
        'savePreferenceRow' => _mock.savePreferenceRow(
          scope: _string(args['scope']),
          key: _string(args['key']),
          value: args['value'] as String?,
        ),
        'getPreferenceProposals' => _mock.preferenceProposals(),
        'proposePreference' =>
          _mock.proposePreference(
                key: _string(args['key']),
                value: args['value'] as String?,
              ) ??
              const {},
        'decidePreferenceProposal' =>
          _mock.decidePreferenceProposal(
                id: _string(args['id']),
                accept: args['accept'] as bool? ?? false,
              ) ??
              const {},
        'getEnergyBucketsInWindow' => _mock.energyBucketsInWindow(
          minutes: _int(args['minutes']),
        ),
        'getParkedEnergyBucketsInWindow' => _mock.parkedEnergyBucketsInWindow(
          minutes: _int(args['minutes']),
        ),
        'getLiveEnergyBuckets' => _mock.liveEnergyBuckets(),
        'getLiveEfficiencyBuckets' => _mock.liveEfficiencyBuckets(),
        'getLiveChargeEnergyBuckets' => _mock.liveChargeEnergyBuckets(),
        'getLiveContinuousEnergyBuckets' => _mock.liveContinuousEnergyBuckets(),
        'getRangeEstimate' => _mock.rangeEstimate(),
        'getHeading' => _mock.heading(),
        'clearTelemetryDatabase' => _mock.clearTelemetryDatabase(),
        'runTelemetryRetention' => _mock.retention(),
        'getStorageUsage' => const {
          'bytes': 5242880,
          'databaseBytes': 5242880,
          'walBytes': 0,
          'shmBytes': 0,
        },
        'getTelemetrySettings' => _mock.settings(),
        'startDevicePairing' => {
          'status': 'pending',
          'userCode': '123-456',
          'expiresAt': '2099-01-01T00:00:00.000Z',
          'vehicleId': 'mock-vehicle',
        },
        'getDevicePairingState' => const {'status': 'idle'},
        'cancelDevicePairing' => const {'status': 'idle', 'cancelled': true},
        'getPairedCompanionDevices' => const {'devices': <Object?>[]},
        'revokeCompanionDevice' => const {'revoked': true},
        'forceCloudSync' => const {
          'cloudReady': true,
          'movedRows': 0,
          'failed': false,
        },
        'getCloudSyncProgress' => const {'totalCount': 0, 'dirtyCount': 0},
        'markCloudHistoryDirty' => const {'markedRows': 0},
        'isBleStreamActive' => const {'active': false},
        'setAutoStartOnBoot' => _mock.settings(
          autoStartOnBoot: _bool(args['enabled']),
        ),
        'setGpsEnabled' => _mock.settings(gpsEnabled: _bool(args['enabled'])),
        'setContinuousModeEnabled' => _mock.settings(
          continuousModeEnabled: _bool(args['enabled']),
        ),
        'setKeepBluetoothOnEnabled' => _mock.settings(
          keepBluetoothOnEnabled: _bool(args['enabled']),
        ),
        'setDebugEventFileEnabled' => _mock.settings(
          debugEventFileEnabled: _bool(args['enabled']),
        ),
        'setTemperatureModeHelperEnabled' => _mock.settings(
          temperatureModeHelperEnabled: _bool(args['enabled']),
        ),
        'setReplaceOemChargingEnabled' => _mock.settings(
          replaceOemChargingEnabled: _bool(args['enabled']),
        ),
        'setExternalChargeControlEnabled' => _mock.settings(
          externalChargeControlEnabled: _bool(args['enabled']),
        ),
        'setChargeTargetSoc' => _mock.settings(
          chargeTargetSoc: (args['targetSoc'] as num?)?.toInt() ?? 80,
        ),
        'getChargeTargetSoc' => <String, Object?>{'targetSoc': 80},
        'getChargeControlAppStatus' => _mock.chargeControlAppStatus(),
        'checkChargeControlAppUpdate' => _mock.chargeControlAppStatus(
          updateAvailable: true,
        ),
        'installChargeControlApp' => _mock.chargeControlAppStatus(
          installed: true,
          installScheduled: true,
        ),
        'launchChargeControlApp' => const <String, Object?>{'ok': true},
        'getChargeControlState' => const <String, Object?>{
          'targetSoc': 80,
          'amps': 16,
          'minAmps': 5,
          'maxAmps': 32,
          'forceCharging': false,
        },
        'setChargingAmperage' => <String, Object?>{
          'targetSoc': 80,
          'amps': (args['amps'] as num?)?.toInt() ?? 16,
          'minAmps': 5,
          'maxAmps': 32,
          'forceCharging': false,
        },
        'setForceCharging' => <String, Object?>{
          'targetSoc': 80,
          'amps': 16,
          'minAmps': 5,
          'maxAmps': 32,
          'forceCharging': args['force'] == true,
        },
        'stopCharging' => const <String, Object?>{'ok': true},
        'setProjectionBetaEnabled' => const <String, Object?>{'ok': true},
        // Nothing launches the mock, so it is never opened for a screen.
        'takePendingDestination' => const <String, Object?>{
          'destination': null,
        },
        'setDefaultChargeCostPerKwh' => _mock.settings(
          defaultChargeCostPerKwh: args['value'] as double?,
        ),
        'setPackCapacityWh' => _mock.settings(
          packCapacityWh: (args['value'] as num?)?.toDouble() ?? 39600,
        ),
        'applyDefaultChargeCostToUnpriced' => <String, Object?>{
          'ok': true,
          'updatedRows': 3,
          'costPerKwh': 0.9,
          'currency': 'BRL',
          'error': null,
        },
        _ => throw StateError('the mock has no answer for $method'),
      };

  Map<String, Object?> _stepTemperature(double delta) => {
    'ok': true,
    'action': 'stepTemperature',
    'requestedValue': delta,
    'appliedValue': 22.0 + delta,
    'propertyIdHex': '0x15600503',
    'areaId': 1,
    'details': const ['mock temperature step'],
  };

  Map<String, Object?> _stepFanSpeed(int delta) => {
    'ok': true,
    'action': 'stepFanSpeed',
    'requestedValue': delta,
    'appliedValue': 3 + delta,
    'propertyIdHex': '0x15400500',
    'areaId': 5,
    'details': const ['mock fan speed step'],
  };

  Map<String, Object?> _merge(List<String> sessionIds) => {
    'ok': true,
    'error': null,
    'mergedSessionId': sessionIds.isEmpty ? null : sessionIds.first,
    'mergedCount': sessionIds.length,
    'framesReassigned': 0,
    'deletedSessions': (sessionIds.length - 1).clamp(0, sessionIds.length),
  };

  Map<String, Object?> _updateCost(Map<String, Object?> args) => {
    'ok': true,
    'updatedRows': 1,
    'session': {
      'id': _string(args['sessionId']),
      'costPerKwh': args['costPerKwh'],
      'paidAmount': args['paidAmount'],
      'costCurrency': _string(args['currency']),
    },
  };

  static int _int(Object? value) => value is num ? value.toInt() : 0;
  static double _double(Object? value) => value is num ? value.toDouble() : 0.0;
  static bool _bool(Object? value) => value == true;
  static String _string(Object? value) => value is String ? value : '';
  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const <String>[];
}
