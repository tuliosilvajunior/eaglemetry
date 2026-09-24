import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  const home = InsightPlace(
    id: 'place-home',
    name: 'Home',
    latitude: -23.5505,
    longitude: -46.6333,
    radiusM: 150,
  );
  const work = InsightPlace(
    id: 'place-work',
    name: 'Work',
    latitude: -23.5600,
    longitude: -46.6500,
    radiusM: 150,
  );
  const gym = InsightPlace(
    id: 'place-gym',
    name: 'Gym',
    latitude: -23.5700,
    longitude: -46.6600,
    radiusM: 150,
  );
  final places = [home, work, gym];

  const pathA = '-23.5505,-46.6333;-23.5550,-46.6400;-23.5600,-46.6500';
  const pathB = '-23.5505,-46.6333;-23.5580,-46.6450;-23.5600,-46.6500';
  const pathC = '-23.5505,-46.6333;-23.5650,-46.6550;-23.5700,-46.6600';

  InsightTrip makeTrip({
    required String id,
    required int endedAtUtcMillis,
    required double startLat,
    required double startLon,
    required double endLat,
    required double endLon,
    required String path,
    double canPackWh = 1500.0,
  }) => InsightTrip(
    id: id,
    aggregationVersion: 2,
    hasMinuteBuckets: true,
    canAgreesWithSoc: true,
    startLatitude: startLat,
    startLongitude: startLon,
    endLatitude: endLat,
    endLongitude: endLon,
    path: path,
    distanceKm: 10.0,
    canPackWh: canPackWh,
    endedAtUtcMillis: endedAtUtcMillis,
    meanAmbientTempC: 25.0,
  );

  test(
    'compareRouteVariants on a large corpus scales linearly and runs in milliseconds',
    () {
      const totalTrips = 2000;
      final baseTime = DateTime.utc(2026, 8, 24, 12, 0).millisecondsSinceEpoch;

      final trips = <InsightTrip>[];
      for (var i = 0; i < totalTrips; i++) {
        if (i < 50) {
          // Home -> Work viaA
          trips.add(
            makeTrip(
              id: 'trip-$i',
              endedAtUtcMillis: baseTime - i * 3600000,
              startLat: home.latitude,
              startLon: home.longitude,
              endLat: work.latitude,
              endLon: work.longitude,
              path: pathA,
              canPackWh: 1400.0,
            ),
          );
        } else if (i < 100) {
          // Home -> Work viaB
          trips.add(
            makeTrip(
              id: 'trip-$i',
              endedAtUtcMillis: baseTime - (i - 50) * 3600000 - 1800000,
              startLat: home.latitude,
              startLon: home.longitude,
              endLat: work.latitude,
              endLon: work.longitude,
              path: pathB,
              canPackWh: 1600.0,
            ),
          );
        } else {
          // Other routes or unrouted drives
          trips.add(
            makeTrip(
              id: 'trip-$i',
              endedAtUtcMillis: baseTime - i * 3600000,
              startLat: home.latitude,
              startLon: home.longitude,
              endLat: gym.latitude,
              endLon: gym.longitude,
              path: pathC,
              canPackWh: 1500.0,
            ),
          );
        }
      }

      final subject = trips.first;

      // Index is built once per read pass
      final index = InsightRouteIndex.build(trips, places);

      // Warm-up JIT
      compareRouteVariants(subject: subject, corpus: trips, index: index);

      final stopwatch = Stopwatch()..start();
      final read = compareRouteVariants(
        subject: subject,
        corpus: trips,
        index: index,
      );
      stopwatch.stop();

      expect(read.hasInsight, isTrue);
      expect(read.insight!.claim, InsightClaim.variantVsVariant);
      expect(read.insight!.baseline, InsightBaseline.otherVariantSameRoute);

      // Quadratic route-matching algorithm across N=2000 trips performs 4,000,000
      // geometry and regex operations. Linear index lookup completes in < 25ms.
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(25),
        reason:
            'compareRouteVariants took ${stopwatch.elapsedMilliseconds}ms; quadratic would exceed threshold',
      );
    },
  );
}
