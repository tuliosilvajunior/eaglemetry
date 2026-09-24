import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  const casa = InsightPlace(
    id: 'casa',
    name: 'Casa',
    latitude: -23.5505,
    longitude: -46.6333,
    radiusM: 150,
  );
  const spazio = InsightPlace(
    id: 'spazio',
    name: 'Spazio',
    latitude: -23.5600,
    longitude: -46.6500,
    radiusM: 150,
  );
  const creche = InsightPlace(
    id: 'creche',
    name: 'Creche',
    latitude: -23.5700,
    longitude: -46.6600,
    radiusM: 150,
  );

  NamedRoute makeRoute({
    required String id,
    required InsightPlace from,
    required InsightPlace to,
    required int count,
  }) => NamedRoute(
    from: from,
    to: to,
    trips: [
      for (var i = 0; i < count; i++)
        InsightTrip(
          id: '$id-$i',
          aggregationVersion: 2,
          hasMinuteBuckets: true,
          endedAtUtcMillis: 1750000000000 + i * 86400000,
          distanceKm: 10.0,
          canPackWh: 1500.0,
          startLatitude: from.latitude,
          startLongitude: from.longitude,
          endLatitude: to.latitude,
          endLongitude: to.longitude,
        ),
    ],
  );

  group('groupRoutesByPair', () {
    test('keeps both directions of a pair in one group', () {
      final toSpazio = makeRoute(
        id: 'casa-spazio',
        from: casa,
        to: spazio,
        count: 2,
      );
      final toCasa = makeRoute(
        id: 'spazio-casa',
        from: spazio,
        to: casa,
        count: 3,
      );

      final groups = groupRoutesByPair([toSpazio, toCasa]);

      expect(groups, hasLength(1));
      final group = groups.single;
      expect(group.a.id, 'casa');
      expect(group.b.id, 'spazio');
      expect(group.directions, hasLength(2));
      expect(group.hasBothDirections, isTrue);
      expect(group.totalTrips, 5);
    });

    test('sorts directions by count descending', () {
      final toSpazio = makeRoute(
        id: 'casa-spazio',
        from: casa,
        to: spazio,
        count: 2,
      );
      final toCasa = makeRoute(
        id: 'spazio-casa',
        from: spazio,
        to: casa,
        count: 4,
      );

      final group = groupRoutesByPair([toSpazio, toCasa]).single;

      expect(group.directions.first.from.id, 'spazio');
      expect(group.directions.first.to.id, 'casa');
      expect(group.directions.last.from.id, 'casa');
    });

    test('keeps a single-direction pair in its own group', () {
      final so = makeRoute(id: 'casa-creche', from: casa, to: creche, count: 1);

      final groups = groupRoutesByPair([so]);

      expect(groups, hasLength(1));
      expect(groups.single.hasBothDirections, isFalse);
      expect(groups.single.directions.single.count, 1);
    });

    test('orders groups by total trips descending', () {
      final busyPair = groupRoutesByPair([
        makeRoute(id: 'a1', from: casa, to: spazio, count: 3),
        makeRoute(id: 'a2', from: spazio, to: casa, count: 2),
      ]).single;
      final quietPair = groupRoutesByPair([
        makeRoute(id: 'b1', from: creche, to: casa, count: 1),
      ]).single;

      final groups = groupRoutesByPair([
        makeRoute(id: 'b1', from: creche, to: casa, count: 1),
        makeRoute(id: 'a1', from: casa, to: spazio, count: 3),
        makeRoute(id: 'a2', from: spazio, to: casa, count: 2),
      ]);

      expect(groups, hasLength(2));
      expect(groups.first.totalTrips, busyPair.totalTrips);
      expect(groups.first.totalTrips, greaterThan(groups.last.totalTrips));
      expect(busyPair.totalTrips, 5);
      expect(quietPair.totalTrips, 1);
    });

    test('empty routes produce no groups', () {
      expect(groupRoutesByPair(const []), isEmpty);
    });
  });
}
