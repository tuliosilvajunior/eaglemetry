import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

InsightTrip _trip({
  required String id,
  required int endedAtUtcMillis,
  double distanceKm = 10.0,
  double canPackWh = 1500.0,
  String? path,
  double? startLatitude,
  double? startLongitude,
  double? endLatitude,
  double? endLongitude,
  bool hasMinuteBuckets = true,
  bool? canAgreesWithSoc = true,
  int aggregationVersion = 2,
  double? meanAmbientTempC = 25.0,
}) => InsightTrip(
  id: id,
  endedAtUtcMillis: endedAtUtcMillis,
  distanceKm: distanceKm,
  canPackWh: canPackWh,
  path: path,
  startLatitude: startLatitude,
  startLongitude: startLongitude,
  endLatitude: endLatitude,
  endLongitude: endLongitude,
  hasMinuteBuckets: hasMinuteBuckets,
  canAgreesWithSoc: canAgreesWithSoc,
  aggregationVersion: aggregationVersion,
  meanAmbientTempC: meanAmbientTempC,
);

void main() {
  const placeHome = InsightPlace(
    id: 'place-home',
    name: 'Home',
    latitude: -23.5505,
    longitude: -46.6333,
    radiusM: 150.0,
  );

  const placeWork = InsightPlace(
    id: 'place-work',
    name: 'Work',
    latitude: -23.5600,
    longitude: -46.6500,
    radiusM: 150.0,
  );

  final places = [placeHome, placeWork];

  const viaA = '-23.5505,-46.6333;-23.5550,-46.6400;-23.5600,-46.6500';
  const viaB = '-23.5505,-46.6333;-23.5580,-46.6450;-23.5600,-46.6500';

  final now = DateTime.utc(2026, 8, 24, 12, 0);
  final nowMillis = now.millisecondsSinceEpoch;
  const dayMillis = 86400000;

  group('primaryInsight - Preference Order', () {
    test('when trip is not on a route, chooses ownAverage30d as primary', () {
      final subject = _trip(
        id: 'subject',
        endedAtUtcMillis: nowMillis - dayMillis,
        // No coordinates => notOnRoute
      );

      final corpus = [
        subject,
        _trip(
          id: 'ref-1',
          endedAtUtcMillis: nowMillis - 2 * dayMillis,
          distanceKm: 10,
          canPackWh: 1600,
        ),
        _trip(
          id: 'ref-2',
          endedAtUtcMillis: nowMillis - 3 * dayMillis,
          distanceKm: 10,
          canPackWh: 1550,
        ),
        _trip(
          id: 'ref-3',
          endedAtUtcMillis: nowMillis - 4 * dayMillis,
          distanceKm: 10,
          canPackWh: 1500,
        ),
        _trip(
          id: 'ref-4',
          endedAtUtcMillis: nowMillis - 5 * dayMillis,
          distanceKm: 10,
          canPackWh: 1450,
        ),
      ];

      final index = InsightRouteIndex.build(corpus, places);
      final selection = primaryInsight(
        subject: subject,
        corpus: corpus,
        index: index,
        now: now,
      );

      // Primary is own average
      expect(selection.primary.hasInsight, isTrue);
      expect(
        selection.primary.insight!.baseline,
        InsightBaseline.ownAverage30d,
      );
      expect(
        selection.primary.insight!.claim,
        InsightClaim.tripVsOwnAverage30d,
      );

      // Secondary / discarded is variant comparison with notOnRoute absence
      expect(selection.secondary, isNotNull);
      expect(selection.secondary!.hasInsight, isFalse);
      expect(selection.secondary!.absence, InsightAbsence.notOnRoute);
      expect(selection.discarded, selection.secondary);
    });

    test(
      'when route has only one variant (no other variant), chooses ownAverage30d as primary',
      () {
        final subject = _trip(
          id: 'subject',
          endedAtUtcMillis: nowMillis - dayMillis,
          startLatitude: -23.5505,
          startLongitude: -46.6333,
          endLatitude: -23.5600,
          endLongitude: -46.6500,
          path: viaA,
        );

        final corpus = [
          subject,
          // All other trips follow the same viaA
          _trip(
            id: 'ref-1',
            endedAtUtcMillis: nowMillis - 2 * dayMillis,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaA,
            distanceKm: 10,
            canPackWh: 1600,
          ),
          _trip(
            id: 'ref-2',
            endedAtUtcMillis: nowMillis - 3 * dayMillis,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaA,
            distanceKm: 10,
            canPackWh: 1550,
          ),
          _trip(
            id: 'ref-3',
            endedAtUtcMillis: nowMillis - 4 * dayMillis,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaA,
            distanceKm: 10,
            canPackWh: 1500,
          ),
          _trip(
            id: 'ref-4',
            endedAtUtcMillis: nowMillis - 5 * dayMillis,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaA,
            distanceKm: 10,
            canPackWh: 1450,
          ),
        ];

        final index = InsightRouteIndex.build(corpus, places);
        final selection = primaryInsight(
          subject: subject,
          corpus: corpus,
          index: index,
          now: now,
        );

        // Primary is own average
        expect(selection.primary.hasInsight, isTrue);
        expect(
          selection.primary.insight!.baseline,
          InsightBaseline.ownAverage30d,
        );

        // Secondary / discarded is variant comparison with noOtherVariant absence
        expect(selection.secondary, isNotNull);
        expect(selection.secondary!.hasInsight, isFalse);
        expect(selection.secondary!.absence, InsightAbsence.noOtherVariant);
      },
    );

    test(
      'when route has multiple variants with enough support, chooses otherVariantSameRoute as primary',
      () {
        final subject = _trip(
          id: 'subject',
          endedAtUtcMillis: nowMillis - dayMillis,
          startLatitude: -23.5505,
          startLongitude: -46.6333,
          endLatitude: -23.5600,
          endLongitude: -46.6500,
          path: viaA,
          distanceKm: 10,
          canPackWh: 1200,
        );

        final corpus = [
          subject,
          _trip(
            id: 'a-1',
            endedAtUtcMillis: nowMillis - 2 * dayMillis,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaA,
            distanceKm: 10,
            canPackWh: 1250,
          ),
          _trip(
            id: 'b-1',
            endedAtUtcMillis: nowMillis - dayMillis - 1000,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaB,
            distanceKm: 10,
            canPackWh: 1800,
          ),
          _trip(
            id: 'b-2',
            endedAtUtcMillis: nowMillis - 2 * dayMillis - 1000,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaB,
            distanceKm: 10,
            canPackWh: 1750,
          ),
        ];

        final index = InsightRouteIndex.build(corpus, places);
        final selection = primaryInsight(
          subject: subject,
          corpus: corpus,
          index: index,
          now: now,
        );

        // Primary is route variant
        expect(selection.primary.hasInsight, isTrue);
        expect(
          selection.primary.insight!.baseline,
          InsightBaseline.otherVariantSameRoute,
        );
        expect(selection.primary.insight!.claim, InsightClaim.variantVsVariant);

        // Secondary / discarded is own average
        expect(selection.secondary, isNotNull);
        expect(selection.secondary!.support.window, kInsightOwnAverageWindow);
      },
    );

    test(
      'when route has multiple variants but insufficient support, chooses variant insufficientSupport as primary',
      () {
        final subject = _trip(
          id: 'subject',
          endedAtUtcMillis: nowMillis - dayMillis,
          startLatitude: -23.5505,
          startLongitude: -46.6333,
          endLatitude: -23.5600,
          endLongitude: -46.6500,
          path: viaA,
          distanceKm: 10,
          canPackWh: 1200,
        );

        // Only 1 trip on viaB, so variant comparison has insufficientSupport
        final corpus = [
          subject,
          _trip(
            id: 'b-1',
            endedAtUtcMillis: nowMillis - dayMillis - 1000,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaB,
            distanceKm: 10,
            canPackWh: 1800,
          ),
          _trip(
            id: 'ref-1',
            endedAtUtcMillis: nowMillis - 2 * dayMillis,
            distanceKm: 10,
            canPackWh: 1500,
          ),
          _trip(
            id: 'ref-2',
            endedAtUtcMillis: nowMillis - 3 * dayMillis,
            distanceKm: 10,
            canPackWh: 1500,
          ),
          _trip(
            id: 'ref-3',
            endedAtUtcMillis: nowMillis - 4 * dayMillis,
            distanceKm: 10,
            canPackWh: 1500,
          ),
        ];

        final index = InsightRouteIndex.build(corpus, places);
        final selection = primaryInsight(
          subject: subject,
          corpus: corpus,
          index: index,
          now: now,
        );

        // Primary is variant with insufficientSupport
        expect(selection.primary.hasInsight, isFalse);
        expect(selection.primary.absence, InsightAbsence.insufficientSupport);
        expect(selection.primary.support.window, kInsightRouteWindow);

        // Secondary / discarded is own average
        expect(selection.secondary, isNotNull);
        expect(selection.secondary!.support.window, kInsightOwnAverageWindow);
      },
    );

    test('when subject is unusable, primary reflects subject gate failure', () {
      final subject = _trip(
        id: 'subject',
        endedAtUtcMillis: nowMillis - dayMillis,
        distanceKm: 0.2, // Below kInsightDistanceFloorKm => subjectTooShort
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        endLatitude: -23.5600,
        endLongitude: -46.6500,
        path: viaA,
      );

      final index = InsightRouteIndex.build([subject], places);
      final selection = primaryInsight(
        subject: subject,
        corpus: [subject],
        index: index,
        now: now,
      );

      expect(selection.primary.hasInsight, isFalse);
      expect(selection.primary.absence, InsightAbsence.subjectTooShort);
    });
  });

  group('consideredTripsForInsight', () {
    test('returns considered reference trips for ownAverage30d insight', () {
      final subject = _trip(
        id: 'subject',
        endedAtUtcMillis: nowMillis - dayMillis,
      );

      final ref1 = _trip(
        id: 'ref-1',
        endedAtUtcMillis: nowMillis - 2 * dayMillis,
        distanceKm: 10,
        canPackWh: 1600,
      );
      final ref2 = _trip(
        id: 'ref-2',
        endedAtUtcMillis: nowMillis - 3 * dayMillis,
        distanceKm: 10,
        canPackWh: 1550,
      );
      final ref3 = _trip(
        id: 'ref-3',
        endedAtUtcMillis: nowMillis - 4 * dayMillis,
        distanceKm: 10,
        canPackWh: 1500,
      );
      final ref4 = _trip(
        id: 'ref-4',
        endedAtUtcMillis: nowMillis - 5 * dayMillis,
        distanceKm: 10,
        canPackWh: 1450,
      );

      final corpus = [subject, ref1, ref2, ref3, ref4];

      final index = InsightRouteIndex.build(corpus, places);
      final selection = primaryInsight(
        subject: subject,
        corpus: corpus,
        index: index,
        now: now,
      );

      final considered = consideredTripsForInsight(
        read: selection.primary,
        subject: subject,
        corpus: corpus,
        index: index,
        now: now,
      );

      expect(considered.map((t) => t.id), ['ref-1', 'ref-2', 'ref-3', 'ref-4']);
    });

    test('returns considered reference trips for variantVsVariant insight', () {
      final subject = _trip(
        id: 'subject',
        endedAtUtcMillis: nowMillis - dayMillis,
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        endLatitude: -23.5600,
        endLongitude: -46.6500,
        path: viaA,
        canPackWh: 1500,
      );

      final other1 = _trip(
        id: 'other-1',
        endedAtUtcMillis: nowMillis - dayMillis - 3600000,
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        endLatitude: -23.5600,
        endLongitude: -46.6500,
        path: viaB,
        canPackWh: 1600,
      );

      final mine2 = _trip(
        id: 'mine-2',
        endedAtUtcMillis: nowMillis - 2 * dayMillis,
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        endLatitude: -23.5600,
        endLongitude: -46.6500,
        path: viaA,
        canPackWh: 1510,
      );

      final other2 = _trip(
        id: 'other-2',
        endedAtUtcMillis: nowMillis - 2 * dayMillis - 3600000,
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        endLatitude: -23.5600,
        endLongitude: -46.6500,
        path: viaB,
        canPackWh: 1610,
      );

      final corpus = [subject, other1, mine2, other2];

      final index = InsightRouteIndex.build(corpus, places);
      final selection = primaryInsight(
        subject: subject,
        corpus: corpus,
        index: index,
        now: now,
      );

      expect(selection.primary.insight?.claim, InsightClaim.variantVsVariant);

      final considered = consideredTripsForInsight(
        read: selection.primary,
        subject: subject,
        corpus: corpus,
        index: index,
        now: now,
      );

      expect(considered.length, 4);
    });
  });
}
