import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_data.dart';
import 'package:capy_energy/core/range_estimate_controller.dart';
import 'package:capy_energy/core/telemetry_api.dart';

void main() {
  group('mock range estimate', () {
    test('parses into a valid DTO and stays consistent', () {
      final estimate = RangeEstimate.fromMap(
        MockTelemetryData().rangeEstimate(),
      );

      // The mock mirrors the 2026-08-04 car read (266 km) and the same SOC and
      // efficiency the other mock surfaces report.
      expect(estimate.carRangeKm, 266.0);
      expect(estimate.carRangeAvailable, isTrue);
      expect(estimate.carRangePropertyId, 289407752);
      expect(estimate.carRangeSignalSource, 'VHAL_CALLBACK');
      expect(estimate.socPercent, 63.4);
      expect(estimate.capacityKwh, MockTelemetryData.batteryCapacityWh / 1000);
      expect(estimate.capacitySource, 'SETTINGS');
      expect(estimate.efficiencySource, 'CLOSED_TRIPS_7D');
      expect(estimate.efficiencyAvailable, isTrue);
      expect(estimate.ownRangeAvailable, isTrue);
      expect(estimate.ownRangeKm, greaterThan(0));

      // 63.4% of capacity x efficiency must equal the projected value: the
      // vehicle value is not copied into the app estimate.
      final expectedOwn = estimate.socPercent! / 100 * estimate.fullRangeKm!;
      expect(estimate.ownRangeKm, closeTo(expectedOwn, 0.001));
    });

    test('stopped collection exposes unavailable values with reasons', () {
      final estimate = RangeEstimate.fromMap(
        MockTelemetryData().rangeEstimate(collecting: false),
      );

      expect(estimate.carRangeAvailable, isFalse);
      expect(estimate.carRangeReason, 'COLLECTION_STOPPED');
      expect(estimate.ownRangeAvailable, isFalse);
      expect(estimate.ownRangeReason, 'COLLECTION_STOPPED');
      expect(estimate.socPercent, isNull);
    });
  });

  group('RangeEstimate.fromMap', () {
    test('parses a full valid reply', () {
      final estimate = RangeEstimate.fromMap(_validMap());

      expect(estimate.timestampMillis, 42);
      expect(estimate.carRangeKm, 266.0);
      expect(estimate.carRangeAvailable, isTrue);
      expect(estimate.carRangeReason, isNull);
      expect(estimate.carRangePropertyId, 289407752);
      expect(estimate.carRangeSignalSource, 'VHAL_CALLBACK');
      expect(estimate.carRangeSourceTimestampNanos, 7);
      expect(estimate.socPercent, 63.4);
      expect(estimate.capacityKwh, 39.1);
      expect(estimate.capacitySource, 'SETTINGS');
      expect(estimate.efficiencyKmPerKwh, 7.18);
      expect(estimate.efficiencySource, 'CLOSED_TRIPS_7D');
      expect(estimate.efficiencyWindowDays, 7);
      expect(estimate.efficiencyTripCount, 2);
      expect(estimate.ownRangeKm, closeTo(177.99, 0.01));
      expect(estimate.ownRangeAvailable, isTrue);
      expect(estimate.ownRangeDegraded, isFalse);
    });

    test('missing fields parse safely as unavailable', () {
      final estimate = RangeEstimate.fromMap(const {});

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeAvailable, isFalse);
      expect(estimate.ownRangeKm, isNull);
      expect(estimate.ownRangeAvailable, isFalse);
      expect(estimate.carRangeReason, isNull);
      // A malformed reply cannot claim the native nameplate fallback.
      expect(estimate.capacityKwh, 0);
      expect(estimate.capacitySource, isEmpty);
      expect(estimate.efficiencyKmPerKwh, isNull);
      expect(estimate.efficiencyTripCount, 0);
    });

    test('wrong numeric types do not crash and stay unavailable', () {
      final estimate = RangeEstimate.fromMap({
        ..._validMap(),
        'carRangeKm': 'not-a-number',
        'fullRangeKm': <Object>[],
        'socPercent': null,
        'capacityKwh': 'boom',
        'efficiencyTripCount': 'many',
      });

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeAvailable, isFalse);
      expect(estimate.fullRangeKm, isNull);
      expect(estimate.socPercent, isNull);
      expect(estimate.efficiencyTripCount, 0);
    });

    test('unknown quality strings parse as unavailable', () {
      final estimate = RangeEstimate.fromMap({
        ..._validMap(),
        'carRangeQuality': 'SOMETHING_NEW',
        'ownRangeQuality': 'SOMETHING_NEW',
      });

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeAvailable, isFalse);
      expect(estimate.ownRangeKm, isNull);
      expect(estimate.ownRangeAvailable, isFalse);
      expect(estimate.ownRangeDegraded, isFalse);
    });

    test('unknown source strings invalidate their associated values', () {
      final estimate = RangeEstimate.fromMap({
        ..._validMap(),
        'carRangeSignalSource': 'FUTURE_SOURCE',
        'capacitySource': 'FUTURE_CAPACITY',
        'efficiencySource': 'FUTURE_EFFICIENCY',
      });

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeAvailable, isFalse);
      expect(estimate.ownRangeKm, isNull);
      expect(estimate.fullRangeKm, isNull);
      expect(estimate.ownRangeAvailable, isFalse);
    });

    test('negative and incoherent range values parse as unavailable', () {
      final estimate = RangeEstimate.fromMap({
        ..._validMap(),
        'carRangeKm': -1.0,
        'socPercent': 101.0,
        'capacityKwh': -39.1,
        'fullRangeKm': -280.0,
        'ownRangeKm': -178.0,
      });

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeAvailable, isFalse);
      expect(estimate.ownRangeKm, isNull);
      expect(estimate.fullRangeKm, isNull);
      expect(estimate.ownRangeAvailable, isFalse);
    });

    test('non-finite numbers are treated as missing', () {
      final estimate = RangeEstimate.fromMap({
        ..._validMap(),
        'carRangeKm': double.nan,
        'ownRangeKm': double.infinity,
        'fullRangeKm': double.nan,
        'efficiencyKmPerKwh': double.infinity,
      });

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeAvailable, isFalse);
      expect(estimate.ownRangeKm, isNull);
      expect(estimate.ownRangeAvailable, isFalse);
      expect(estimate.fullRangeKm, isNull);
      expect(estimate.efficiencyAvailable, isFalse);
    });

    test('degraded quality keeps the value but flags the state', () {
      final estimate = RangeEstimate.fromMap({
        ..._validMap(),
        'ownRangeQuality': 'DEGRADED',
        'ownRangeReason': 'EFFICIENCY_REFRESH_FAILED',
      });

      expect(estimate.ownRangeKm, isNotNull);
      expect(estimate.ownRangeAvailable, isFalse);
      expect(estimate.ownRangeDegraded, isTrue);
      expect(estimate.ownRangeReason, 'EFFICIENCY_REFRESH_FAILED');
    });
  });

  group('RangeEstimateController', () {
    test('start issues an immediate read and polls on cadence', () {
      fakeAsync((async) {
        final fake = _FakeApi();
        final controller = RangeEstimateController(
          telemetryApi: fake,
          pollInterval: const Duration(seconds: 2),
        );

        controller.start();
        async.flushMicrotasks();
        expect(fake.callCount, 1);
        expect(controller.estimate, isNotNull);

        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(fake.callCount, 4);
        expect(controller.estimate, isNotNull);

        controller.stop();
      });
    });

    test('start and stop are idempotent', () {
      fakeAsync((async) {
        final fake = _FakeApi();
        final controller = RangeEstimateController(
          telemetryApi: fake,
          pollInterval: const Duration(seconds: 2),
        );

        controller.start();
        controller.start();
        controller.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        // Initial read plus one scheduled tick, not a pile-up from triple start.
        expect(fake.callCount, 2);

        controller.stop();
        controller.stop();
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(fake.callCount, 2);
      });
    });

    test('stop then start resumes with an immediate read', () {
      fakeAsync((async) {
        final fake = _FakeApi();
        final controller = RangeEstimateController(
          telemetryApi: fake,
          pollInterval: const Duration(seconds: 2),
        );

        controller.start();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        controller.stop();
        final beforeResume = fake.callCount;

        controller.start();
        async.flushMicrotasks();
        expect(fake.callCount, beforeResume + 1);

        controller.stop();
      });
    });

    test('a failed poll keeps the last DTO within the staleness window', () {
      fakeAsync((async) {
        final fake = _FakeApi()..failOnCall(2);
        var now = DateTime.fromMillisecondsSinceEpoch(1_000_000);
        final controller = RangeEstimateController(
          telemetryApi: fake,
          pollInterval: const Duration(seconds: 2),
        )..setClockForTest(() => now);

        controller.start();
        async.elapse(const Duration(seconds: 2)); // second poll fails here
        async.flushMicrotasks();

        expect(fake.callCount, 2);
        expect(controller.estimate, isNotNull);
        expect(controller.hasFailed, isTrue);

        now = now.add(const Duration(seconds: 9));
        expect(controller.estimate, isNotNull);

        now = now.add(const Duration(seconds: 2));
        expect(controller.estimate, isNull);

        controller.stop();
      });
    });

    test('a later success clears the failure', () {
      fakeAsync((async) {
        final fake = _FakeApi()..failOnCall(2);
        final controller = RangeEstimateController(
          telemetryApi: fake,
          pollInterval: const Duration(seconds: 2),
        );

        controller.start();
        async.elapse(const Duration(seconds: 2)); // fails
        async.flushMicrotasks();
        expect(controller.hasFailed, isTrue);

        async.elapse(const Duration(seconds: 2)); // succeeds again
        async.flushMicrotasks();
        expect(controller.hasFailed, isFalse);
        expect(controller.estimate, isNotNull);

        controller.stop();
      });
    });

    test(
      'kilometersAt scales the native full range and rejects bad targets',
      () {
        fakeAsync((async) {
          final fake = _FakeApi(fullRangeKm: 280.0);
          final controller = RangeEstimateController(telemetryApi: fake);
          controller.start();
          async.flushMicrotasks();
          expect(controller.fullRangeKm, 280.0);

          expect(controller.kilometersAt(0), 0);
          expect(controller.kilometersAt(50), 140.0);
          expect(controller.kilometersAt(100), 280.0);

          expect(controller.kilometersAt(-1), isNull);
          expect(controller.kilometersAt(101), isNull);
          expect(controller.kilometersAt(double.nan), isNull);
          expect(controller.kilometersAt(double.infinity), isNull);

          controller.stop();
        });
      },
    );

    test('kilometersAt stays null while the native factor is unavailable', () {
      final controller = RangeEstimateController(telemetryApi: _FakeApi());
      controller.reset();
      expect(controller.kilometersAt(80), isNull);
      expect(controller.fullRangeKm, isNull);
    });
  });
}

Map<String, Object?> _validMap() => {
  'timestampMillis': 42,
  'carRangeKm': 266.0,
  'carRangeQuality': 'AVAILABLE',
  'carRangeReason': null,
  'carRangePropertyId': 289407752,
  'carRangeSignalSource': 'VHAL_CALLBACK',
  'carRangeReceivedAtUtcMillis': 9,
  'carRangeSourceTimestampNanos': 7,
  'socPercent': 63.4,
  'capacityKwh': 39.1,
  'capacitySource': 'SETTINGS',
  'efficiencyKmPerKwh': 7.18,
  'efficiencySource': 'CLOSED_TRIPS_7D',
  'efficiencyWindowDays': 7,
  'efficiencyTripCount': 2,
  'efficiencyDistanceKm': 24.7,
  'efficiencyNetEnergyKwh': 3.44,
  'efficiencyUpdatedAtUtcMillis': 5,
  'fullRangeKm': 280.738,
  'ownRangeKm': 178.0,
  'ownRangeQuality': 'AVAILABLE',
  'ownRangeReason': null,
};

class _FakeApi extends TelemetryApi {
  _FakeApi({this.fullRangeKm = 280.738}) : super();

  final double fullRangeKm;
  int callCount = 0;
  final Set<int> failOn = {};

  _FakeApi failOnCall(int callNumber) {
    failOn.add(callNumber);
    return this;
  }

  @override
  Future<RangeEstimate> getRangeEstimate() async {
    callCount++;
    if (failOn.contains(callCount)) {
      throw Exception('poll $callCount failed');
    }
    return RangeEstimate.fromMap({
      ..._validMap(),
      'fullRangeKm': fullRangeKm,
      'ownRangeKm': 70.0 / 100 * fullRangeKm,
    });
  }
}
