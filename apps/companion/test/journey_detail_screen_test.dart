import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/journey_detail_screen.dart';
import 'package:capy_companion/sync/journey_store.dart';
import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

Widget _host(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

Future<T> _real<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

Future<void> _readsLand(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
}

const _trip = {
  'id': 'trip-1',
  'kind': 'TRIP',
  'status': 'CLOSED',
  'startedAtUtcMillis': 1750000000000,
  'startedAtElapsedNanos': 5000000000,
  'startedAtBootCount': 4,
  'endedAtUtcMillis': 1750001800000,
  'endedAtElapsedNanos': 1805000000000,
  'endedAtBootCount': 4,
  'startSocPercent': 80,
  'endSocPercent': 62,
  'startOdometerKm': 1000,
  'endOdometerKm': 1042,
  'rollupTractionWh': 8100.0,
  'rollupRegenWh': 1520.0,
  'rollupAuxiliaryWh': 550.0,
  'rollupDistanceKm': 42.0,
};

void main() {
  testWidgets('displays journey metrics and member sessions', (tester) async {
    final archive = await _real(tester, memoryArchive);
    final store = SqfliteStore(archive.database);
    final source = LocalTelemetrySource(archive);
    final journeyStore = JourneyStore(archive);

    await _real(tester, () => archive.upsertTrip(_trip));

    final journey = await _real(
      tester,
      () => journeyStore.create(
        name: 'Summer Holiday',
        startedAtUtcMillis: 1749999000000,
        endedAtUtcMillis: 1750005000000,
        note: 'Trip to the beach',
      ),
    );

    await tester.pumpWidget(
      _host(
        JourneyDetailScreen(
          journey: journey,
          store: store,
          source: source,
          journeyStore: journeyStore,
        ),
      ),
    );
    await _readsLand(tester);

    expect(find.text('Summer Holiday'), findsOneWidget);
    expect(find.text('Trip to the beach'), findsOneWidget);
    expect(find.text('42.0'), findsWidgets);
    expect(
      find.text('Trips and charges in this journey', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('deleting journey confirms and marks tombstone', (tester) async {
    final archive = await _real(tester, memoryArchive);
    final store = SqfliteStore(archive.database);
    final source = LocalTelemetrySource(archive);
    final journeyStore = JourneyStore(archive);

    final journey = await _real(
      tester,
      () => journeyStore.create(
        name: 'Temporary Group',
        startedAtUtcMillis: 1749999000000,
        endedAtUtcMillis: 1750005000000,
      ),
    );

    await tester.pumpWidget(
      _host(
        JourneyDetailScreen(
          journey: journey,
          store: store,
          source: source,
          journeyStore: journeyStore,
        ),
      ),
    );
    await _readsLand(tester);

    // Tap delete icon
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Delete journey'), findsWidgets);

    // Confirm delete
    await tester.tap(find.text('Delete journey').last);
    await _readsLand(tester);

    final activeJourneys = await _real(tester, journeyStore.journeys);
    expect(activeJourneys, isEmpty);
  });

  testWidgets(
    'displays parked separator between consecutive sessions with gap >= 1 min',
    (tester) async {
      final archive = await _real(tester, memoryArchive);
      final store = SqfliteStore(archive.database);
      final source = LocalTelemetrySource(archive);
      final journeyStore = JourneyStore(archive);

      // Trip 1: 10:00 to 10:30 (1750000000000 to 1750001800000)
      await _real(tester, () => archive.upsertTrip(_trip));

      // Trip 2: 11:00 to 11:30 (1750003600000 to 1750005400000) -> 30 min gap after Trip 1
      final trip2 = Map<String, Object?>.from(_trip)
        ..['id'] = 'trip-2'
        ..['startedAtUtcMillis'] = 1750003600000
        ..['endedAtUtcMillis'] = 1750005400000;
      await _real(tester, () => archive.upsertTrip(trip2));

      final journey = await _real(
        tester,
        () => journeyStore.create(
          name: 'Road Trip with Stop',
          startedAtUtcMillis: 1749999000000,
          endedAtUtcMillis: 1750006000000,
        ),
      );

      await tester.pumpWidget(
        _host(
          JourneyDetailScreen(
            journey: journey,
            store: store,
            source: source,
            journeyStore: journeyStore,
          ),
        ),
      );
      await _readsLand(tester);

      // Expect to see the separator: "Parked for 30 min"
      expect(
        find.text('Parked for 30 min', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byIcon(Icons.local_parking_rounded, skipOffstage: false),
        findsOneWidget,
      );
    },
  );
}
