import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/range_drop_controller.dart';
import 'package:capy_energy/core/telemetry_api.dart';

/// A range estimate built through the DTO's own gates, so the test cannot
/// hand the controller a reading the app would never show.
RangeEstimate _estimate({
  double? carRangeKm = 266,
  double? ownRangeKm = 200,
  String carReason = '',
  String ownReason = '',
  String ownQuality = 'AVAILABLE',
}) {
  const capacityKwh = 60.0;
  const efficiencyKmPerKwh = 7.18;
  return RangeEstimate.fromMap({
    'timestampMillis': 0,
    'carRangeKm': carRangeKm,
    'carRangeQuality': carRangeKm == null ? 'UNAVAILABLE' : 'AVAILABLE',
    'carRangeReason': carReason.isEmpty ? null : carReason,
    'carRangePropertyId': RangeEstimate.rangeRemainingPropertyId,
    'carRangeSignalSource': carRangeKm == null ? null : 'VHAL_CALLBACK',
    'carRangeReceivedAtUtcMillis': 0,
    'carRangeSourceTimestampNanos': 0,
    'socPercent': ownRangeKm == null ? null : 50.0,
    'capacityKwh': capacityKwh,
    'capacitySource': 'SETTINGS',
    'efficiencyKmPerKwh': efficiencyKmPerKwh,
    'efficiencySource': 'CLOSED_TRIPS_7D',
    'efficiencyWindowDays': 7,
    'efficiencyTripCount': 2,
    'efficiencyDistanceKm': 24.7,
    'efficiencyNetEnergyKwh': 3.44,
    'efficiencyUpdatedAtUtcMillis': 0,
    'fullRangeKm': ownRangeKm == null ? null : capacityKwh * efficiencyKmPerKwh,
    'ownRangeKm': ownRangeKm,
    'ownRangeQuality': ownRangeKm == null ? 'UNAVAILABLE' : ownQuality,
    'ownRangeReason': ownReason.isEmpty ? null : ownReason,
  });
}

/// Stands in for the three process-wide controllers the screen already runs.
///
/// The controller under test reads through closures and advances on one
/// [Listenable]; this holds the values those closures return and fires it.
class _Sources extends ChangeNotifier {
  RangeEstimate? estimate;
  double? odometerKm;
  String? activeSessionId;
  DateTime clock = DateTime(2026, 8, 26, 14, 32);

  RangeDropController attach() => RangeDropController(
    source: this,
    readEstimate: () => estimate,
    readOdometerKm: () => odometerKm,
    readActiveSessionId: () => activeSessionId,
    clock: () => clock,
  );

  /// One tick of the polls, with whatever fields the case changes.
  void tick({
    RangeEstimate? estimate,
    double? odometerKm,
    String? activeSessionId = _unchanged,
    Duration elapsed = const Duration(seconds: 2),
  }) {
    if (estimate != null) this.estimate = estimate;
    if (odometerKm != null) this.odometerKm = odometerKm;
    if (!identical(activeSessionId, _unchanged)) {
      this.activeSessionId = activeSessionId;
    }
    clock = clock.add(elapsed);
    notifyListeners();
  }

  static const _unchanged = '__unchanged__';
}

/// A tick that clears a field a null argument cannot reach through [tick].
void _clearEstimate(_Sources sources) {
  sources.estimate = null;
  sources.notifyListeners();
}

void main() {
  group('RangeDropController', () {
    test('reports distance and both drops over a measured stretch', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 226, ownRangeKm: 174),
        odometerKm: 12825,
      );

      final state = controller.state;
      expect(state.hasBaseline, isTrue);
      expect(state.distanceKm, closeTo(25, 0.001));
      expect(state.car.km, closeTo(40, 0.001));
      expect(state.app.km, closeTo(26, 0.001));
      expect(state.frozen, isFalse);
    });

    test('takes no baseline until every input is usable', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      // In a trip, but the odometer has not arrived yet.
      sources.tick(estimate: _estimate(), activeSessionId: 'trip-1');
      expect(controller.state.hasBaseline, isFalse);

      // Odometer present, but the car range is unavailable.
      sources.tick(estimate: _estimate(carRangeKm: null), odometerKm: 12800);
      expect(controller.state.hasBaseline, isFalse);

      sources.tick(estimate: _estimate(carRangeKm: 266), odometerKm: 12800);
      expect(controller.state.hasBaseline, isTrue);
      expect(controller.state.baselineAt, DateTime(2026, 8, 26, 14, 32, 6));
    });

    test('measures from the observation point when it joins mid-trip', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      // The trip has been running for a while; the app only starts here.
      sources.tick(
        estimate: _estimate(carRangeKm: 200, ownRangeKm: 150),
        odometerKm: 12900,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 180, ownRangeKm: 137),
        odometerKm: 12912,
      );

      final state = controller.state;
      expect(state.baselineAt, DateTime(2026, 8, 26, 14, 32, 2));
      expect(state.distanceKm, closeTo(12, 0.001));
      expect(state.car.km, closeTo(20, 0.001));
      expect(state.app.km, closeTo(13, 0.001));
    });

    test('a new trip discards the previous baseline', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 226, ownRangeKm: 174),
        odometerKm: 12825,
      );
      sources.tick(activeSessionId: null);
      sources.tick(
        estimate: _estimate(carRangeKm: 226, ownRangeKm: 174),
        odometerKm: 12825,
        activeSessionId: 'trip-2',
      );

      expect(controller.state.distanceKm, 0);
      expect(controller.state.car.km, 0);
      expect(controller.state.frozen, isFalse);

      sources.tick(
        estimate: _estimate(carRangeKm: 216, ownRangeKm: 165),
        odometerKm: 12834,
      );
      expect(controller.state.distanceKm, closeTo(9, 0.001));
      expect(controller.state.car.km, closeTo(10, 0.001));
    });

    test('recovered range is a negative drop, not a clamp to zero', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 200, ownRangeKm: 150),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 203, ownRangeKm: 151),
        odometerKm: 12802,
      );

      expect(controller.state.car.km, closeTo(-3, 0.001));
      expect(controller.state.app.km, closeTo(-1, 0.001));
    });

    test('an unavailable car range leaves the app line reporting', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(
          carRangeKm: null,
          ownRangeKm: 174,
          carReason: 'SIGNAL_ERROR',
        ),
        odometerKm: 12825,
      );

      final state = controller.state;
      expect(state.car.isAvailable, isFalse);
      expect(state.car.km, isNull);
      expect(state.car.reason, 'SIGNAL_ERROR');
      expect(state.app.km, closeTo(26, 0.001));
    });

    test('an unavailable app range leaves the car line reporting', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(
          carRangeKm: 226,
          ownRangeKm: null,
          ownReason: 'EFFICIENCY_REFRESH_FAILED',
        ),
        odometerKm: 12825,
      );

      final state = controller.state;
      expect(state.app.isAvailable, isFalse);
      expect(state.app.km, isNull);
      expect(state.app.reason, 'EFFICIENCY_REFRESH_FAILED');
      expect(state.car.km, closeTo(40, 0.001));
    });

    test('an unavailable reading does not destroy the baseline', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      _clearEstimate(sources);
      expect(controller.state.hasBaseline, isTrue);
      expect(controller.state.car.km, isNull);

      sources.tick(
        estimate: _estimate(carRangeKm: 226, ownRangeKm: 174),
        odometerKm: 12825,
      );
      expect(controller.state.car.km, closeTo(40, 0.001));
      expect(controller.state.baselineAt, DateTime(2026, 8, 26, 14, 32, 2));
    });

    test('a stretch below the floor reports nothing, then clears it', () {
      final sources = _Sources();
      final controller = RangeDropController(
        source: sources,
        readEstimate: () => sources.estimate,
        readOdometerKm: () => sources.odometerKm,
        readActiveSessionId: () => sources.activeSessionId,
        clock: () => sources.clock,
        floorKm: 10,
      );
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 260, ownRangeKm: 196),
        odometerKm: 12804,
      );
      expect(controller.state.floorCleared, isFalse);

      sources.tick(
        estimate: _estimate(carRangeKm: 254, ownRangeKm: 192),
        odometerKm: 12808,
      );
      expect(controller.state.floorCleared, isTrue);
      expect(controller.state.car.km, closeTo(12, 0.001));
    });

    test('the default floor lets every stretch report', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );

      expect(kRangeDropFloorKm, 0);
      expect(controller.state.floorCleared, isTrue);
    });

    test('leaving the trip freezes the last stretch', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 226, ownRangeKm: 174),
        odometerKm: 12825,
      );
      sources.tick(activeSessionId: null);

      expect(controller.state.frozen, isTrue);
      expect(controller.state.distanceKm, closeTo(25, 0.001));
      expect(controller.state.car.km, closeTo(40, 0.001));

      // The car keeps reporting while parked; the frozen figures do not move.
      sources.tick(
        estimate: _estimate(carRangeKm: 230, ownRangeKm: 176),
        odometerKm: 12825,
      );
      expect(controller.state.car.km, closeTo(40, 0.001));
    });

    test('a degraded app estimate still measures, and says it is degraded', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(
          carRangeKm: 226,
          ownRangeKm: 174,
          ownQuality: 'DEGRADED',
          ownReason: 'EFFICIENCY_REFRESH_FAILED',
        ),
        odometerKm: 12825,
      );

      final state = controller.state;
      expect(state.app.km, closeTo(26, 0.001));
      expect(state.app.reason, 'EFFICIENCY_REFRESH_FAILED');
      expect(state.car.reason, isNull);
    });

    test('a dropped odometer holds the distance rather than collapsing it', () {
      final sources = _Sources();
      final controller = sources.attach();
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 226, ownRangeKm: 174),
        odometerKm: 12825,
      );
      sources.odometerKm = null;
      sources.notifyListeners();

      expect(controller.state.distanceKm, closeTo(25, 0.001));
    });

    test('a dropped car line keeps the floor where it was', () {
      final sources = _Sources();
      final controller = RangeDropController(
        source: sources,
        readEstimate: () => sources.estimate,
        readOdometerKm: () => sources.odometerKm,
        readActiveSessionId: () => sources.activeSessionId,
        clock: () => sources.clock,
        floorKm: 10,
      );
      addTearDown(controller.dispose);

      sources.tick(
        estimate: _estimate(carRangeKm: 266, ownRangeKm: 200),
        odometerKm: 12800,
        activeSessionId: 'trip-1',
      );
      sources.tick(
        estimate: _estimate(carRangeKm: 254, ownRangeKm: 192),
        odometerKm: 12808,
      );
      expect(controller.state.floorCleared, isTrue);

      sources.tick(
        estimate: _estimate(carRangeKm: null, ownRangeKm: 190),
        odometerKm: 12810,
      );
      expect(controller.state.floorCleared, isTrue);
      expect(controller.state.car.km, isNull);
    });
  });
}
