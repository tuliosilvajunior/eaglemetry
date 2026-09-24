import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/insight.dart';
import 'package:capy_energy/core/insight_place.dart';
import 'package:capy_energy/core/insight_route_index.dart';

void main() {
  const fixturePath = 'testdata/insight_route_variant_cases.json';
  final fixture =
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, Object?>;
  final places = (fixture['places']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map(_placeOf)
      .toList(growable: false);
  final viaA = fixture['viaA']! as String;
  final viaB = fixture['viaB']! as String;
  final cases = (fixture['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  for (final testCase in cases) {
    final name = testCase['name']! as String;
    test(name, () {
      final trips = (testCase['trips']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map((map) => _tripOf(map, viaA: viaA, viaB: viaB))
          .toList(growable: false);
      final subjectId = testCase['subjectId']! as String;
      final subject = trips.firstWhere((trip) => trip.id == subjectId);
      final index = InsightRouteIndex.build(trips, places);
      final read = compareRouteVariants(
        subject: subject,
        corpus: trips,
        index: index,
      );
      final expected = testCase['expected']! as Map<String, Object?>;
      expect(read.support.considered, expected['considered']);
      if (expected['kind'] == 'none') {
        expect(read.hasInsight, isFalse);
        expect(read.absence?.name, expected['absence']);
        return;
      }
      expect(read.hasInsight, isTrue);
      expect(read.insight!.claim, InsightClaim.variantVsVariant);
      expect(read.insight!.baseline, InsightBaseline.otherVariantSameRoute);
      expect(read.insight!.confidence.name, expected['confidence']);
      expect(
        read.insight!.magnitude.displayValue,
        closeTo((expected['difference']! as num).toDouble(), 1e-9),
      );
    });
  }
}

InsightPlace _placeOf(Map<String, Object?> map) => InsightPlace(
  id: map['id']! as String,
  name: map['name']! as String,
  latitude: (map['latitude']! as num).toDouble(),
  longitude: (map['longitude']! as num).toDouble(),
);

InsightTrip _tripOf(
  Map<String, Object?> map, {
  required String viaA,
  required String viaB,
}) {
  final which = map['path']! as String;
  return InsightTrip(
    id: map['id']! as String,
    endedAtUtcMillis: (map['endedAtUtcMillis']! as num).toInt(),
    distanceKm: (map['distanceKm']! as num).toDouble(),
    canPackWh: (map['canPackWh']! as num).toDouble(),
    hasMinuteBuckets: true,
    canAgreesWithSoc: true,
    aggregationVersion: 2,
    startLatitude: -10.18,
    startLongitude: -48.33,
    endLatitude: -10.20,
    endLongitude: -48.35,
    path: which == 'B' ? viaB : viaA,
  );
}
