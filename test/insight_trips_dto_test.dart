import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';

void main() {
  test('fromMap keeps a null SOC agreement as unconfirmed', () {
    final result = InsightTripsResult.fromMap({
      'subjectId': 'a',
      'trips': [
        {
          'id': 'a',
          'endedAtUtcMillis': 1,
          'distanceKm': 10.0,
          'canPackWh': 1000.0,
          'hasMinuteBuckets': true,
          'canAgreesWithSoc': null,
          'aggregationVersion': 2,
        },
      ],
    });

    expect(result.subjectId, 'a');
    expect(result.subject?.canAgreesWithSoc, isNull);
    expect(result.subject?.hasMinuteBuckets, isTrue);
    expect(result.subject?.canPackWh, 1000);
  });

  test(
    'the mock answers a corpus the closed trip can compare against',
    () async {
      final api = TelemetryApi(source: MockTelemetrySource());

      final result = await api.getInsightTrips(subjectId: 'mock-trip-001');

      expect(result.subjectId, 'mock-trip-001');
      expect(result.subject, isNotNull);
      expect(result.trips.length, greaterThanOrEqualTo(5));
      final read = insightReadForSubject(
        subjectId: 'mock-trip-001',
        corpus: result.trips,
        now: DateTime.now(),
      );
      expect(read.hasInsight, isTrue);
      expect(read.insight!.confidence, InsightConfidence.supported);
    },
  );
}
