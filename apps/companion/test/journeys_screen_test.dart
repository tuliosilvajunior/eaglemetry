import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/journey_detail_screen.dart';
import 'package:capy_companion/screens/journeys_screen.dart';
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
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
}

const _trip1 = {
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
  testWidgets(
    'empty journeys screen displays empty state and allows creating journey',
    (tester) async {
      final archive = await _real(tester, memoryArchive);
      final store = SqfliteStore(archive.database);
      final source = LocalTelemetrySource(archive);
      final journeyStore = JourneyStore(archive);

      await tester.pumpWidget(
        _host(
          JourneysScreen(
            store: store,
            source: source,
            journeyStore: journeyStore,
          ),
        ),
      );
      await _readsLand(tester);

      expect(find.text('Journeys'), findsWidgets);
      expect(find.text('No journeys yet'), findsOneWidget);
      expect(find.text('New journey'), findsWidgets);
    },
  );

  testWidgets(
    'displays list of journeys with folded metrics and opens detail on tap',
    (tester) async {
      final archive = await _real(tester, memoryArchive);
      final store = SqfliteStore(archive.database);
      final source = LocalTelemetrySource(archive);
      final journeyStore = JourneyStore(archive);

      // Insert trip
      await _real(tester, () => archive.upsertTrip(_trip1));

      // Create journey covering this trip
      await _real(
        tester,
        () => journeyStore.create(
          name: 'Roadtrip to Coast',
          startedAtUtcMillis: 1749999000000,
          endedAtUtcMillis: 1750005000000,
          note: 'Sunny weekend drive',
        ),
      );

      await tester.pumpWidget(
        _host(
          JourneysScreen(
            store: store,
            source: source,
            journeyStore: journeyStore,
          ),
        ),
      );
      await _readsLand(tester);

      expect(find.text('Roadtrip to Coast'), findsOneWidget);
      expect(find.text('Sunny weekend drive'), findsOneWidget);
      expect(find.text('42.0 km'), findsOneWidget);
      expect(find.text('1 trips · 0 charges'), findsOneWidget);

      // Tap card to open detail
      await tester.tap(find.text('Roadtrip to Coast'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _readsLand(tester);

      expect(find.byType(JourneyDetailScreen), findsOneWidget);
    },
  );
}
