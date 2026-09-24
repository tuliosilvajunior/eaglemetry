import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('assembleInsightTrip', () {
    test('calculates net CAN pack energy: traction - regen + auxiliary', () {
      final trip = assembleInsightTrip(
        const InsightTripInputs(
          id: 'trip-1',
          rollupTractionWh: 900.0,
          rollupRegenWh: 100.0,
          rollupAuxiliaryWh: 12.5,
          socAgreesWithIntegral: 'agrees',
          hasMinuteBuckets: true,
          rollupDistanceKm: 7.25,
        ),
      );

      expect(trip.canPackWh, closeTo(812.5, 1e-9));
      expect(trip.canAgreesWithSoc, isTrue);
      expect(trip.aggregationVersion, 1);
      expect(trip.hasMinuteBuckets, isTrue);
      expect(trip.distanceKm, closeTo(7.25, 1e-9));
    });

    test(
      'null rollupTractionWh yields null canPackWh and aggregationVersion 0',
      () {
        final trip = assembleInsightTrip(
          const InsightTripInputs(
            id: 'trip-2',
            rollupTractionWh: null,
            rollupRegenWh: 100.0,
            rollupAuxiliaryWh: 12.5,
            startOdometerKm: 10.0,
            endOdometerKm: 20.0,
          ),
        );

        expect(trip.canPackWh, isNull);
        expect(trip.aggregationVersion, 0);
        expect(trip.distanceKm, closeTo(10.0, 1e-9));
      },
    );

    test('translates socAgreesWithIntegral to canAgreesWithSoc states', () {
      expect(
        assembleInsightTrip(
          const InsightTripInputs(
            id: 't-agrees',
            socAgreesWithIntegral: 'agrees',
          ),
        ).canAgreesWithSoc,
        isTrue,
      );

      expect(
        assembleInsightTrip(
          const InsightTripInputs(
            id: 't-contradicts',
            socAgreesWithIntegral: 'contradicts',
          ),
        ).canAgreesWithSoc,
        isFalse,
      );

      expect(
        assembleInsightTrip(
          const InsightTripInputs(
            id: 't-unconfirmed',
            socAgreesWithIntegral: 'unconfirmed',
          ),
        ).canAgreesWithSoc,
        isNull,
      );

      expect(
        assembleInsightTrip(
          const InsightTripInputs(id: 't-null', socAgreesWithIntegral: null),
        ).canAgreesWithSoc,
        isNull,
      );
    });

    test('distance prefers rollupDistanceKm then odometer delta', () {
      // 1. Rollup distance takes priority
      final trip1 = assembleInsightTrip(
        const InsightTripInputs(
          id: 't-1',
          rollupDistanceKm: 15.5,
          startOdometerKm: 100.0,
          endOdometerKm: 120.0,
        ),
      );
      expect(trip1.distanceKm, closeTo(15.5, 1e-9));

      // 2. Fallback to odometer delta
      final trip2 = assembleInsightTrip(
        const InsightTripInputs(
          id: 't-2',
          rollupDistanceKm: null,
          startOdometerKm: 100.0,
          endOdometerKm: 120.0,
        ),
      );
      expect(trip2.distanceKm, closeTo(20.0, 1e-9));

      // 3. Negative odometer step is refused
      final trip3 = assembleInsightTrip(
        const InsightTripInputs(
          id: 't-3',
          rollupDistanceKm: null,
          startOdometerKm: 120.0,
          endOdometerKm: 100.0,
        ),
      );
      expect(trip3.distanceKm, isNull);

      // 4. Missing both distances is null
      final trip4 = assembleInsightTrip(const InsightTripInputs(id: 't-4'));
      expect(trip4.distanceKm, isNull);
    });

    test('preserves geometry and metadata fields', () {
      final trip = assembleInsightTrip(
        const InsightTripInputs(
          id: 'trip-geo',
          endedAtUtcMillis: 1750000000000,
          hasMinuteBuckets: false,
          startLatitude: -23.55,
          startLongitude: -46.63,
          endLatitude: -23.56,
          endLongitude: -46.65,
          path: '-23.55,-46.63;-23.56,-46.65',
          meanAmbientTempC: 24.5,
        ),
      );

      expect(trip.id, 'trip-geo');
      expect(trip.endedAtUtcMillis, 1750000000000);
      expect(trip.hasMinuteBuckets, isFalse);
      expect(trip.startLatitude, closeTo(-23.55, 1e-9));
      expect(trip.startLongitude, closeTo(-46.63, 1e-9));
      expect(trip.endLatitude, closeTo(-23.56, 1e-9));
      expect(trip.endLongitude, closeTo(-46.65, 1e-9));
      expect(trip.path, '-23.55,-46.63;-23.56,-46.65');
      expect(trip.meanAmbientTempC, closeTo(24.5, 1e-9));
    });
  });

  group('InsightTripInputs.fromMap', () {
    test('parses raw session map correctly', () {
      final map = {
        'id': 'session-123',
        'endedAtUtcMillis': 1750000000000,
        'rollupDistanceKm': 12.3,
        'startOdometerKm': 1000.0,
        'endOdometerKm': 1012.3,
        'rollupTractionWh': 1500.0,
        'rollupRegenWh': 200.0,
        'rollupAuxiliaryWh': 50.0,
        'socAgreesWithIntegral': 'agrees',
        'hasMinuteBuckets': true,
        'startLatitude': -10.18,
        'startLongitude': -48.33,
        'endLatitude': -10.19,
        'endLongitude': -48.34,
        'path': '-10.18,-48.33;-10.19,-48.34',
        'meanAmbientTempC': 28.0,
      };

      final inputs = InsightTripInputs.fromMap(map);
      final trip = assembleInsightTrip(inputs);

      expect(trip.id, 'session-123');
      expect(trip.canPackWh, closeTo(1350.0, 1e-9));
      expect(trip.canAgreesWithSoc, isTrue);
      expect(trip.aggregationVersion, 1);
      expect(trip.hasMinuteBuckets, isTrue);
      expect(trip.distanceKm, closeTo(12.3, 1e-9));
      expect(trip.path, '-10.18,-48.33;-10.19,-48.34');
      expect(trip.meanAmbientTempC, closeTo(28.0, 1e-9));
    });

    test('falls back to startAmbientTempC when meanAmbientTempC is null', () {
      final map = {'id': 'session-temp', 'startAmbientTempC': 22.5};

      final inputs = InsightTripInputs.fromMap(map);
      expect(inputs.meanAmbientTempC, closeTo(22.5, 1e-9));
    });
  });
}
