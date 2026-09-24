import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/insight.dart';

void main() {
  const fixturePath = 'testdata/insight_own_average_cases.json';
  const tolerance = 1e-9;

  final fixture =
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, Object?>;
  final now = DateTime.fromMillisecondsSinceEpoch(
    (fixture['nowUtcMillis']! as num).toInt(),
    isUtc: true,
  );
  final cases = (fixture['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the fixture states the window the specification named', () {
    expect(fixture['windowDays'], 30);
    expect(fixture['distanceFloorKm'], kInsightDistanceFloorKm);
    expect(fixture['minReferenceTrips'], kInsightMinReferenceTrips);
    expect(kInsightOwnAverageWindow.inDays, 30);
  });

  for (final testCase in cases) {
    final name = testCase['name']! as String;
    test(name, () {
      final read = _readCase(testCase, now);
      final expected = testCase['expected']! as Map<String, Object?>;
      _expectRead(read, expected, tolerance);
    });
  }

  test('the same aggregates produce the same insight twice', () {
    final testCase = cases.firstWhere(
      (item) => item['name'] == 'a gap larger than the IQR is a claim',
    );
    final first = _readCase(testCase, now);
    final second = _readCase(testCase, now);
    expect(first.hasInsight, isTrue);
    expect(second.insight!.magnitude.value, first.insight!.magnitude.value);
    expect(second.insight!.support, first.insight!.support);
    expect(second.insight!.confidence, first.insight!.confidence);
  });

  test('a subject absent from the corpus is never recorded', () {
    final read = insightReadForSubject(
      subjectId: 'missing',
      corpus: const [],
      now: now,
    );
    expect(read.hasInsight, isFalse);
    expect(read.absence, InsightAbsence.subjectNeverRecorded);
    expect(read.support.considered, 0);
  });
}

InsightRead _readCase(Map<String, Object?> testCase, DateTime now) {
  final trips = (testCase['trips']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map(_tripOf)
      .toList(growable: false);
  final subjectId = testCase['subjectId']! as String;
  return compareTripToOwnAverage(
    subject: trips.firstWhere((trip) => trip.id == subjectId),
    corpus: trips,
    now: now,
  );
}

InsightTrip _tripOf(Map<String, Object?> map) {
  return InsightTrip(
    id: map['id']! as String,
    endedAtUtcMillis: (map['endedAtUtcMillis'] as num?)?.toInt(),
    distanceKm: (map['distanceKm'] as num?)?.toDouble(),
    canPackWh: (map['canPackWh'] as num?)?.toDouble(),
    hasMinuteBuckets: map['hasMinuteBuckets'] == true,
    canAgreesWithSoc: map['canAgreesWithSoc'] as bool?,
    aggregationVersion: (map['aggregationVersion']! as num).toInt(),
  );
}

void _expectRead(
  InsightRead read,
  Map<String, Object?> expected,
  double tolerance,
) {
  expect(read.support.window, kInsightOwnAverageWindow);
  expect(read.support.considered, expected['considered']);

  final excluded = expected['excluded'] as Map<String, Object?>?;
  if (excluded != null) {
    expect(read.support.excluded.length, excluded.length);
    for (final entry in excluded.entries) {
      final reason = InsightExclusion.values.firstWhere(
        (value) => value.name == entry.key,
      );
      expect(read.support.excluded[reason], entry.value);
    }
  }

  if (expected['kind'] == 'none') {
    expect(read.hasInsight, isFalse);
    expect(read.absence?.name, expected['absence']);
    return;
  }

  final insight = read.insight;
  expect(insight, isNotNull);
  expect(insight!.claim, InsightClaim.tripVsOwnAverage30d);
  expect(insight.baseline, InsightBaseline.ownAverage30d);
  expect(insight.confidence.name, expected['confidence']);
  expect(insight.aggregationVersion, expected['aggregationVersion']);
  expect(insight.subject.unit, 'Wh/km');
  expect(insight.reference.unit, 'Wh/km');
  expect(insight.magnitude.unit, 'Wh/km');
  _expectClose(insight.subject.value, expected['subjectWhPerKm'], tolerance);
  _expectClose(
    insight.reference.value,
    expected['referenceWhPerKm'],
    tolerance,
  );
  _expectClose(
    insight.magnitude.value,
    expected['differenceWhPerKm'],
    tolerance,
  );
}

void _expectClose(double? actual, Object? expected, double tolerance) {
  expect(actual, isNotNull);
  expect(actual!, closeTo((expected! as num).toDouble(), tolerance));
}
