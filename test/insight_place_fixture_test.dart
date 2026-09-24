import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/insight_place.dart';

void main() {
  const fixturePath = 'testdata/insight_place_cases.json';
  final fixture =
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, Object?>;
  final cases = (fixture['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test(
    'the fixture states the radius and the grid the specification named',
    () {
      expect(fixture['placeRadiusM'], kInsightPlaceRadiusM);
      expect(fixture['variantGridM'], kInsightVariantGridM);
    },
  );

  for (final testCase in cases) {
    final name = testCase['name']! as String;
    test(name, () {
      final places = (testCase['places']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map(_placeOf)
          .toList(growable: false);
      if (testCase.containsKey('point')) {
        final point = _pointOf(testCase['point']! as Map<String, Object?>);
        expect(placeContaining(point, places)?.id, testCase['expectedPlaceId']);
        return;
      }
      final subject = testCase['subject']! as Map<String, Object?>;
      final corpus = (testCase['corpus']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map(_endOf)
          .toList(growable: false);
      final match = matchTripRoute(
        start: _nullablePoint(subject['start']),
        end: _nullablePoint(subject['end']),
        path: subject['path'] as String?,
        places: places,
        corpus: corpus,
      );
      expect(match?.from.id, testCase['expectedFromId']);
      expect(match?.to.id, testCase['expectedToId']);
      if (testCase['expectedFromId'] == null) {
        expect(match, isNull);
        return;
      }
      expect(match!.tripCount, testCase['expectedTripCount']);
      expect(match.variantCount, testCase['expectedVariantCount']);
    });
  }
}

InsightPlace _placeOf(Map<String, Object?> map) => InsightPlace(
  id: map['id']! as String,
  name: map['name']! as String,
  latitude: (map['latitude']! as num).toDouble(),
  longitude: (map['longitude']! as num).toDouble(),
);

InsightPoint _pointOf(Map<String, Object?> map) => InsightPoint(
  (map['latitude']! as num).toDouble(),
  (map['longitude']! as num).toDouble(),
);

InsightPoint? _nullablePoint(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  return _pointOf(raw);
}

({InsightPoint? start, InsightPoint? end, String? path}) _endOf(
  Map<String, Object?> map,
) {
  return (
    start: _nullablePoint(map['start']),
    end: _nullablePoint(map['end']),
    path: map['path'] as String?,
  );
}
