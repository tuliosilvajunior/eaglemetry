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

  const day = 86400000;

  InsightTrip makeTrip({
    required String id,
    int? endedAtUtcMillis,
    bool? canAgreesWithSoc = true,
    double? startLatitude = -23.5505,
    double? startLongitude = -46.6333,
    double? endLatitude = -23.5600,
    double? endLongitude = -46.6500,
    String? path,
    double? distanceKm = 10.0,
    double? canPackWh = 1500.0,
  }) => InsightTrip(
    id: id,
    endedAtUtcMillis: endedAtUtcMillis,
    aggregationVersion: 2,
    hasMinuteBuckets: true,
    canAgreesWithSoc: canAgreesWithSoc,
    startLatitude: startLatitude,
    startLongitude: startLongitude,
    endLatitude: endLatitude,
    endLongitude: endLongitude,
    path: path,
    distanceKm: distanceKm,
    canPackWh: canPackWh,
  );

  group('InsightRouteIndex.build', () {
    test('empty trips or places produces empty routes and null lookups', () {
      final emptyTripsIndex = InsightRouteIndex.build([], places);
      expect(emptyTripsIndex.routes, isEmpty);
      expect(emptyTripsIndex.routeOf('any'), isNull);
      expect(emptyTripsIndex.variantSignatureOf('any'), isEmpty);

      final emptyPlacesIndex = InsightRouteIndex.build([
        makeTrip(id: 't1'),
      ], []);
      expect(emptyPlacesIndex.routes, isEmpty);
      expect(emptyPlacesIndex.routeOf('t1'), isNull);
    });

    test(
      'groups trips by ordered pair of named places sorted by count descending',
      () {
        final t1 = makeTrip(
          id: 't1',
          startLatitude: home.latitude,
          startLongitude: home.longitude,
          endLatitude: work.latitude,
          endLongitude: work.longitude,
        );
        final t2 = makeTrip(
          id: 't2',
          startLatitude: home.latitude,
          startLongitude: home.longitude,
          endLatitude: work.latitude,
          endLongitude: work.longitude,
        );
        final t3 = makeTrip(
          id: 't3',
          startLatitude: work.latitude,
          startLongitude: work.longitude,
          endLatitude: home.latitude,
          endLongitude: home.longitude,
        );
        final t4 = makeTrip(
          id: 't4',
          startLatitude: home.latitude,
          startLongitude: home.longitude,
          endLatitude: gym.latitude,
          endLongitude: gym.longitude,
        );
        final t5 = makeTrip(
          id: 't5',
          startLatitude: home.latitude,
          startLongitude: home.longitude,
          endLatitude: work.latitude,
          endLongitude: work.longitude,
        );

        final index = InsightRouteIndex.build([t1, t2, t3, t4, t5], places);

        expect(index.routes.length, 3);

        // Most frequent route is Home -> Work (3 trips)
        final topRoute = index.routes.first;
        expect(topRoute.from.id, home.id);
        expect(topRoute.to.id, work.id);
        expect(topRoute.count, 3);
        expect(topRoute.trips, [t1, t2, t5]);

        // routeOf lookups
        expect(index.routeOf('t1'), topRoute);
        expect(index.routeOf('t2'), topRoute);
        expect(index.routeOf('t5'), topRoute);

        final returnRoute = index.routeOf('t3');
        expect(returnRoute, isNotNull);
        expect(returnRoute!.from.id, work.id);
        expect(returnRoute.to.id, home.id);
        expect(returnRoute.count, 1);

        final gymRoute = index.routeOf('t4');
        expect(gymRoute, isNotNull);
        expect(gymRoute!.from.id, home.id);
        expect(gymRoute.to.id, gym.id);
        expect(gymRoute.count, 1);

        expect(index.routeOf('nonexistent'), isNull);
      },
    );

    test(
      'ignores trips with missing start/end, unknown place coordinates, or loop trips (from == to)',
      () {
        final noStart = makeTrip(
          id: 'no-start',
          startLatitude: null,
          startLongitude: null,
        );
        final noEnd = makeTrip(
          id: 'no-end',
          endLatitude: null,
          endLongitude: null,
        );
        final unknownEnd = makeTrip(
          id: 'unknown-end',
          startLatitude: home.latitude,
          startLongitude: home.longitude,
          endLatitude: 0.0,
          endLongitude: 0.0,
        );
        final loop = makeTrip(
          id: 'loop',
          startLatitude: home.latitude,
          startLongitude: home.longitude,
          endLatitude: home.latitude,
          endLongitude: home.longitude,
        );

        final index = InsightRouteIndex.build([
          noStart,
          noEnd,
          unknownEnd,
          loop,
        ], places);

        expect(index.routes, isEmpty);
        expect(index.routeOf('no-start'), isNull);
        expect(index.routeOf('no-end'), isNull);
        expect(index.routeOf('unknown-end'), isNull);
        expect(index.routeOf('loop'), isNull);
      },
    );

    test('variantSignatureOf returns signature for trip path', () {
      const pathA = '-23.5505,-46.6333;-23.5550,-46.6400;-23.5600,-46.6500';
      const pathB = '-23.5505,-46.6333;-23.5580,-46.6450;-23.5600,-46.6500';

      final t1 = makeTrip(id: 't1', path: pathA);
      final t2 = makeTrip(id: 't2', path: pathB);
      final tNoPath = makeTrip(id: 't3', path: null);

      final index = InsightRouteIndex.build([t1, t2, tNoPath], places);

      final sig1 = index.variantSignatureOf('t1');
      final sig2 = index.variantSignatureOf('t2');
      final sigNoPath = index.variantSignatureOf('t3');
      final sigUnknown = index.variantSignatureOf('unknown');

      expect(sig1.isNotEmpty, isTrue);
      expect(sig2.isNotEmpty, isTrue);
      expect(sig1, isNot(equals(sig2)));
      expect(sigNoPath, isEmpty);
      expect(sigUnknown, isEmpty);
    });

    test(
      'matchOf returns InsightRouteMatch with correct variant count and trip count',
      () {
        const pathA = '-23.5505,-46.6333;-23.5550,-46.6400;-23.5600,-46.6500';
        const pathB = '-23.5505,-46.6333;-23.5580,-46.6450;-23.5600,-46.6500';

        final t1 = makeTrip(id: 't1', path: pathA);
        final t2 = makeTrip(id: 't2', path: pathA);
        final t3 = makeTrip(id: 't3', path: pathB);
        final tUnknown = makeTrip(
          id: 't-unnamed',
          startLatitude: 0.0,
          startLongitude: 0.0,
        );

        final index = InsightRouteIndex.build([t1, t2, t3, tUnknown], places);

        final match1 = index.matchOf('t1');
        expect(match1, isNotNull);
        expect(match1!.from.id, home.id);
        expect(match1.to.id, work.id);
        expect(match1.tripCount, 3);
        expect(match1.variantCount, 2);
        expect(match1.variantSignature, index.variantSignatureOf('t1'));

        final match3 = index.matchOf('t3');
        expect(match3, isNotNull);
        expect(match3!.from.id, home.id);
        expect(match3.to.id, work.id);
        expect(match3.tripCount, 3);
        expect(match3.variantCount, 2);
        expect(match3.variantSignature, index.variantSignatureOf('t3'));

        expect(index.matchOf('t-unnamed'), isNull);
        expect(index.matchOf('non-existent'), isNull);
      },
    );
  });

  group('NamedRoute statistics', () {
    test('computes averageDistanceKm and averageWhPerKm accurately', () {
      final t1 = makeTrip(
        id: 't1',
        distanceKm: 10.0,
        canPackWh: 1500.0, // 150 Wh/km
      );
      final t2 = makeTrip(
        id: 't2',
        distanceKm: 20.0,
        canPackWh: 2500.0, // 125 Wh/km
      );

      final route = NamedRoute(from: home, to: work, trips: [t1, t2]);

      expect(route.count, 2);
      expect(route.averageDistanceKm, 15.0);
      // Total Wh = 4000, Total km = 30 -> 4000/30 = 133.33333333333334
      expect(route.averageWhPerKm, closeTo(133.333, 0.001));
    });

    test('returns null averages when trips have no valid distance or Wh', () {
      final t1 = makeTrip(id: 't1', distanceKm: null, canPackWh: null);
      final t2 = makeTrip(id: 't2', distanceKm: 0.0, canPackWh: 0.0);

      final route = NamedRoute(from: home, to: work, trips: [t1, t2]);

      expect(route.averageDistanceKm, isNull);
      expect(route.averageWhPerKm, isNull);
    });
  });

  group('NamedRoute ranking and eligibility', () {
    test('ranks measured trips most efficient first', () {
      final t1 = makeTrip(
        id: 'slow',
        endedAtUtcMillis: 1750000000000,
        distanceKm: 10.0,
        canPackWh: 1600.0, // 160 Wh/km
      );
      final t2 = makeTrip(
        id: 'best',
        endedAtUtcMillis: 1750000000000 + day,
        distanceKm: 10.0,
        canPackWh: 1000.0, // 100 Wh/km
      );
      final t3 = makeTrip(
        id: 'middle',
        endedAtUtcMillis: 1750000000000 + 2 * day,
        distanceKm: 20.0,
        canPackWh: 2500.0, // 125 Wh/km
      );

      final route = NamedRoute(from: home, to: work, trips: [t1, t2, t3]);
      final ranking = route.rankingByEfficiency;

      expect(ranking.map((e) => e.$1.id).toList(), ['best', 'middle', 'slow']);
      expect(ranking.first.$2, closeTo(100.0, 0.001));
      expect(ranking.last.$2, closeTo(160.0, 0.001));
    });

    test('counts only comparable trips for the eligibility gate', () {
      final measured = makeTrip(
        id: 'measured',
        endedAtUtcMillis: 1750000000000,
      );
      final noEnergy = makeTrip(
        id: 'no-energy',
        endedAtUtcMillis: 1750000000000,
        canPackWh: null,
      );
      final noBuckets = InsightTrip(
        id: 'no-buckets',
        aggregationVersion: 2,
        hasMinuteBuckets: false,
        endedAtUtcMillis: 1750000000000,
        distanceKm: 10.0,
        canPackWh: 1500.0,
      );
      final unconfirmed = InsightTrip(
        id: 'unconfirmed',
        aggregationVersion: 2,
        hasMinuteBuckets: true,
        canAgreesWithSoc: null,
        endedAtUtcMillis: 1750000000000,
        distanceKm: 10.0,
        canPackWh: 1500.0,
      );
      final open = makeTrip(id: 'open', endedAtUtcMillis: null);

      final route = NamedRoute(
        from: home,
        to: work,
        trips: [measured, noEnergy, noBuckets, unconfirmed, open],
      );

      expect(route.count, 5);
      expect(route.measuredCount, 1);
      expect(route.isComparable, isFalse);
      expect(route.missingTrips, kInsightMinReferenceTrips - 1);
      expect(route.rankingByEfficiency, hasLength(1));
    });

    test('a route at the gate is comparable with nothing missing', () {
      final trips = [
        for (var i = 1; i <= kInsightMinReferenceTrips; i++)
          makeTrip(id: 't$i', endedAtUtcMillis: 1750000000000 + i * day),
      ];

      final route = NamedRoute(from: home, to: work, trips: trips);

      expect(route.isComparable, isTrue);
      expect(route.missingTrips, 0);
    });
  });
}
