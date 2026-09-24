import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('SessionKind', () {
    test('parses names case-insensitively', () {
      expect(SessionKind.fromName('trip'), SessionKind.trip);
      expect(SessionKind.fromName('TRIP'), SessionKind.trip);
      expect(SessionKind.fromName('charge'), SessionKind.charge);
      expect(SessionKind.fromName('CHARGE'), SessionKind.charge);
      expect(SessionKind.fromName('parked'), SessionKind.parked);
      expect(SessionKind.fromName('PARKED'), SessionKind.parked);
      expect(SessionKind.fromName('UNKNOWN'), SessionKind.trip);
    });
  });

  group('SessionRollup', () {
    test('computes netPackEnergy correctly with measured values', () {
      const rollup = SessionRollup(
        distance: Measurement.measured(15.5, unit: 'km'),
        traction: Measurement.measured(2500, unit: 'Wh'),
        regen: Measurement.measured(500, unit: 'Wh'),
        auxiliary: Measurement.measured(200, unit: 'Wh'),
        climate: Measurement.measured(100, unit: 'Wh'),
        delivered: Measurement.measured(0, unit: 'Wh'),
        integratedSeconds: Measurement.measured(1200, unit: 's'),
      );

      final net = rollup.netPackEnergy;
      expect(net.isMeasured, isTrue);
      expect(net.value, 2200); // 2500 - 500 + 200
      expect(net.unit, 'Wh');
    });

    test('propagates estimated validity to netPackEnergy', () {
      const rollup = SessionRollup(
        distance: Measurement.measured(10.0, unit: 'km'),
        traction: Measurement.estimated(
          2000,
          unit: 'Wh',
          note: 'assumed scale',
        ),
        regen: Measurement.measured(400, unit: 'Wh'),
        auxiliary: Measurement.measured(100, unit: 'Wh'),
        climate: Measurement.measured(50, unit: 'Wh'),
        delivered: Measurement.measured(0, unit: 'Wh'),
        integratedSeconds: Measurement.measured(600, unit: 's'),
      );

      final net = rollup.netPackEnergy;
      expect(net.validity, MeasurementValidity.estimated);
      expect(net.value, 1700);
      expect(net.note, 'assumed scale');
    });

    test('propagates invalid validity to netPackEnergy', () {
      const rollup = SessionRollup(
        distance: Measurement.measured(10.0, unit: 'km'),
        traction: Measurement.invalid(unit: 'Wh', note: 'bus error'),
        regen: Measurement.measured(400, unit: 'Wh'),
        auxiliary: Measurement.measured(100, unit: 'Wh'),
        climate: Measurement.measured(50, unit: 'Wh'),
        delivered: Measurement.measured(0, unit: 'Wh'),
        integratedSeconds: Measurement.measured(600, unit: 's'),
      );

      final net = rollup.netPackEnergy;
      expect(net.validity, MeasurementValidity.invalid);
      expect(net.value, isNull);
      expect(net.note, 'bus error');
    });
  });

  group('SessionRecord', () {
    test('creates with all required measurements', () {
      const session = SessionRecord(
        id: 'session-123',
        vehicleId: 'VIN123',
        kind: SessionKind.trip,
        status: 'CLOSED',
        startedAtUtcMillis: 1000000,
        startedAtElapsedNanos: 500000,
        endedAtUtcMillis: 1060000,
        endedAtElapsedNanos: 560000,
        durationMillis: 60000,
        rollup: SessionRollup(
          distance: Measurement.measured(2.5, unit: 'km'),
          traction: Measurement.measured(500, unit: 'Wh'),
          regen: Measurement.measured(100, unit: 'Wh'),
          auxiliary: Measurement.measured(50, unit: 'Wh'),
          climate: Measurement.measured(25, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          integratedSeconds: Measurement.measured(60, unit: 's'),
        ),
        startOdometer: Measurement.measured(10000.0, unit: 'km'),
        endOdometer: Measurement.measured(10002.5, unit: 'km'),
        startSoc: Measurement.measured(80.0, unit: '%'),
        endSoc: Measurement.measured(79.0, unit: '%'),
        minSoc: Measurement.measured(79.0, unit: '%'),
        maxSoc: Measurement.measured(80.0, unit: '%'),
        socAgreesWithIntegral: 'agrees',
        startAmbientTemp: Measurement.measured(22.0, unit: '°C'),
        endAmbientTemp: Measurement.measured(23.0, unit: '°C'),
        meanAmbientTemp: Measurement.measured(22.5, unit: '°C'),
        createdAtUtcMillis: 1000000,
        updatedAtUtcMillis: 1060000,
      );

      expect(session.id, 'session-123');
      expect(session.kind, SessionKind.trip);
      expect(session.rollup.distance.value, 2.5);
      expect(session.startSoc.value, 80.0);
      expect(session.socAgreesWithIntegral, 'agrees');
    });
  });

  group('reduceIntervalRecords', () {
    test('returns original list when empty or width is 1 minute', () {
      expect(reduceIntervalRecords([], widthMillis: 60000), isEmpty);
      expect(reduceIntervalRecords([], widthMillis: 120000), isEmpty);

      final single = [
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 60000,
          widthMillis: 60000,
          traction: Measurement.measured(100, unit: 'Wh'),
          regen: Measurement.measured(20, unit: 'Wh'),
          auxiliary: Measurement.measured(10, unit: 'Wh'),
          climate: Measurement.measured(5, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(1.0, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 60,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
        ),
      ];

      expect(reduceIntervalRecords(single, widthMillis: 60000), single);
    });

    test('reduces 1-minute intervals into 2-minute buckets correctly', () {
      final intervals = [
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 0,
          widthMillis: 60000,
          traction: Measurement.measured(100, unit: 'Wh'),
          regen: Measurement.measured(20, unit: 'Wh'),
          auxiliary: Measurement.measured(10, unit: 'Wh'),
          climate: Measurement.measured(5, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(0.8, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 60,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
        ),
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 60000,
          widthMillis: 60000,
          traction: Measurement.measured(150, unit: 'Wh'),
          regen: Measurement.measured(30, unit: 'Wh'),
          auxiliary: Measurement.measured(15, unit: 'Wh'),
          climate: Measurement.measured(8, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(1.2, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 60,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
        ),
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 120000,
          widthMillis: 60000,
          traction: Measurement.measured(200, unit: 'Wh'),
          regen: Measurement.measured(40, unit: 'Wh'),
          auxiliary: Measurement.measured(20, unit: 'Wh'),
          climate: Measurement.measured(10, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(1.5, unit: 'km'),
          coveredSeconds: 50,
          climateCoveredSeconds: 50,
          speedCoveredSeconds: 50,
          deliveredCoveredSeconds: 0,
        ),
      ];

      final reduced = reduceIntervalRecords(intervals, widthMillis: 120000);
      expect(reduced.length, 2);

      // Bucket 0 (0 to 120000)
      expect(reduced[0].startUtcMillis, 0);
      expect(reduced[0].widthMillis, 120000);
      expect(reduced[0].traction.value, 250); // 100 + 150
      expect(reduced[0].regen.value, 50); // 20 + 30
      expect(reduced[0].auxiliary.value, 25); // 10 + 15
      expect(reduced[0].climate.value, 13); // 5 + 8
      expect(reduced[0].distance.value, 2.0); // 0.8 + 1.2
      expect(reduced[0].coveredSeconds, 120);

      // Bucket 1 (120000 to 240000)
      expect(reduced[1].startUtcMillis, 120000);
      expect(reduced[1].widthMillis, 120000);
      expect(reduced[1].traction.value, 200);
      expect(reduced[1].regen.value, 40);
      expect(reduced[1].auxiliary.value, 20);
      expect(reduced[1].climate.value, 10);
      expect(reduced[1].distance.value, 1.5);
      expect(reduced[1].coveredSeconds, 50);
    });

    test('preserves weaker validity when combining intervals', () {
      final intervals = [
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 0,
          widthMillis: 60000,
          traction: Measurement.measured(100, unit: 'Wh'),
          regen: Measurement.measured(20, unit: 'Wh'),
          auxiliary: Measurement.measured(10, unit: 'Wh'),
          climate: Measurement.measured(5, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(0.8, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 60,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
        ),
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 60000,
          widthMillis: 60000,
          traction: Measurement.estimated(
            150,
            unit: 'Wh',
            note: 'extrapolated',
          ),
          regen: Measurement.measured(30, unit: 'Wh'),
          auxiliary: Measurement.measured(15, unit: 'Wh'),
          climate: Measurement.measured(8, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(1.2, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 60,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
        ),
      ];

      final reduced = reduceIntervalRecords(intervals, widthMillis: 120000);
      expect(reduced.length, 1);
      expect(reduced[0].traction.validity, MeasurementValidity.estimated);
      expect(reduced[0].traction.value, 250);
      expect(reduced[0].traction.note, 'extrapolated');
      expect(reduced[0].regen.validity, MeasurementValidity.measured);
    });

    test(
      'preserves startSoc and endSoc boundary readings when reducing intervals',
      () {
        final intervals = [
          const IntervalRecord(
            sessionId: 's1',
            startUtcMillis: 0,
            widthMillis: 60000,
            traction: Measurement.measured(100, unit: 'Wh'),
            regen: Measurement.measured(20, unit: 'Wh'),
            auxiliary: Measurement.measured(10, unit: 'Wh'),
            climate: Measurement.measured(5, unit: 'Wh'),
            delivered: Measurement.measured(0, unit: 'Wh'),
            distance: Measurement.measured(0.8, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 60,
            speedCoveredSeconds: 60,
            deliveredCoveredSeconds: 0,
            startSoc: Measurement.measured(80.0, unit: '%'),
            endSoc: Measurement.measured(79.5, unit: '%'),
          ),
          const IntervalRecord(
            sessionId: 's1',
            startUtcMillis: 60000,
            widthMillis: 60000,
            traction: Measurement.measured(150, unit: 'Wh'),
            regen: Measurement.measured(30, unit: 'Wh'),
            auxiliary: Measurement.measured(15, unit: 'Wh'),
            climate: Measurement.measured(8, unit: 'Wh'),
            delivered: Measurement.measured(0, unit: 'Wh'),
            distance: Measurement.measured(1.2, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 60,
            speedCoveredSeconds: 60,
            deliveredCoveredSeconds: 0,
            startSoc: Measurement.measured(79.5, unit: '%'),
            endSoc: Measurement.measured(79.0, unit: '%'),
          ),
        ];

        final reduced = reduceIntervalRecords(intervals, widthMillis: 120000);
        expect(reduced.length, 1);
        expect(reduced[0].startSoc.isMeasured, isTrue);
        expect(reduced[0].startSoc.value, 80.0);
        expect(reduced[0].endSoc.isMeasured, isTrue);
        expect(reduced[0].endSoc.value, 79.0);
      },
    );

    test(
      'preserves unreported startSoc and endSoc when no interval reports SOC',
      () {
        final intervals = [
          const IntervalRecord(
            sessionId: 's1',
            startUtcMillis: 0,
            widthMillis: 60000,
            traction: Measurement.measured(100, unit: 'Wh'),
            regen: Measurement.measured(20, unit: 'Wh'),
            auxiliary: Measurement.measured(10, unit: 'Wh'),
            climate: Measurement.measured(5, unit: 'Wh'),
            delivered: Measurement.measured(0, unit: 'Wh'),
            distance: Measurement.measured(0.8, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 60,
            speedCoveredSeconds: 60,
            deliveredCoveredSeconds: 0,
          ),
          const IntervalRecord(
            sessionId: 's1',
            startUtcMillis: 60000,
            widthMillis: 60000,
            traction: Measurement.measured(150, unit: 'Wh'),
            regen: Measurement.measured(30, unit: 'Wh'),
            auxiliary: Measurement.measured(15, unit: 'Wh'),
            climate: Measurement.measured(8, unit: 'Wh'),
            delivered: Measurement.measured(0, unit: 'Wh'),
            distance: Measurement.measured(1.2, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 60,
            speedCoveredSeconds: 60,
            deliveredCoveredSeconds: 0,
          ),
        ];

        final reduced = reduceIntervalRecords(intervals, widthMillis: 120000);
        expect(reduced.length, 1);
        expect(reduced[0].startSoc.hasValue, isFalse);
        expect(reduced[0].endSoc.hasValue, isFalse);
      },
    );

    test('handles partially reported startSoc and endSoc in reduced group', () {
      final intervals = [
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 0,
          widthMillis: 60000,
          traction: Measurement.measured(100, unit: 'Wh'),
          regen: Measurement.measured(20, unit: 'Wh'),
          auxiliary: Measurement.measured(10, unit: 'Wh'),
          climate: Measurement.measured(5, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(0.8, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 60,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
          startSoc: Measurement.unreported(unit: '%'),
          endSoc: Measurement.unreported(unit: '%'),
        ),
        const IntervalRecord(
          sessionId: 's1',
          startUtcMillis: 60000,
          widthMillis: 60000,
          traction: Measurement.measured(150, unit: 'Wh'),
          regen: Measurement.measured(30, unit: 'Wh'),
          auxiliary: Measurement.measured(15, unit: 'Wh'),
          climate: Measurement.measured(8, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          distance: Measurement.measured(1.2, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 60,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
          startSoc: Measurement.measured(75.0, unit: '%'),
          endSoc: Measurement.measured(74.2, unit: '%'),
        ),
      ];

      final reduced = reduceIntervalRecords(intervals, widthMillis: 120000);
      expect(reduced.length, 1);
      expect(reduced[0].startSoc.isMeasured, isTrue);
      expect(reduced[0].startSoc.value, 75.0);
      expect(reduced[0].endSoc.isMeasured, isTrue);
      expect(reduced[0].endSoc.value, 74.2);
    });

    test(
      'preserves startVoltage from first and endVoltage from last reporting interval',
      () {
        final intervals = [
          const IntervalRecord(
            sessionId: 's1',
            startUtcMillis: 0,
            widthMillis: 60000,
            traction: Measurement.measured(100, unit: 'Wh'),
            regen: Measurement.measured(20, unit: 'Wh'),
            auxiliary: Measurement.measured(10, unit: 'Wh'),
            climate: Measurement.measured(5, unit: 'Wh'),
            delivered: Measurement.measured(0, unit: 'Wh'),
            distance: Measurement.measured(0.8, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 60,
            speedCoveredSeconds: 60,
            deliveredCoveredSeconds: 0,
            startVoltage: Measurement.measured(380.0, unit: 'V'),
            endVoltage: Measurement.measured(382.0, unit: 'V'),
          ),
          const IntervalRecord(
            sessionId: 's1',
            startUtcMillis: 60000,
            widthMillis: 60000,
            traction: Measurement.measured(150, unit: 'Wh'),
            regen: Measurement.measured(30, unit: 'Wh'),
            auxiliary: Measurement.measured(15, unit: 'Wh'),
            climate: Measurement.measured(8, unit: 'Wh'),
            delivered: Measurement.measured(0, unit: 'Wh'),
            distance: Measurement.measured(1.2, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 60,
            speedCoveredSeconds: 60,
            deliveredCoveredSeconds: 0,
            startVoltage: Measurement.measured(382.0, unit: 'V'),
            endVoltage: Measurement.measured(385.5, unit: 'V'),
          ),
        ];

        final reduced = reduceIntervalRecords(intervals, widthMillis: 120000);
        expect(reduced.length, 1);
        expect(reduced[0].startVoltage.isMeasured, isTrue);
        expect(reduced[0].startVoltage.value, 380.0);
        expect(reduced[0].endVoltage.isMeasured, isTrue);
        expect(reduced[0].endVoltage.value, 385.5);
      },
    );
  });

  group('reduceIntervalRecordsByIndex', () {
    IntervalRecord minute({
      required int startUtcMillis,
      double tractionWh = 100,
    }) => IntervalRecord(
      sessionId: 's1',
      startUtcMillis: startUtcMillis,
      widthMillis: 60000,
      traction: Measurement.measured(tractionWh, unit: 'Wh'),
      regen: Measurement.measured(0, unit: 'Wh'),
      auxiliary: Measurement.measured(0, unit: 'Wh'),
      climate: Measurement.measured(0, unit: 'Wh'),
      delivered: Measurement.measured(0, unit: 'Wh'),
      distance: Measurement.measured(0, unit: 'km'),
      coveredSeconds: 60,
      climateCoveredSeconds: 60,
      speedCoveredSeconds: 60,
      deliveredCoveredSeconds: 0,
    );

    test(
      'one bogus stamp does not widen the reduced session (fixture: real car)',
      () {
        // A nine-minute drive where one minute was stamped from a boot-default
        // clock years away. The recorded widths are all the minute.
        const sessionStart = 1780000000000;
        final intervals = [
          for (var i = 0; i < 9; i++)
            minute(
              startUtcMillis: i == 8
                  ? 1753168080000 // 2025-05-23 22:08:00 UTC boot default
                  : sessionStart + i * 60000,
              tractionWh: 100.0,
            ),
        ];

        final reduced = reduceIntervalRecordsByIndex(
          intervals,
          widthMillis: 60000,
          positionOf: (interval) =>
              indexOfIntervalPosition(intervals.indexOf(interval), interval),
        );

        // Nine minutes, nine bars — the energy chart must render nine minutes,
        // not the 22000 hours the stamp difference would claim.
        expect(reduced, hasLength(9));
        // And the total energy is preserved exactly through the reduction.
        final drawnBefore = intervals.fold<double>(
          0,
          (sum, inv) => sum + (inv.traction.displayValue ?? 0),
        );
        final drawnAfter = reduced.fold<double>(
          0,
          (sum, inv) => sum + (inv.traction.displayValue ?? 0),
        );
        expect(drawnAfter, closeTo(drawnBefore, 1e-9));
        final coveredBefore = intervals.fold<double>(
          0,
          (sum, inv) => sum + inv.coveredSeconds,
        );
        final coveredAfter = reduced.fold<double>(
          0,
          (sum, inv) => sum + inv.coveredSeconds,
        );
        expect(coveredAfter, closeTo(coveredBefore, 1e-9));
        expect(coveredAfter, closeTo(9 * 60, 1e-9));
      },
    );
  });
  group('monotonicIntervalPosition (time authority T7)', () {
    IntervalRecord pendingMinute({
      required int elapsedNanos,
      required double tractionWh,
      required int startUtcMillis,
      int? bootCount,
      String timeState = 'pending',
    }) => IntervalRecord(
      sessionId: 's1',
      startUtcMillis: startUtcMillis,
      widthMillis: 60000,
      traction: Measurement.measured(tractionWh, unit: 'Wh'),
      regen: Measurement.measured(0, unit: 'Wh'),
      auxiliary: Measurement.measured(0, unit: 'Wh'),
      climate: Measurement.measured(0, unit: 'Wh'),
      delivered: Measurement.measured(0, unit: 'Wh'),
      distance: Measurement.measured(0, unit: 'km'),
      coveredSeconds: 60,
      climateCoveredSeconds: 0,
      speedCoveredSeconds: 0,
      deliveredCoveredSeconds: 0,
      startElapsedNanos: elapsedNanos,
      startBootCount: bootCount ?? 7,
      timeState: timeState,
    );

    test(
      'a pending session positions by the monotonic pair, never the stamp',
      () {
        // Three minutes of one boot, stamps out of order: the boot-default
        // clock stamped the middle minute first. The list arrives in stamp
        // order, as the DAO returns it.
        const minuteNanos = 60000000000;
        final intervals = [
          pendingMinute(
            elapsedNanos: 2 * minuteNanos,
            tractionWh: 300,
            startUtcMillis: 1000000,
          ),
          pendingMinute(
            elapsedNanos: 0,
            tractionWh: 100,
            startUtcMillis: 2000000,
          ),
          pendingMinute(
            elapsedNanos: minuteNanos,
            tractionWh: 200,
            startUtcMillis: 3000000,
          ),
        ];

        final positionOf = intervalPositionOf(intervals);
        final reduced = reduceIntervalRecordsByIndex(
          intervals,
          widthMillis: 120000,
          positionOf: positionOf,
        );

        // The first two elapsed minutes share bucket 0: 100 + 200 Wh.
        // The ordinal basis would bucket the stamp order instead (300 + 100).
        expect(reduced, hasLength(2));
        expect(reduced[0].traction.value, 300.0);
        expect(reduced[1].traction.value, 300.0);

        final reduced3Min = reduceIntervalRecordsByIndex(
          intervals,
          widthMillis: 180000,
          positionOf: positionOf,
        );
        // 3 minutes of driving reduced to a 3-minute bucket must produce
        // exactly 1 bucket starting at 0, not 2 buckets with a negative start.
        expect(reduced3Min, hasLength(1));
        expect(reduced3Min[0].startUtcMillis, 0);
        expect(reduced3Min[0].traction.value, 600.0);
      },
    );
    test('a trusted series with the pair positions exactly as today', () {
      // The pair is present but the clock is trusted: the bars must not
      // move a millimeter. The session starts mid-minute, so the monotonic
      // grid (0, 0, 60000) differs from the ordinal one (0, 60000, 120000)
      // — dropping the pending gate fails this test.
      const minuteNanos = 60000000000;
      final intervals = [
        pendingMinute(
          elapsedNanos: 0,
          tractionWh: 100,
          startUtcMillis: 1780000000000,
          timeState: 'known',
        ),
        pendingMinute(
          elapsedNanos: minuteNanos ~/ 2,
          tractionWh: 200,
          startUtcMillis: 1780000060000,
          timeState: 'known',
        ),
        pendingMinute(
          elapsedNanos: minuteNanos + minuteNanos ~/ 2,
          tractionWh: 300,
          startUtcMillis: 1780000120000,
          timeState: 'known',
        ),
      ];

      final positionOf = intervalPositionOf(intervals);
      expect(positionOf(intervals[0]), 0);
      expect(positionOf(intervals[1]), 60000);
      expect(positionOf(intervals[2]), 120000);
    });

    test('a pending series without the pair falls back to the ordinal', () {
      // Every row written before T2 has no pair: the chart must still draw
      // the whole history, in today's slots, without throwing.
      IntervalRecord strip(IntervalRecord interval) => IntervalRecord(
        sessionId: interval.sessionId,
        startUtcMillis: interval.startUtcMillis,
        widthMillis: interval.widthMillis,
        traction: interval.traction,
        regen: interval.regen,
        auxiliary: interval.auxiliary,
        climate: interval.climate,
        delivered: interval.delivered,
        distance: interval.distance,
        coveredSeconds: interval.coveredSeconds,
        climateCoveredSeconds: interval.climateCoveredSeconds,
        speedCoveredSeconds: interval.speedCoveredSeconds,
        deliveredCoveredSeconds: interval.deliveredCoveredSeconds,
        timeState: 'pending',
      );
      final stripped = [
        strip(
          pendingMinute(
            elapsedNanos: 0,
            tractionWh: 100,
            startUtcMillis: 1780000000000,
          ),
        ),
        strip(
          pendingMinute(
            elapsedNanos: 60000000000,
            tractionWh: 200,
            startUtcMillis: 1780000060000,
          ),
        ),
      ];
      expect(stripped[0].startElapsedNanos, isNull);
      expect(stripped[1].startBootCount, isNull);

      final positionOf = intervalPositionOf(stripped);
      expect(positionOf(stripped[0]), 0);
      expect(positionOf(stripped[1]), 60000);
      final reduced = reduceIntervalRecordsByIndex(
        stripped,
        widthMillis: 120000,
        positionOf: positionOf,
      );
      expect(reduced, hasLength(1));
      expect(reduced[0].traction.value, 300.0);
    });

    test(
      'a pending series with mixed pairs falls back to ordinal, never colliding',
      () {
        final mixed = [
          IntervalRecord(
            sessionId: 's1',
            startUtcMillis: 1000000,
            widthMillis: 60000,
            traction: const Measurement.measured(100, unit: 'Wh'),
            regen: const Measurement.measured(0, unit: 'Wh'),
            auxiliary: const Measurement.measured(0, unit: 'Wh'),
            climate: const Measurement.measured(0, unit: 'Wh'),
            delivered: const Measurement.measured(0, unit: 'Wh'),
            distance: const Measurement.measured(0, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 0,
            speedCoveredSeconds: 0,
            deliveredCoveredSeconds: 0,
            timeState: 'pending',
            // pair absent
          ),
          pendingMinute(
            elapsedNanos: 0,
            tractionWh: 200,
            startUtcMillis: 2000000,
          ),
        ];

        final positionOf = intervalPositionOf(mixed);
        // The absent-pair row must not collide at slot 0 with the elapsed-0 row.
        // The whole series must fall back to ordinal: 0 and 60000.
        expect(positionOf(mixed[0]), 0);
        expect(positionOf(mixed[1]), 60000);
        expect(positionOf(mixed[0]), isNot(equals(positionOf(mixed[1]))));
      },
    );

    test('a reboot inside the session falls back to the ordinal, never absurd', () {
      // Elapsed restarts at every boot: the second boot's small counter
      // minus the first boot's anchor is not a span. The whole series
      // falls back, so no bar lands on a negative or hour-wide slot.
      const minuteNanos = 60000000000;
      final intervals = [
        pendingMinute(
          elapsedNanos: minuteNanos,
          tractionWh: 200,
          startUtcMillis: 1000000,
          bootCount: 7,
        ),
        pendingMinute(
          elapsedNanos: 0,
          tractionWh: 100,
          startUtcMillis: 2000000,
          bootCount: 7,
        ),
        pendingMinute(
          elapsedNanos: 5000000000,
          tractionWh: 300,
          startUtcMillis: 3000000,
          bootCount: 8,
        ),
      ];

      final positionOf = intervalPositionOf(intervals);
      // The entire series must fall back to ordinal (index order 0, 60000, 120000).
      // If boot 7 was erroneously placed monotonically, intervals[0] would be 60000.
      expect(positionOf(intervals[0]), 0);
      expect(positionOf(intervals[1]), 60000);
      expect(positionOf(intervals[2]), 120000);
    });

    test('years-old stamps never take part in a pending position', () {
      // The boot-default band (2025) and a forward jump (2027) in one
      // session. The list arrives sorted by startUtcMillis (stamp order):
      // minute 1 (2025) is index 0, minute 2 (2025) is index 1,
      // but minute 0 (2027 jump) is index 2.
      // Positions must come from elapsed realtime alone, placing minute 0 at 0ms.
      const minuteNanos = 60000000000;
      final ancient = [
        pendingMinute(
          elapsedNanos: minuteNanos,
          tractionWh: 200.0,
          startUtcMillis: 1753168080000, // 2025-05-23 boot default (minute 1)
        ),
        pendingMinute(
          elapsedNanos: 2 * minuteNanos,
          tractionWh: 300.0,
          startUtcMillis: 1753168140000, // minute 2
        ),
        pendingMinute(
          elapsedNanos: 0,
          tractionWh: 100.0,
          startUtcMillis: 1799999999999, // 2027 forward jump (minute 0)
        ),
      ];

      final ancientOf = intervalPositionOf(ancient);
      // Monotonic positions must place by elapsed, not by stamp order:
      expect(ancientOf(ancient[0]), 60000); // minute 1 -> 60s
      expect(ancientOf(ancient[1]), 120000); // minute 2 -> 120s
      expect(ancientOf(ancient[2]), 0); // minute 0 -> 0s
    });

    test(
      'normal case (trusted clock) positions identically to pre-PR behavior across reduction',
      () {
        // PROVE NO REGRESSION: A 10-minute trusted session with real variation
        // must reduce to exact byte-identical intervals as the pre-PR baseline.
        final intervals = [
          for (var i = 0; i < 10; i++)
            IntervalRecord(
              sessionId: 'normal-session',
              startUtcMillis: 1780000000000 + i * 60000,
              widthMillis: 60000,
              traction: Measurement.measured(100.0 + i * 10, unit: 'Wh'),
              regen: Measurement.measured(i * 5.0, unit: 'Wh'),
              auxiliary: Measurement.measured(10.0, unit: 'Wh'),
              climate: Measurement.measured(5.0, unit: 'Wh'),
              delivered: Measurement.measured(0.0, unit: 'Wh'),
              distance: Measurement.measured(1.0 + i * 0.1, unit: 'km'),
              coveredSeconds: 60,
              climateCoveredSeconds: 60,
              speedCoveredSeconds: 60,
              deliveredCoveredSeconds: 0,
              startSoc: Measurement.measured(80.0 - i * 0.5, unit: '%'),
              endSoc: Measurement.measured(79.5 - i * 0.5, unit: '%'),
              startVoltage: Measurement.measured(380.0 - i * 0.5, unit: 'V'),
              endVoltage: Measurement.measured(379.5 - i * 0.5, unit: 'V'),
              startElapsedNanos: i * 60000000000,
              startBootCount: 1,
              timeState: 'known',
            ),
        ];

        for (final width in [120000, 180000, 300000]) {
          final prePR = reduceIntervalRecordsByIndex(
            intervals,
            widthMillis: width,
            positionOf: (interval) =>
                indexOfIntervalPosition(intervals.indexOf(interval), interval),
          );
          final postPR = reduceIntervalRecordsByIndex(
            intervals,
            widthMillis: width,
            positionOf: intervalPositionOf(intervals),
          );

          expect(postPR.length, prePR.length);
          for (var i = 0; i < prePR.length; i++) {
            expect(postPR[i].startUtcMillis, prePR[i].startUtcMillis);
            expect(postPR[i].widthMillis, prePR[i].widthMillis);
            expect(postPR[i].traction.value, prePR[i].traction.value);
            expect(postPR[i].regen.value, prePR[i].regen.value);
            expect(postPR[i].distance.value, prePR[i].distance.value);
            expect(postPR[i].startSoc.value, prePR[i].startSoc.value);
            expect(postPR[i].endSoc.value, prePR[i].endSoc.value);
            expect(postPR[i].startVoltage.value, prePR[i].startVoltage.value);
            expect(postPR[i].endVoltage.value, prePR[i].endVoltage.value);
          }
        }
      },
    );

    test('corrupt negative startElapsedNanos falls back to ordinal', () {
      final intervals = [
        pendingMinute(
          elapsedNanos: -1000,
          tractionWh: 100,
          startUtcMillis: 1000000,
        ),
        pendingMinute(
          elapsedNanos: 60000000000,
          tractionWh: 200,
          startUtcMillis: 2000000,
        ),
      ];
      final positionOf = intervalPositionOf(intervals);
      expect(positionOf(intervals[0]), 0);
      expect(positionOf(intervals[1]), 60000);
    });

    test(
      'historical session with 55 intervals from 2025 to 2027 without pair reduces safely by ordinal',
      () {
        // Mirroring the captain's real database with 16,142 intervals recorded before T2.
        // Stamps jump from 2025-05-23 to 2027-12-29 with null elapsed/boot.
        final historical = [
          for (var i = 0; i < 55; i++)
            IntervalRecord(
              sessionId: 'ancient-session',
              startUtcMillis: i < 30
                  ? 1753168080000 +
                        i *
                            60000 // 2025-05-23
                  : 1830000000000 + (i - 30) * 60000, // 2027
              widthMillis: 60000,
              traction: Measurement.measured(100.0, unit: 'Wh'),
              regen: Measurement.measured(0.0, unit: 'Wh'),
              auxiliary: Measurement.measured(0.0, unit: 'Wh'),
              climate: Measurement.measured(0.0, unit: 'Wh'),
              delivered: Measurement.measured(0.0, unit: 'Wh'),
              distance: Measurement.measured(1.0, unit: 'km'),
              coveredSeconds: 60,
              climateCoveredSeconds: 0,
              speedCoveredSeconds: 0,
              deliveredCoveredSeconds: 0,
              startElapsedNanos: null,
              startBootCount: null,
              timeState: 'unknown',
            ),
        ];

        final positionOf = intervalPositionOf(historical);
        for (var i = 0; i < 55; i++) {
          expect(positionOf(historical[i]), i * 60000);
        }

        final reduced = reduceIntervalRecordsByIndex(
          historical,
          widthMillis: 120000,
          positionOf: positionOf,
        );
        expect(reduced, hasLength(28));
        expect(reduced.first.startUtcMillis, 0);
        expect(reduced.last.widthMillis, 120000);
      },
    );
  });
}
