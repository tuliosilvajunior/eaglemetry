import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/insights_screen.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SizedBox(width: 400, height: 800, child: child)),
);

Future<CompanionArchive> _archive(WidgetTester tester) async {
  late CompanionArchive archive;
  await tester.runAsync(() async => archive = await memoryArchive());
  return archive;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('shows empty state when no routes are matched', (tester) async {
    final archive = await _archive(tester);
    final store = SqfliteStore(archive.database);
    final source = LocalTelemetrySource(archive);

    await tester.pumpWidget(
      _host(InsightsScreen(store: store, source: source)),
    );
    await _settle(tester);

    expect(find.text('No routes yet'), findsOneWidget);
    expect(
      find.text(
        'Name the start and end places of your trips to group routes and see consumption statistics here.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('info button opens the explanation dialog', (tester) async {
    final archive = await _archive(tester);
    const now = 1750000000000;

    await tester.runAsync(() async {
      await archive.upsertPlace({
        'id': 'place-home',
        'name': 'Casa',
        'latitude': -23.5505,
        'longitude': -46.6333,
        'radiusM': 150.0,
        'createdAtUtcMillis': now,
        'updatedAtUtcMillis': now,
        'origin': 'phone',
      });
    });

    final store = SqfliteStore(archive.database);
    final source = LocalTelemetrySource(archive);

    await tester.pumpWidget(
      _host(InsightsScreen(store: store, source: source)),
    );
    await _settle(tester);

    await tester.tap(find.byType(InfoIconButton));
    await tester.pumpAndSettle();

    expect(find.text('How insights work'), findsOneWidget);
    expect(
      find.textContaining('A trip is measured when the car recorded'),
      findsOneWidget,
    );
    expect(find.text('Got it'), findsOneWidget);

    await tester.ensureVisible(find.text('Got it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('How insights work'), findsNothing);
  });

  testWidgets(
    'groups trips between named places and displays route cards with stats',
    (tester) async {
      final archive = await _archive(tester);
      const now = 1750000000000;

      await tester.runAsync(() async {
        // Upsert places
        await archive.upsertPlace({
          'id': 'place-home',
          'name': 'Casa',
          'latitude': -23.5505,
          'longitude': -46.6333,
          'radiusM': 150.0,
          'createdAtUtcMillis': now,
          'updatedAtUtcMillis': now,
          'origin': 'phone',
        });

        await archive.upsertPlace({
          'id': 'place-work',
          'name': 'Trabalho',
          'latitude': -23.5600,
          'longitude': -46.6500,
          'radiusM': 150.0,
          'createdAtUtcMillis': now,
          'updatedAtUtcMillis': now,
          'origin': 'phone',
        });

        // Trip 1: Casa -> Trabalho
        await archive.upsertTrip({
          'id': 'trip-1',
          'status': 'CLOSED',
          'startedAtUtcMillis': now,
          'endedAtUtcMillis': now + 1800000,
          'startedAtElapsedNanos': 1000000000,
          'endedAtElapsedNanos': 1801000000000,
          'startLatitude': -23.5505,
          'startLongitude': -46.6333,
          'endLatitude': -23.5600,
          'endLongitude': -46.6500,
          'rollupDistanceKm': 15.0,
          'rollupTractionWh': 2250.0,
        });

        // Trip 2: Casa -> Trabalho
        await archive.upsertTrip({
          'id': 'trip-2',
          'status': 'CLOSED',
          'startedAtUtcMillis': now + 86400000,
          'endedAtUtcMillis': now + 86400000 + 1800000,
          'startedAtElapsedNanos': 1000000000,
          'endedAtElapsedNanos': 1801000000000,
          'startLatitude': -23.5505,
          'startLongitude': -46.6333,
          'endLatitude': -23.5600,
          'endLongitude': -46.6500,
          'rollupDistanceKm': 15.0,
          'rollupTractionWh': 2100.0,
        });

        // Trip 3: Trabalho -> Casa
        await archive.upsertTrip({
          'id': 'trip-3',
          'status': 'CLOSED',
          'startedAtUtcMillis': now + 86400000 + 36000000,
          'endedAtUtcMillis': now + 86400000 + 37800000,
          'startedAtElapsedNanos': 1000000000,
          'endedAtElapsedNanos': 1801000000000,
          'startLatitude': -23.5600,
          'startLongitude': -46.6500,
          'endLatitude': -23.5505,
          'endLongitude': -46.6333,
          'rollupDistanceKm': 14.5,
          'rollupTractionWh': 2000.0,
        });
      });

      final store = SqfliteStore(archive.database);
      final source = LocalTelemetrySource(archive);

      await tester.pumpWidget(
        _host(InsightsScreen(store: store, source: source)),
      );
      await _settle(tester);

      // One group card for the pair, with both directions as tabs.
      expect(find.text('Casa ↔ Trabalho'), findsOneWidget);
      expect(find.text('Casa → Trabalho'), findsOneWidget);
      expect(find.text('Trabalho → Casa'), findsOneWidget);

      // Busiest direction (Casa -> Trabalho, 2 trips) leads the switch, and
      // neither direction has measured trips in this fixture.
      expect(find.text('0 of 2 trips measured'), findsOneWidget);

      // Switch to the other direction; its own counts appear.
      await tester.tap(find.text('Trabalho → Casa'));
      await tester.pump();
      expect(find.text('0 of 1 trips measured'), findsOneWidget);
    },
  );
}
