import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  SessionRecord createSession({
    required String id,
    required int startedAtUtcMillis,
    required int endedAtUtcMillis,
    double distanceKm = 10.0,
    double tractionWh = 2000.0,
    double regenWh = 400.0,
    double startLat = -23.5505,
    double startLon = -46.6333,
  }) {
    return SessionRecord(
      id: id,
      vehicleId: 'test-car',
      kind: SessionKind.trip,
      status: 'CLOSED',
      startedAtUtcMillis: startedAtUtcMillis,
      startedAtElapsedNanos: 0,
      endedAtUtcMillis: endedAtUtcMillis,
      endedAtElapsedNanos: (endedAtUtcMillis - startedAtUtcMillis) * 1000000,
      durationMillis: endedAtUtcMillis - startedAtUtcMillis,
      rollup: SessionRollup(
        distance: Measurement.measured(distanceKm, unit: 'km'),
        traction: Measurement.measured(tractionWh, unit: 'Wh'),
        regen: Measurement.measured(regenWh, unit: 'Wh'),
        auxiliary: const Measurement.measured(100.0, unit: 'Wh'),
        climate: const Measurement.unreported(unit: 'Wh'),
        delivered: const Measurement.unreported(unit: 'Wh'),
        integratedSeconds: Measurement.measured(
          (endedAtUtcMillis - startedAtUtcMillis) / 1000.0,
          unit: 's',
        ),
      ),
      startOdometer: const Measurement.measured(1000.0, unit: 'km'),
      endOdometer: Measurement.measured(1000.0 + distanceKm, unit: 'km'),
      startSoc: const Measurement.measured(80.0, unit: '%'),
      endSoc: const Measurement.measured(75.0, unit: '%'),
      minSoc: const Measurement.measured(75.0, unit: '%'),
      maxSoc: const Measurement.measured(80.0, unit: '%'),
      startAmbientTemp: const Measurement.measured(22.0, unit: '°C'),
      endAmbientTemp: const Measurement.measured(23.0, unit: '°C'),
      meanAmbientTemp: const Measurement.measured(22.5, unit: '°C'),
      startLatitude: -23.5505,
      startLongitude: -46.6333,
      createdAtUtcMillis: startedAtUtcMillis,
      updatedAtUtcMillis: endedAtUtcMillis,
    );
  }

  final homePlace = const InsightPlace(
    id: 'place-home',
    name: 'Casa',
    latitude: -23.5505,
    longitude: -46.6333,
  );

  final workPlace = const InsightPlace(
    id: 'place-work',
    name: 'Trabalho',
    latitude: -23.5615,
    longitude: -46.6559,
  );

  Widget buildHost({
    required Widget child,
    double width = 360,
    double height = 700,
  }) {
    return MaterialApp(
      locale: const Locale('pt', 'BR'),
      theme: AppTheme.light(),
      home: Scaffold(
        body: SizedBox(width: width, height: height, child: child),
      ),
    );
  }

  group('TripsBody', () {
    testWidgets('renders loading state', (tester) async {
      await tester.pumpWidget(
        buildHost(
          child: TripsBody(
            state: const Loadable.loading(),
            capabilities: SurfaceCapabilities.fromWidth(360),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('renders error state with retry button', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        buildHost(
          child: TripsBody(
            state: Loadable.failed(Exception('Network error')),
            capabilities: SurfaceCapabilities.fromWidth(360),
            onRetry: () => retried = true,
          ),
        ),
      );

      expect(find.textContaining('Network error'), findsOneWidget);
      await tester.tap(find.text('Tentar novamente'));
      expect(retried, isTrue);
    });

    testWidgets('renders empty state when there are no trips', (tester) async {
      await tester.pumpWidget(
        buildHost(
          child: TripsBody(
            state: const Loadable.ready([]),
            capabilities: SurfaceCapabilities.fromWidth(360),
          ),
        ),
      );

      expect(find.text('Nenhuma viagem registrada'), findsOneWidget);
    });

    testWidgets('renders day groups with headers and trip cards', (
      tester,
    ) async {
      final now = DateTime.now();
      final todayStart = DateTime(
        now.year,
        now.month,
        now.day,
        10,
        0,
      ).millisecondsSinceEpoch;
      final yesterdayStart = DateTime(
        now.year,
        now.month,
        now.day - 1,
        15,
        0,
      ).millisecondsSinceEpoch;

      final s1 = createSession(
        id: 's1',
        startedAtUtcMillis: todayStart,
        endedAtUtcMillis: todayStart + 1800000,
        distanceKm: 12.0,
        tractionWh: 2000,
        regenWh: 400,
      );
      final s2 = createSession(
        id: 's2',
        startedAtUtcMillis: yesterdayStart,
        endedAtUtcMillis: yesterdayStart + 1800000,
        distanceKm: 8.0,
        tractionWh: 1500,
        regenWh: 300,
      );

      final e1 = assembleTripSessionEntry(
        session: s1,
        places: [homePlace, workPlace],
        endLatitude: -23.5615,
        endLongitude: -46.6559,
      );
      final e2 = assembleTripSessionEntry(
        session: s2,
        places: [homePlace, workPlace],
        endLatitude: -23.5505,
        endLongitude: -46.6333,
      );

      TripSessionEntry? selected;

      await tester.pumpWidget(
        buildHost(
          child: TripsBody(
            state: Loadable.ready([e1, e2]),
            capabilities: SurfaceCapabilities.fromWidth(360),
            onSelectTrip: (t) => selected = t,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hoje'), findsOneWidget);
      expect(find.text('Ontem'), findsOneWidget);
      expect(find.byType(TripSessionCard), findsNWidgets(2));

      await tester.tap(find.text('Casa').first);
      expect(selected?.id, 's1');
    });

    testWidgets('filters trips with search query', (tester) async {
      final now = DateTime.now();
      final t1 = now.millisecondsSinceEpoch;
      final s1 = createSession(
        id: 's1',
        startedAtUtcMillis: t1,
        endedAtUtcMillis: t1 + 1000,
      );
      final s2 = createSession(
        id: 's2',
        startedAtUtcMillis: t1 - 10000,
        endedAtUtcMillis: t1 - 9000,
        startLat: 0.0,
        startLon: 0.0,
      );

      final e1 = assembleTripSessionEntry(
        session: s1,
        places: [homePlace],
      ); // Casa
      final e2 = assembleTripSessionEntry(
        session: s2,
        places: [workPlace],
        endLatitude: -23.5615,
        endLongitude: -46.6559,
      ); // Trabalho

      await tester.pumpWidget(
        buildHost(
          child: TripsBody(
            state: Loadable.ready([e1, e2]),
            capabilities: SurfaceCapabilities.fromWidth(360),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TripSessionCard), findsNWidgets(2));

      // Enter search query
      await tester.enterText(find.byType(TextField), 'Casa');
      await tester.pumpAndSettle();

      expect(find.byType(TripSessionCard), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TripSessionCard),
          matching: find.text('Casa'),
        ),
        findsOneWidget,
      );
    });
  });
}
