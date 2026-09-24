import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  final origin = DateTime.utc(2026, 8, 6, 21, 0);
  const tenSeconds = Duration(seconds: 10);

  EnergyBucket bucket({
    int index = 0,
    Duration width = tenSeconds,
    double tractionWh = 0,
    double regeneratedWh = 0,
    double auxiliaryWh = 0,
    double speedDistanceKm = 0,
    double odometerDistanceKm = 0,
    double? integratedSeconds,
  }) => EnergyBucket(
    start: origin.add(width * index),
    width: width,
    tractionWh: tractionWh,
    regeneratedWh: regeneratedWh,
    auxiliaryWh: auxiliaryWh,
    integratedSeconds: integratedSeconds ?? width.inSeconds.toDouble(),
    speedDistanceKm: speedDistanceKm,
    odometerDistanceKm: odometerDistanceKm,
    speedIntegratedSeconds: width.inSeconds.toDouble(),
  );

  // 50 km/h for ten seconds at 15 kW: 138.9 m on 41.67 Wh.
  EnergyBucket cruising({int index = 0}) =>
      bucket(index: index, tractionWh: 41.667, speedDistanceKm: 0.13889);

  group('states', () {
    test('moving while drawing reports the ratio', () {
      final point = readEfficiency([cruising()]).points.single;

      expect(point.state, EfficiencyState.consuming);
      expect(point.kmPerKwh, closeTo(3.333, 0.001));
    });

    test('auxiliary draw counts against efficiency', () {
      final point = readEfficiency([
        bucket(
          tractionWh: 41.667,
          auxiliaryWh: 41.667,
          speedDistanceKm: 0.13889,
        ),
      ]).points.single;

      expect(point.netWh, closeTo(83.334, 0.001));
      expect(point.kmPerKwh, closeTo(1.667, 0.001));
    });

    test('regeneration is credited back before the ratio', () {
      final point = readEfficiency([
        bucket(tractionWh: 60, regeneratedWh: 20, speedDistanceKm: 0.13889),
      ]).points.single;

      expect(point.netWh, closeTo(40, 0.001));
      expect(point.kmPerKwh, closeTo(3.472, 0.001));
    });

    test('stopped with a load reads zero, not missing', () {
      final point = readEfficiency([bucket(auxiliaryWh: 5)]).points.single;

      expect(point.state, EfficiencyState.idle);
      expect(point.kmPerKwh, 0);
    });

    test('a net gain reports no ratio', () {
      final point = readEfficiency([
        bucket(regeneratedWh: 10, auxiliaryWh: 1, speedDistanceKm: 0.13889),
      ]).points.single;

      expect(point.state, EfficiencyState.regenerating);
      expect(point.gainedRange, isTrue);
      expect(point.netWh, closeTo(-9, 0.001));
      expect(point.kmPerKwh, isNull);
    });

    test('coasting does not report an arithmetically huge ratio', () {
      final point = readEfficiency([
        bucket(tractionWh: 0.1, speedDistanceKm: 0.13889),
      ], window: Duration.zero).points.single;

      expect(point.state, EfficiencyState.coasting);
      expect(point.kmPerKwh, isNull);
    });

    test('an interval the car did not report is unreported, not a zero', () {
      final point = readEfficiency([
        bucket(integratedSeconds: 0),
      ]).points.single;

      expect(point.state, EfficiencyState.unreported);
      expect(point.kmPerKwh, isNull);
      // Nothing was measured, so the floors have no span to scale to.
      expect(point.measured, Duration.zero);
      expect(point.netWhPerKm, isNull);
    });

    test('a reported standstill with no load is still, not unreported', () {
      // Two different facts about the car. One is a red light; the other is a
      // bus that stopped publishing. Neither has a ratio, and that is the only
      // thing they have in common.
      final point = readEfficiency([bucket()]).points.single;

      expect(point.state, EfficiencyState.still);
      expect(point.kmPerKwh, isNull);
      expect(point.measured, greaterThan(Duration.zero));
    });

    test('a standstill still counts as the newest thing the car said', () {
      // Read at the bucket. Through the trailing window the standstill would
      // inherit the driving behind it and read as `consuming`, which is the
      // window working, not the state being wrong.
      final series = readEfficiency([
        cruising(index: 0),
        bucket(index: 1),
      ], window: Duration.zero);

      expect(series.points[1].state, EfficiencyState.still);
      expect(series.head?.start, origin.add(tenSeconds));
    });

    test('unreported intervals keep their slot on the time axis', () {
      final series = readEfficiency([
        cruising(index: 0),
        bucket(index: 1, integratedSeconds: 0),
        cruising(index: 2),
      ]);

      expect(series.points, hasLength(3));
      expect(series.points[1].state, EfficiencyState.unreported);
      expect(series.points[2].start, origin.add(tenSeconds * 2));
    });
  });

  group('average', () {
    test('is the ratio of the sums, not the mean of the ratios', () {
      // Fast: 0.5 km on 100 Wh (5 km/kWh). Slow: 0.02 km on 20 Wh (1 km/kWh).
      // The mean of the ratios is 3.0; the real window efficiency is 4.333.
      final series = readEfficiency([
        bucket(index: 0, tractionWh: 100, speedDistanceKm: 0.5),
        bucket(index: 1, tractionWh: 20, speedDistanceKm: 0.02),
      ], window: Duration.zero);

      expect(series.points[0].kmPerKwh, closeTo(5, 0.001));
      expect(series.points[1].kmPerKwh, closeTo(1, 0.001));
      expect(series.averageKmPerKwh, closeTo(4.333, 0.001));
    });

    test('gaps contribute neither distance nor energy', () {
      final withGap = readEfficiency([
        cruising(index: 0),
        bucket(
          index: 1,
          tractionWh: 999,
          speedDistanceKm: 9,
          integratedSeconds: 0,
        ),
      ]);

      expect(withGap.averageKmPerKwh, closeTo(3.333, 0.001));
    });

    test('idle time drags the window average down', () {
      final series = readEfficiency([
        cruising(index: 0),
        bucket(index: 1, auxiliaryWh: 41.667),
      ]);

      expect(series.averageKmPerKwh, closeTo(1.667, 0.001));
    });

    test('a window that gained energy has no average', () {
      final series = readEfficiency([
        bucket(regeneratedWh: 50, speedDistanceKm: 0.2),
      ]);

      expect(series.averageKmPerKwh, isNull);
    });

    test('a window that never moved has no average', () {
      final series = readEfficiency([bucket(auxiliaryWh: 20)]);

      expect(series.averageKmPerKwh, isNull);
    });
  });

  group('head', () {
    test('is the newest reported interval', () {
      final series = readEfficiency([
        bucket(index: 0, tractionWh: 100, speedDistanceKm: 0.5),
        cruising(index: 1),
      ], window: Duration.zero);

      expect(series.head?.start, origin.add(tenSeconds));
      expect(series.head?.kmPerKwh, closeTo(3.333, 0.001));
    });

    test(
      'stays on the last reading instead of dropping into a trailing gap',
      () {
        final series = readEfficiency([
          cruising(index: 0),
          bucket(index: 1, integratedSeconds: 0),
          bucket(index: 2, integratedSeconds: 0),
        ]);

        expect(series.head?.start, origin);
        expect(series.head?.state, EfficiencyState.consuming);
      },
    );

    test('is null when nothing was reported', () {
      expect(readEfficiency([bucket(integratedSeconds: 0)]).head, isNull);
      expect(EfficiencySeries.empty.head, isNull);
    });
  });

  group('distance source', () {
    test('sub-minute intervals ignore the odometer', () {
      // The odometer resolves in whole kilometres, so at ten seconds it lands
      // one interval's step onto a neighbour that did the same distance.
      final series = readEfficiency([
        bucket(
          tractionWh: 41.667,
          speedDistanceKm: 0.13889,
          odometerDistanceKm: 1,
        ),
      ]);

      expect(series.points.single.distanceKm, closeTo(0.13889, 0.00001));
    });

    test('minute intervals prefer the odometer', () {
      final series = readEfficiency([
        bucket(
          width: EnergyBucket.oneMinute,
          tractionWh: 250,
          speedDistanceKm: 0.9,
          odometerDistanceKm: 1,
        ),
      ]);

      expect(series.points.single.distanceKm, closeTo(1, 0.00001));
      expect(series.points.single.kmPerKwh, closeTo(4, 0.001));
    });

    test(
      'minute intervals fall back to speed when the odometer did not move',
      () {
        final series = readEfficiency([
          bucket(
            width: EnergyBucket.oneMinute,
            tractionWh: 250,
            speedDistanceKm: 0.9,
          ),
        ]);

        expect(series.points.single.distanceKm, closeTo(0.9, 0.00001));
      },
    );

    test('the source can be forced', () {
      final series = readEfficiency([
        bucket(
          width: EnergyBucket.oneMinute,
          tractionWh: 250,
          speedDistanceKm: 0.9,
          odometerDistanceKm: 1,
        ),
      ], distanceSource: EfficiencyDistanceSource.speedOnly);

      expect(series.points.single.distanceKm, closeTo(0.9, 0.00001));
    });
  });

  test('an empty series is empty, not zero', () {
    final series = readEfficiency(const []);

    expect(series.isEmpty, isTrue);
    expect(series.averageKmPerKwh, isNull);
  });

  group('trailing window', () {
    /// The reason the window exists.
    ///
    /// Two intervals of one climb-and-brake cycle: the first spends, the
    /// second gives most of it back. Read one at a time they report 1.7 and
    /// 27.8 km/kWh, a sixteen-fold swing over two adjacent ten-second slots of
    /// steady driving. Read over the pair they report the 3.3 the driving
    /// actually achieved.
    test('stops one cycle of regeneration reading as two verdicts', () {
      final climb = bucket(
        index: 0,
        tractionWh: 83.334,
        speedDistanceKm: 0.13889,
      );
      final brake = bucket(
        index: 1,
        tractionWh: 41.667,
        regeneratedWh: 41.667,
        speedDistanceKm: 0.13889,
      );

      final apart = readEfficiency([climb, brake], window: Duration.zero);
      expect(apart.points[0].kmPerKwh, closeTo(1.667, 0.01));
      expect(apart.points[1].state, EfficiencyState.coasting);

      final together = readEfficiency([
        climb,
        brake,
      ], window: const Duration(minutes: 3));
      expect(together.points[1].kmPerKwh, closeTo(3.333, 0.01));
      expect(together.points[1].state, EfficiencyState.consuming);
    });

    test('each point reaches back over the window, and no further', () {
      final buckets = [for (var i = 0; i < 30; i++) cruising(index: i)];
      // Six ten-second slots to the minute.
      final series = readEfficiency(
        buckets,
        window: const Duration(minutes: 1),
      );

      expect(series.points[0].drawnWh, closeTo(41.667, 0.01));
      expect(series.points[5].drawnWh, closeTo(41.667 * 6, 0.01));
      expect(series.points[20].drawnWh, closeTo(41.667 * 6, 0.01));
      // The ratio is the same throughout, because the driving is.
      expect(series.points[20].kmPerKwh, closeTo(3.333, 0.001));
    });

    test('a slot the car did not report stays a gap inside a full window', () {
      final series = readEfficiency([
        cruising(index: 0),
        cruising(index: 1),
        bucket(index: 2, integratedSeconds: 0),
      ]);

      expect(series.points[2].state, EfficiencyState.unreported);
      expect(series.head?.start, origin.add(tenSeconds));
    });

    test('the window average does not depend on the window', () {
      final buckets = [
        for (var i = 0; i < 20; i++)
          bucket(
            index: i,
            tractionWh: 20.0 + i * 3,
            regeneratedWh: i.isEven ? 15.0 : 0.0,
            speedDistanceKm: 0.1 + i * 0.002,
          ),
      ];

      final reference = readEfficiency(buckets, window: Duration.zero);
      for (final window in const [
        Duration(seconds: 30),
        Duration(minutes: 3),
        Duration(minutes: 15),
      ]) {
        final series = readEfficiency(buckets, window: window);
        expect(
          series.averageKmPerKwh,
          closeTo(reference.averageKmPerKwh!, 1e-9),
        );
        expect(series.distanceKm, closeTo(reference.distanceKm, 1e-9));
      }
    });
  });

  group('proportional floors', () {
    /// The half-watt-hour constant was right for ten seconds and wrong for
    /// three minutes, where it let a barely-moving car through and the tiny
    /// distance then divided into a large energy.
    test('scale with the interval', () {
      expect(efficiencyEnergyFloorWh(tenSeconds), closeTo(0.278, 0.001));
      expect(
        efficiencyEnergyFloorWh(const Duration(minutes: 3)),
        closeTo(5.0, 0.001),
      );
      expect(efficiencyDistanceFloorKm(tenSeconds), closeTo(0.00556, 0.0001));
      expect(
        efficiencyDistanceFloorKm(const Duration(minutes: 3)),
        closeTo(0.1, 0.0001),
      );
    });

    /// 60 m over three minutes is 1.2 km/h. The car was in a queue, not
    /// driving, and dividing 400 Wh by it would report 6 667 Wh/km as though
    /// it described travel.
    test('a crawling window has no ratio to report', () {
      final buckets = [
        for (var i = 0; i < 18; i++)
          bucket(index: i, tractionWh: 22.2, speedDistanceKm: 0.00333),
      ];
      final series = readEfficiency(buckets);

      expect(series.points.last.state, EfficiencyState.idle);
      expect(series.points.last.netWhPerKm, isNull);
    });
  });

  group('the two lines', () {
    test('demand, recovered and cost are one subtraction', () {
      final point = readEfficiency([
        bucket(
          tractionWh: 80,
          auxiliaryWh: 20,
          regeneratedWh: 40,
          speedDistanceKm: 0.5,
        ),
      ], window: Duration.zero).points.single;

      expect(point.drawnWh, closeTo(100, 0.001));
      expect(point.regeneratedWh, closeTo(40, 0.001));
      expect(point.netWh, closeTo(60, 0.001));
      // Sharing the denominator is what lets the band be drawn as the gap
      // between the two lines. In km/kWh these would be reciprocals and would
      // not subtract.
      expect(point.drawnWhPerKm, closeTo(200, 0.001));
      expect(point.netWhPerKm, closeTo(120, 0.001));
      expect(point.drawnWhPerKm! - point.netWhPerKm!, closeTo(40 / 0.5, 0.001));
    });

    test(
      'a stretch that gave back more than it took reports a negative cost',
      () {
        final point = readEfficiency([
          bucket(tractionWh: 10, regeneratedWh: 60, speedDistanceKm: 0.3),
        ], window: Duration.zero).points.single;

        expect(point.state, EfficiencyState.regenerating);
        expect(point.kmPerKwh, isNull);
        expect(point.netWhPerKm, lessThan(0));
      },
    );
  });
}
