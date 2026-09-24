import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

InsightPlace _place(
  String id,
  String name,
  double latitude,
  double longitude, {
  double radiusM = kInsightPlaceRadiusM,
  int? createdAtUtcMillis,
}) {
  return InsightPlace(
    id: id,
    name: name,
    latitude: latitude,
    longitude: longitude,
    radiusM: radiusM,
    createdAtUtcMillis: createdAtUtcMillis,
  );
}

void main() {
  group('normalizedPlaceName', () {
    test('folds case and trims outer whitespace', () {
      expect(normalizedPlaceName('  Casa '), 'casa');
      expect(normalizedPlaceName('CASA'), 'casa');
      expect(normalizedPlaceName('cAsA'), normalizedPlaceName(' casa'));
    });

    test('empty and whitespace-only names collapse to empty', () {
      expect(normalizedPlaceName(''), '');
      expect(normalizedPlaceName('   '), '');
    });
  });

  group('findDuplicatePairs', () {
    test('same name within 500 m is one pair', () {
      // ~111 m apart.
      final places = [
        _place('a', 'Casa', -10.18, -48.33),
        _place('b', 'Casa', -10.181, -48.33),
      ];
      final pairs = findDuplicatePairs(places);
      expect(pairs, hasLength(1));
      expect(pairs.first.placeA.id, 'a');
      expect(pairs.first.placeB.id, 'b');
    });

    test('normalization applies: case and whitespace still collide', () {
      final places = [
        _place('a', ' casa ', -10.18, -48.33),
        _place('b', 'CASA', -10.181, -48.33),
      ];
      expect(findDuplicatePairs(places), hasLength(1));
    });

    test('same name beyond 500 m is not a duplicate', () {
      // ~1109 m apart (0.01 deg).
      final places = [
        _place('a', 'Casa', -10.18, -48.33),
        _place('b', 'Casa', -10.19, -48.33),
      ];
      expect(findDuplicatePairs(places), isEmpty);
    });

    test('different names near each other are not duplicates', () {
      final places = [
        _place('a', 'Casa', -10.18, -48.33),
        _place('b', 'Trabalho', -10.181, -48.33),
      ];
      expect(findDuplicatePairs(places), isEmpty);
    });

    test(
      'two autonamed rows with the same autoName and empty name pair up',
      () {
        // Companion auto twins: both user names empty, same suggested
        // autoName, ~111 m apart. The banner must offer Mesclar.
        InsightPlace auto(String id, double lat) => InsightPlace(
          id: id,
          name: '',
          latitude: lat,
          longitude: -48.33,
          autoName: 'Rua das Acacias, 100',
        );
        final pairs = findDuplicatePairs([
          auto('a', -10.18),
          auto('b', -10.181),
        ]);
        expect(pairs, hasLength(1));
      },
    );

    test('renamed twin vs different autoName nearby does not pair by name', () {
      final named = InsightPlace(
        id: 'a',
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      final auto = InsightPlace(
        id: 'b',
        name: '',
        latitude: -10.181,
        longitude: -48.33,
        autoName: 'Rua das Acacias, 100',
      );
      expect(findDuplicatePairs([named, auto]), isEmpty);
    });

    test('three rows with one name produce three pairs, older first', () {
      final places = [
        _place('c', 'Casa', -10.1802, -48.33, createdAtUtcMillis: 300),
        _place('a', 'Casa', -10.18, -48.33, createdAtUtcMillis: 100),
        _place('b', 'Casa', -10.1801, -48.33, createdAtUtcMillis: 200),
      ];
      final pairs = findDuplicatePairs(places);
      expect(pairs, hasLength(3));
      for (final pair in pairs) {
        expect(
          pair.placeA.createdAtUtcMillis!,
          lessThan(pair.placeB.createdAtUtcMillis!),
        );
      }
    });
  });

  group('proposeMerge geometry', () {
    test('center is the mean of both centers', () {
      final a = _place('a', 'Casa', -10.18, -48.33);
      final b = _place('b', 'Casa', -10.182, -48.334);
      final center = proposeMergeCenter(a, b);
      expect(center.latitude, closeTo(-10.181, 1e-9));
      expect(center.longitude, closeTo(-48.332, 1e-9));
    });

    test('radius covers both circles: half distance plus widest', () {
      final a = _place('a', 'Casa', -10.18, -48.33, radiusM: 150);
      final b = _place('b', 'Casa', -10.19, -48.33, radiusM: 100);
      final d = insightDistanceM(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
      final expected = d / 2 + 150;
      final radius = proposeMergeRadiusM(a, b);
      expect(radius, closeTo(expected, 1e-6));
      // Both old centers stay inside the proposal.
      final center = proposeMergeCenter(a, b);
      expect(
        insightDistanceM(
          center.latitude,
          center.longitude,
          a.latitude,
          a.longitude,
        ),
        lessThanOrEqualTo(radius),
      );
      expect(
        insightDistanceM(
          center.latitude,
          center.longitude,
          b.latitude,
          b.longitude,
        ),
        lessThanOrEqualTo(radius),
      );
    });

    test('radius clamps to the slider bounds', () {
      final tiny = _place('a', 'Casa', -10.18, -48.33, radiusM: 10);
      final tiny2 = _place('b', 'Casa', -10.1800001, -48.33, radiusM: 10);
      expect(proposeMergeRadiusM(tiny, tiny2), kInsightPlaceMinRadiusM);

      final huge = _place('a', 'Casa', -10.18, -48.33, radiusM: 1900);
      final huge2 = _place('b', 'Casa', -10.19, -48.33, radiusM: 1900);
      expect(proposeMergeRadiusM(huge, huge2), kInsightPlaceMaxRadiusM);
    });
  });

  group('resolveMergeKeep', () {
    test('older createdAt wins', () {
      final old = _place('zz', 'Casa', -10.18, -48.33, createdAtUtcMillis: 1);
      final newer = _place(
        'aa',
        'Casa',
        -10.181,
        -48.33,
        createdAtUtcMillis: 2,
      );
      expect(resolveMergeKeep(old, newer), same(old));
      expect(resolveMergeKeep(newer, old), same(old));
    });

    test('missing stamp or tie falls back to the smaller id', () {
      final aa = _place('aa', 'Casa', -10.18, -48.33);
      final zz = _place('zz', 'Casa', -10.181, -48.33);
      expect(resolveMergeKeep(aa, zz), same(aa));
      expect(resolveMergeKeep(zz, aa), same(aa));
    });
  });

  group('buildPlacesData duplicatePairs', () {
    test('exposes the near-duplicate pairs of the named list', () {
      final places = [
        _place('a', 'Casa', -10.18, -48.33),
        _place('b', 'casa', -10.181, -48.33),
        _place('c', 'Trabalho', -10.30, -48.50),
      ];
      final data = buildPlacesData(places: places, trips: const []);
      expect(data.duplicatePairs, hasLength(1));
      expect(data.duplicatePairs.first.placeA.id, 'a');
      expect(data.duplicatePairs.first.placeB.id, 'b');
    });

    test('clean list carries no pairs', () {
      final data = buildPlacesData(
        places: [_place('a', 'Casa', -10.18, -48.33)],
        trips: const [],
      );
      expect(data.duplicatePairs, isEmpty);
    });
  });

  group('candidate derivation after a merge', () {
    test('endpoints the merged circle now covers stop being candidates', () {
      // Two small circles ~200 m apart with an endpoint in the uncovered
      // middle: before the merge it derives a candidate, after the merge
      // the proposed circle contains it and the candidate goes away.
      final before = [
        _place('a', 'Casa', -10.18, -48.33, radiusM: 50),
        _place('b', 'casa', -10.1818, -48.33, radiusM: 50),
      ];
      final middle = const InsightPoint(-10.1809, -48.33);
      expect(placeContaining(middle, before), isNull);

      final trips = [
        _trip(
          startLat: -10.1809,
          startLon: -48.33,
          endLat: -10.5,
          endLon: -48.5,
        ),
      ];
      final dataBefore = buildPlacesData(places: before, trips: trips);
      // The uncovered midpoint derives its own candidate cell.
      expect(
        dataBefore.candidates.any(
          (c) => c.latitude.toStringAsFixed(3) == '-10.181',
        ),
        isTrue,
      );

      final keeper = resolveMergeKeep(before[0], before[1]);
      final after = [
        InsightPlace(
          id: keeper.id,
          name: keeper.name,
          latitude: proposeMergeCenter(before[0], before[1]).latitude,
          longitude: proposeMergeCenter(before[0], before[1]).longitude,
          radiusM: proposeMergeRadiusM(before[0], before[1]),
        ),
      ];
      expect(placeContaining(middle, after), isNotNull);
      final dataAfter = buildPlacesData(places: after, trips: trips);
      // After the merge the midpoint is inside the kept circle, so only
      // the far end still derives a candidate.
      expect(dataAfter.candidates, hasLength(1));
      expect(dataAfter.candidates.single.latitude, closeTo(-10.5, 0.01));
    });
  });

  group('findBlockingDuplicate', () {
    test('blocks a new place on top of an existing one', () {
      final existing = [_place('a', 'Casa', -10.18, -48.33)];
      final blocker = findBlockingDuplicate(
        id: null,
        name: 'casa ',
        latitude: -10.181,
        longitude: -48.33,
        existing: existing,
      );
      expect(blocker?.id, 'a');
    });

    test('updating the conflicting row itself does not block', () {
      final existing = [_place('a', 'Casa', -10.18, -48.33)];
      expect(
        findBlockingDuplicate(
          id: 'a',
          name: 'Casa',
          latitude: -10.185,
          longitude: -48.33,
          existing: existing,
        ),
        isNull,
      );
    });

    test('tombstoned rows are not handed to the check by callers', () {
      // Callers filter live rows; this asserts distance beyond the bound
      // passes even against a live row list.
      final existing = [_place('a', 'Casa', -10.19, -48.33)];
      expect(
        findBlockingDuplicate(
          id: null,
          name: 'Casa',
          latitude: -10.18,
          longitude: -48.33,
          existing: existing,
        ),
        isNull,
      );
    });

    test('unnamed write never blocks', () {
      final existing = [_place('a', '', -10.18, -48.33)];
      expect(
        findBlockingDuplicate(
          id: null,
          name: '',
          latitude: -10.18,
          longitude: -48.33,
          existing: existing,
        ),
        isNull,
      );
    });
  });

  group('DuplicatePlaceException message', () {
    test('names the place and the metres, suggests merge or wider radius', () {
      final error = DuplicatePlaceException(name: 'Casa', distanceM: 123.4);
      expect(
        error.toString(),
        "Ja existe 'Casa' a 123 m — use raio maior ou"
        ' mescle',
      );
    });
  });
}

InsightTrip _trip({
  required double startLat,
  required double startLon,
  required double endLat,
  required double endLon,
}) {
  return InsightTrip(
    id: 't-$startLat-$endLat',
    endedAtUtcMillis: 0,
    distanceKm: 1,
    canPackWh: 100,
    hasMinuteBuckets: false,
    canAgreesWithSoc: true,
    aggregationVersion: 1,
    startLatitude: startLat,
    startLongitude: startLon,
    endLatitude: endLat,
    endLongitude: endLon,
  );
}
