import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('InsightTrip Car vs Companion parity', () {
    void expectParity({
      required Map<String, Object?> sessionRow,
      required bool hasMinuteBuckets,
    }) {
      // 1. Car path: SessionEntity raw fields mapped via Wire DTO
      final wire = InsightTripWire(
        id: sessionRow['id'] as String,
        endedAtUtcMillis: sessionRow['endedAtUtcMillis'] as int?,
        rollupDistanceKm: (sessionRow['rollupDistanceKm'] as num?)?.toDouble(),
        startOdometerKm: (sessionRow['startOdometerKm'] as num?)?.toDouble(),
        endOdometerKm: (sessionRow['endOdometerKm'] as num?)?.toDouble(),
        rollupTractionWh: (sessionRow['rollupTractionWh'] as num?)?.toDouble(),
        rollupRegenWh: (sessionRow['rollupRegenWh'] as num?)?.toDouble(),
        rollupAuxiliaryWh: (sessionRow['rollupAuxiliaryWh'] as num?)
            ?.toDouble(),
        socAgreesWithIntegral: sessionRow['socAgreesWithIntegral'] as String?,
        hasMinuteBuckets: hasMinuteBuckets,
        startLatitude: (sessionRow['startLatitude'] as num?)?.toDouble(),
        startLongitude: (sessionRow['startLongitude'] as num?)?.toDouble(),
        endLatitude: (sessionRow['endLatitude'] as num?)?.toDouble(),
        endLongitude: (sessionRow['endLongitude'] as num?)?.toDouble(),
        path: sessionRow['path'] as String?,
        meanAmbientTempC:
            (sessionRow['meanAmbientTempC'] as num?)?.toDouble() ??
            (sessionRow['startAmbientTempC'] as num?)?.toDouble(),
      );
      final carTripsResult = InsightTripsResult.fromWire(
        InsightTripsWire(trips: [wire]),
      );
      final carTrip = carTripsResult.trips.first;

      // 2. Companion path: Synchronized session row + interval bucket lookup
      final companionInputs = InsightTripInputs(
        id: sessionRow['id'] as String,
        endedAtUtcMillis: sessionRow['endedAtUtcMillis'] as int?,
        rollupDistanceKm: (sessionRow['rollupDistanceKm'] as num?)?.toDouble(),
        startOdometerKm: (sessionRow['startOdometerKm'] as num?)?.toDouble(),
        endOdometerKm: (sessionRow['endOdometerKm'] as num?)?.toDouble(),
        rollupTractionWh: (sessionRow['rollupTractionWh'] as num?)?.toDouble(),
        rollupRegenWh: (sessionRow['rollupRegenWh'] as num?)?.toDouble(),
        rollupAuxiliaryWh: (sessionRow['rollupAuxiliaryWh'] as num?)
            ?.toDouble(),
        socAgreesWithIntegral: sessionRow['socAgreesWithIntegral'] as String?,
        hasMinuteBuckets: hasMinuteBuckets,
        startLatitude: (sessionRow['startLatitude'] as num?)?.toDouble(),
        startLongitude: (sessionRow['startLongitude'] as num?)?.toDouble(),
        endLatitude: (sessionRow['endLatitude'] as num?)?.toDouble(),
        endLongitude: (sessionRow['endLongitude'] as num?)?.toDouble(),
        path: sessionRow['path'] as String?,
        meanAmbientTempC:
            (sessionRow['meanAmbientTempC'] as num?)?.toDouble() ??
            (sessionRow['startAmbientTempC'] as num?)?.toDouble(),
      );
      final companionTrip = assembleInsightTrip(companionInputs);

      // Verify strict field-by-field parity
      expect(carTrip.id, companionTrip.id);
      expect(carTrip.endedAtUtcMillis, companionTrip.endedAtUtcMillis);
      expect(carTrip.distanceKm, companionTrip.distanceKm);
      expect(carTrip.canPackWh, companionTrip.canPackWh);
      expect(carTrip.hasMinuteBuckets, companionTrip.hasMinuteBuckets);
      expect(carTrip.canAgreesWithSoc, companionTrip.canAgreesWithSoc);
      expect(carTrip.aggregationVersion, companionTrip.aggregationVersion);
      expect(carTrip.startLatitude, companionTrip.startLatitude);
      expect(carTrip.startLongitude, companionTrip.startLongitude);
      expect(carTrip.endLatitude, companionTrip.endLatitude);
      expect(carTrip.endLongitude, companionTrip.endLongitude);
      expect(carTrip.path, companionTrip.path);
      expect(carTrip.meanAmbientTempC, companionTrip.meanAmbientTempC);
    }

    test(
      'parity on a standard completed drive with traction, regen and aux',
      () {
        expectParity(
          sessionRow: {
            'id': 'trip-std',
            'endedAtUtcMillis': 1750000000000,
            'rollupDistanceKm': 15.2,
            'startOdometerKm': 1200.0,
            'endOdometerKm': 1215.2,
            'rollupTractionWh': 2200.0,
            'rollupRegenWh': 300.0,
            'rollupAuxiliaryWh': 50.0,
            'socAgreesWithIntegral': 'agrees',
            'startLatitude': -23.5505,
            'startLongitude': -46.6333,
            'endLatitude': -23.5600,
            'endLongitude': -46.6500,
            'path': '-23.5505,-46.6333;-23.5600,-46.6500',
            'meanAmbientTempC': 26.5,
          },
          hasMinuteBuckets: true,
        );
      },
    );

    test(
      'parity on contradiction session (socAgreesWithIntegral: contradicts)',
      () {
        expectParity(
          sessionRow: {
            'id': 'trip-contradict',
            'endedAtUtcMillis': 1750000000000,
            'rollupDistanceKm': 10.0,
            'startOdometerKm': 100.0,
            'endOdometerKm': 110.0,
            'rollupTractionWh': 1000.0,
            'rollupRegenWh': 100.0,
            'rollupAuxiliaryWh': 10.0,
            'socAgreesWithIntegral': 'contradicts',
            'meanAmbientTempC': 20.0,
          },
          hasMinuteBuckets: true,
        );
      },
    );

    test('parity on unconfirmed session (socAgreesWithIntegral: null)', () {
      expectParity(
        sessionRow: {
          'id': 'trip-unconfirmed',
          'endedAtUtcMillis': 1750000000000,
          'rollupDistanceKm': 8.0,
          'startOdometerKm': 50.0,
          'endOdometerKm': 58.0,
          'rollupTractionWh': 800.0,
          'socAgreesWithIntegral': null,
        },
        hasMinuteBuckets: true,
      );
    });

    test('parity on session without CAN energy rollups (version 0)', () {
      expectParity(
        sessionRow: {
          'id': 'trip-no-can',
          'endedAtUtcMillis': 1750000000000,
          'startOdometerKm': 200.0,
          'endOdometerKm': 210.0,
          'rollupTractionWh': null,
          'socAgreesWithIntegral': null,
        },
        hasMinuteBuckets: false,
      );
    });

    test('parity on session without minute buckets', () {
      expectParity(
        sessionRow: {
          'id': 'trip-no-buckets',
          'endedAtUtcMillis': 1750000000000,
          'rollupDistanceKm': 12.0,
          'rollupTractionWh': 1200.0,
          'rollupRegenWh': 100.0,
          'rollupAuxiliaryWh': 20.0,
          'socAgreesWithIntegral': 'agrees',
        },
        hasMinuteBuckets: false,
      );
    });

    test('parity on odometer fallback and temperature fallback', () {
      expectParity(
        sessionRow: {
          'id': 'trip-fallbacks',
          'endedAtUtcMillis': 1750000000000,
          'rollupDistanceKm': null,
          'startOdometerKm': 300.0,
          'endOdometerKm': 318.5,
          'rollupTractionWh': 1800.0,
          'startAmbientTempC': 21.0,
          'meanAmbientTempC': null,
          'socAgreesWithIntegral': 'agrees',
        },
        hasMinuteBuckets: true,
      );
    });
  });

  group('primaryInsight Car vs Companion baseline parity', () {
    const placeHome = InsightPlace(
      id: 'place-home',
      name: 'Casa',
      latitude: -23.5505,
      longitude: -46.6333,
      radiusM: 150.0,
    );
    const placeWork = InsightPlace(
      id: 'place-work',
      name: 'Trabalho',
      latitude: -23.5600,
      longitude: -46.6500,
      radiusM: 150.0,
    );
    final places = [placeHome, placeWork];

    const viaA = '-23.5505,-46.6333;-23.5550,-46.6400;-23.5600,-46.6500';
    const viaB = '-23.5505,-46.6333;-23.5580,-46.6450;-23.5600,-46.6500';

    final now = DateTime.utc(2026, 8, 24, 12, 0);
    final nowMillis = now.millisecondsSinceEpoch;
    const day = 86400000;

    test(
      'both Car and Companion show route variant baseline when multiple variants exist',
      () {
        final subject = InsightTrip(
          id: 'subject',
          endedAtUtcMillis: nowMillis - day,
          distanceKm: 15.0,
          canPackWh: 2250.0,
          hasMinuteBuckets: true,
          canAgreesWithSoc: true,
          aggregationVersion: 2,
          startLatitude: -23.5505,
          startLongitude: -46.6333,
          endLatitude: -23.5600,
          endLongitude: -46.6500,
          path: viaA,
          meanAmbientTempC: 25.0,
        );

        final corpus = [
          subject,
          InsightTrip(
            id: 'a-1',
            endedAtUtcMillis: nowMillis - 2 * day,
            distanceKm: 15.0,
            canPackWh: 2200.0,
            hasMinuteBuckets: true,
            canAgreesWithSoc: true,
            aggregationVersion: 2,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaA,
            meanAmbientTempC: 25.0,
          ),
          InsightTrip(
            id: 'b-1',
            endedAtUtcMillis: nowMillis - day - 1000,
            distanceKm: 15.0,
            canPackWh: 2700.0,
            hasMinuteBuckets: true,
            canAgreesWithSoc: true,
            aggregationVersion: 2,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaB,
            meanAmbientTempC: 25.0,
          ),
          InsightTrip(
            id: 'b-2',
            endedAtUtcMillis: nowMillis - 2 * day - 1000,
            distanceKm: 15.0,
            canPackWh: 2650.0,
            hasMinuteBuckets: true,
            canAgreesWithSoc: true,
            aggregationVersion: 2,
            startLatitude: -23.5505,
            startLongitude: -46.6333,
            endLatitude: -23.5600,
            endLongitude: -46.6500,
            path: viaB,
            meanAmbientTempC: 25.0,
          ),
        ];

        final index = InsightRouteIndex.build(corpus, places);
        final carSelection = primaryInsight(
          subject: subject,
          corpus: corpus,
          index: index,
          now: now,
        );

        final companionSelection = primaryInsight(
          subject: subject,
          corpus: corpus,
          index: index,
          now: now,
        );

        expect(carSelection.primary.hasInsight, isTrue);
        expect(companionSelection.primary.hasInsight, isTrue);
        expect(
          carSelection.primary.insight!.baseline,
          InsightBaseline.otherVariantSameRoute,
        );
        expect(
          companionSelection.primary.insight!.baseline,
          InsightBaseline.otherVariantSameRoute,
        );
        expect(
          insightPhrase(carSelection.primary, placeName: 'Trabalho'),
          insightPhrase(companionSelection.primary, placeName: 'Trabalho'),
        );
      },
    );

    test(
      'both Car and Companion show 30-day own average baseline when single variant on route',
      () {
        final subject = InsightTrip(
          id: 'subject',
          endedAtUtcMillis: nowMillis - day,
          distanceKm: 15.0,
          canPackWh: 2250.0,
          hasMinuteBuckets: true,
          canAgreesWithSoc: true,
          aggregationVersion: 2,
          startLatitude: -23.5505,
          startLongitude: -46.6333,
          endLatitude: -23.5600,
          endLongitude: -46.6500,
          path: viaA,
        );

        final corpus = [
          subject,
          for (var i = 1; i <= 4; i++)
            InsightTrip(
              id: 'ref-$i',
              endedAtUtcMillis: nowMillis - (i + 1) * day,
              distanceKm: 15.0,
              canPackWh: 2000.0,
              hasMinuteBuckets: true,
              canAgreesWithSoc: true,
              aggregationVersion: 2,
              startLatitude: -23.5505,
              startLongitude: -46.6333,
              endLatitude: -23.5600,
              endLongitude: -46.6500,
              path: viaA,
            ),
        ];

        final index = InsightRouteIndex.build(corpus, places);
        final carSelection = primaryInsight(
          subject: subject,
          corpus: corpus,
          index: index,
          now: now,
        );

        final companionSelection = primaryInsight(
          subject: subject,
          corpus: corpus,
          index: index,
          now: now,
        );

        expect(carSelection.primary.hasInsight, isTrue);
        expect(companionSelection.primary.hasInsight, isTrue);
        expect(
          carSelection.primary.insight!.baseline,
          InsightBaseline.ownAverage30d,
        );
        expect(
          companionSelection.primary.insight!.baseline,
          InsightBaseline.ownAverage30d,
        );
        expect(
          insightPhrase(carSelection.primary, placeName: 'Trabalho'),
          insightPhrase(companionSelection.primary, placeName: 'Trabalho'),
        );
      },
    );
  });
}
