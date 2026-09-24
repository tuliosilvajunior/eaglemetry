import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';

void main() {
  test('coalesceLatest keeps only the newest event per turn', () async {
    final controller = StreamController<int>();
    final values = <int>[];
    final done = Completer<void>();
    final sub = coalesceLatest(
      controller.stream,
    ).listen(values.add, onDone: done.complete);

    controller.add(1);
    controller.add(2);
    controller.add(3);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(values, [3]);

    controller.add(4);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(values, [3, 4]);

    await controller.close();
    await done.future;
    await sub.cancel();
  });

  test('coalesceLatest flushes latest on done without delay', () async {
    final controller = StreamController<int>();
    final valuesFuture = coalesceLatest(controller.stream).toList();

    controller
      ..add(10)
      ..add(20)
      ..add(30);
    await controller.close();

    expect(await valuesFuture, [30]);
  });

  test('LiveTelemetryFrame.fromMap accepts typed nested maps without copy', () {
    final signal = <String, Object?>{
      'signalId': 'EV_BATTERY_LEVEL',
      'value': 72.5,
      'unit': '%',
      'quality': 'GOOD',
      'source': 'vhal',
      'propertyId': 291504647,
      'propertyIdHex': '0x11600307',
      'areaId': 0,
      'timestampMillis': 1000,
      'sourceTimestampNanos': 2000,
      'details': '',
      'timestamp': <String, Object?>{
        'receivedAtUtcMillis': 1000,
        'receivedAtElapsedNanos': 3000,
        'sourceTimestampNanos': 2000,
        'accuracy': 'SOURCE_TIMESTAMP',
        'uncertaintyMillis': 0,
      },
    };

    final frame = LiveTelemetryFrame.fromMap({
      'timestampMillis': 1000,
      'updatedSignalId': 'EV_BATTERY_LEVEL',
      'signals': [signal],
      'status': <String, Object?>{
        'running': true,
        'collectorStatus': 'active',
        'vehicleActivity': 'DRIVING',
        'tripState': 'ACTIVE',
        'chargeState': 'DISCONNECTED',
        'callbackSignals': 4,
        'pollingSignals': 2,
        'lastUpdateMillis': 1000,
        'signalCount': 12,
      },
      'trip': <String, Object?>{'state': 'ACTIVE'},
      'charge': const <String, Object?>{},
      'location': const <String, Object?>{},
      'sessions': const <String, Object?>{},
      'frames': const <String, Object?>{},
      'recentEvents': const <Object?>[],
    });

    expect(frame.timestampMillis, 1000);
    expect(frame.updatedSignalId, 'EV_BATTERY_LEVEL');
    expect(frame.signals, hasLength(1));
    expect(frame.signals.single.signalId, 'EV_BATTERY_LEVEL');
    expect(frame.signals.single.value, 72.5);
    expect(frame.signals.single.timestamp?.receivedAtUtcMillis, 1000);
    expect(frame.status?.running, isTrue);
    expect(frame.status?.tripState, 'ACTIVE');
    expect(frame.trip['state'], 'ACTIVE');
    expect(frame.recentEvents, isEmpty);
  });

  test('TelemetryFrame parses Roadcast frame enrichment', () {
    final frame = TelemetryFrame.fromMap({
      'id': 17,
      'canDrivePowerKw': -12.4,
      'canPackVoltageV': 398.7,
      'canPackCurrentA': -2.1,
      'canPackCurrentRaw': 4979,
      'canPackCurrentEstimated': true,
      'canSampleElapsedNanos': 123456789,
    });

    expect(frame.canDrivePowerKw, -12.4);
    expect(frame.canPackVoltageV, 398.7);
    expect(frame.canPackCurrentA, -2.1);
    expect(frame.canPackCurrentRaw, 4979);
    expect(frame.canPackCurrentEstimated, isTrue);
    expect(frame.canSampleElapsedNanos, 123456789);
  });

  test('ChargeMergeCandidatesResult parses native candidate shape', () {
    final result = ChargeMergeCandidatesResult.fromMap({
      'totalCount': 1,
      'limit': 10,
      'candidates': [
        {
          'sessionIds': ['charge-a', 'charge-b'],
          'startUtcMillis': 1000,
          'endUtcMillis': 7000,
          'durationMillis': 6000,
          'startSoc': 56.4,
          'endSoc': 63.3,
          'startOdometerKm': 1627.3,
          'endOdometerKm': 1627.3,
          'totalFrames': 120,
          'breaks': [
            {
              'previousSessionId': 'charge-a',
              'nextSessionId': 'charge-b',
              'gapMillis': 14000,
              'socDelta': 0.0,
              'odometerDeltaKm': 0.0,
            },
          ],
          'sessions': [
            _chargeSessionMap(
              id: 'charge-a',
              startMillis: 1000,
              endMillis: 4000,
              startSoc: 56.4,
              endSoc: 63.3,
              endReason: 'removed_while_charging',
            ),
            _chargeSessionMap(
              id: 'charge-b',
              startMillis: 4000,
              endMillis: 7000,
              startSoc: 63.3,
              endSoc: 63.3,
              endReason: 'removed_after_end',
            ),
          ],
        },
      ],
    });

    expect(result.totalCount, 1);
    expect(result.candidates.single.sessionIds, ['charge-a', 'charge-b']);
    expect(result.candidates.single.sessions, hasLength(2));
    expect(result.candidates.single.breaks.single.gapMillis, 14000);
    expect(result.candidates.single.totalFrames, 120);
  });

  test('TelemetrySettingsResult parses temperature helper switch', () {
    final disabled = TelemetrySettingsResult.fromMap(const {
      'autoStartOnBoot': true,
      'gpsEnabled': false,
      'debugEventFileEnabled': false,
    });
    final enabled = TelemetrySettingsResult.fromMap(const {
      'autoStartOnBoot': true,
      'gpsEnabled': false,
      'debugEventFileEnabled': false,
      'temperatureModeHelperEnabled': true,
    });

    expect(disabled.temperatureModeHelperEnabled, isFalse);
    expect(enabled.temperatureModeHelperEnabled, isTrue);
  });
}

Map<String, Object?> _chargeSessionMap({
  required String id,
  required int startMillis,
  required int endMillis,
  required double startSoc,
  required double endSoc,
  required String endReason,
}) {
  return {
    'id': id,
    'status': 'DISCONNECTED',
    'plugConnectedAtUtcMillis': startMillis,
    'plugConnectedAtElapsedNanos': startMillis * 1000000,
    'chargeStartedAtUtcMillis': startMillis,
    'chargeStartedAtElapsedNanos': startMillis * 1000000,
    'chargeEndedAtUtcMillis': endMillis,
    'chargeEndedAtElapsedNanos': endMillis * 1000000,
    'plugDisconnectedAtUtcMillis': endMillis,
    'plugDisconnectedAtElapsedNanos': endMillis * 1000000,
    'startSoc': startSoc,
    'endSoc': endSoc,
    'startOdometerKm': 1627.3,
    'endOdometerKm': 1627.3,
    'plugType': 605225491,
    'startPowerKw': 1.05,
    'startAmbientTempC': null,
    'endAmbientTempC': null,
    'startLatitude': null,
    'startLongitude': null,
    'startAltitudeM': null,
    'startGpsAccuracyM': null,
    'startLocationProvider': null,
    'startLocationElapsedRealtimeNanos': null,
    'endReason': endReason,
    'createdAtUtcMillis': startMillis,
    'updatedAtUtcMillis': endMillis,
  };
}
