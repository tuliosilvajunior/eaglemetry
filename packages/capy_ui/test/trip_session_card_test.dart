import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  final session = SessionRecord(
    id: 'test-trip-1',
    vehicleId: 'vehicle-1',
    kind: SessionKind.trip,
    status: 'CLOSED',
    startedAtUtcMillis: 1750000000000,
    startedAtElapsedNanos: 0,
    endedAtUtcMillis: 1750001800000,
    endedAtElapsedNanos: 1800000 * 1000000,
    durationMillis: 1800000,
    rollup: const SessionRollup(
      distance: Measurement.measured(12.5, unit: 'km'),
      traction: Measurement.measured(2000.0, unit: 'Wh'),
      regen: Measurement.measured(400.0, unit: 'Wh'),
      auxiliary: Measurement.measured(200.0, unit: 'Wh'),
      climate: Measurement.unreported(unit: 'Wh'),
      delivered: Measurement.unreported(unit: 'Wh'),
      integratedSeconds: Measurement.measured(1800.0, unit: 's'),
    ),
    startOdometer: const Measurement.measured(1000.0, unit: 'km'),
    endOdometer: const Measurement.measured(1012.5, unit: 'km'),
    startSoc: const Measurement.measured(80.0, unit: '%'),
    endSoc: const Measurement.measured(75.0, unit: '%'),
    minSoc: const Measurement.measured(75.0, unit: '%'),
    maxSoc: const Measurement.measured(80.0, unit: '%'),
    startAmbientTemp: const Measurement.measured(22.0, unit: '°C'),
    endAmbientTemp: const Measurement.measured(23.0, unit: '°C'),
    meanAmbientTemp: const Measurement.measured(22.5, unit: '°C'),
    startLatitude: -23.5505,
    startLongitude: -46.6333,
    createdAtUtcMillis: 1750000000000,
    updatedAtUtcMillis: 1750001800000,
  );

  final entry = TripSessionEntry(
    id: 'test-trip-1',
    startedAtUtcMillis: 1750000000000,
    endedAtUtcMillis: 1750001800000,
    durationMillis: 1800000,
    distanceKm: 12.5,
    netEnergyKwh: 1.8,
    avgSpeedKmh: 25.0,
    startPlace: 'Av. Paulista, 1000',
    endPlace: 'Shopping Cidade',
    startLatitude: -23.5505,
    startLongitude: -46.6333,
    endLatitude: -23.5615,
    endLongitude: -46.6559,
    routePoints: const [
      InsightPoint(-23.5505, -46.6333),
      InsightPoint(-23.5550, -46.6400),
      InsightPoint(-23.5615, -46.6559),
    ],
    session: session,
  );

  Widget buildHost({
    required Widget child,
    double width = 360,
    double height = 700,
  }) {
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );
  }

  group('TripSessionCard', () {
    testWidgets('renders compact mobile layout on narrow viewports', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        buildHost(
          width: 360,
          child: TripSessionCard(
            entry: entry,
            capabilities: SurfaceCapabilities.fromWidth(360),
            onTap: () => tapped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Av. Paulista, 1000'), findsOneWidget);
      expect(find.text('Shopping Cidade'), findsOneWidget);
      expect(find.text('12.5'), findsOneWidget);
      expect(find.text('1.80'), findsOneWidget);
      expect(find.text('25'), findsOneWidget);

      await tester.tap(find.byType(TripSessionCard));
      expect(tapped, isTrue);
    });

    testWidgets('renders expanded landscape layout on wide viewports', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildHost(
          width: 860,
          child: TripSessionCard(
            entry: entry,
            capabilities: SurfaceCapabilities.fromWidth(860),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Av. Paulista, 1000'), findsOneWidget);
      expect(find.text('Shopping Cidade'), findsOneWidget);
      expect(find.text('12.5'), findsOneWidget);
      expect(find.text('1.80'), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
      expect(find.text('30 min'), findsOneWidget);
    });

    testWidgets('handles trip with no route coordinates cleanly', (
      tester,
    ) async {
      final noGpsEntry = TripSessionEntry(
        id: 'no-gps-trip',
        startedAtUtcMillis: 1750000000000,
        endedAtUtcMillis: 1750001800000,
        durationMillis: 1800000,
        distanceKm: 5.0,
        netEnergyKwh: 0.8,
        avgSpeedKmh: 20.0,
        startPlace: 'Garagem',
        endPlace: 'Mercado',
        routePoints: const [],
        session: session,
      );

      await tester.pumpWidget(
        buildHost(
          width: 360,
          child: TripSessionCard(
            entry: noGpsEntry,
            capabilities: SurfaceCapabilities.fromWidth(360),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Garagem'), findsOneWidget);
      expect(find.text('Mercado'), findsOneWidget);
      expect(find.byIcon(Icons.map_outlined), findsOneWidget);
    });
  });
}
