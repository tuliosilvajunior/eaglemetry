import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/history_screen.dart';
import 'package:capy_companion/screens/trip_detail_screen.dart';
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

/// Runs real work under a fake clock.
///
/// Inside `testWidgets` the clock is fake, and the store is real: SQLite
/// answers off the test isolate, so anything awaited outside [runAsync] waits
/// for a tick that never comes. Every read and write of the archive goes
/// through here.
Future<T> _real<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

/// Lets the screen's own reads answer, then rebuilds with what they answered.
///
/// This is not a `pumpAndSettle`. Both screens draw a
/// `CircularProgressIndicator` while a read is open, and that animation
/// schedules a frame forever: a settle would run to its own ten-minute timeout
/// instead of to a ready screen.
Future<void> _readsLand(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
}

/// A trip row exactly as the car sends it.
///
/// It carries no `durationMillis`, because the car does not send one: the
/// stored row holds the endpoints and the duration is derived from them. A
/// fixture that stated it read as a passing test while every drive on the
/// phone showed `--`.
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
};

/// The same drive, with the rollup the car folded for it.
///
/// 8 100 - 1 520 + 550 = 7 130 Wh, which is the sum of the two minutes below.
/// The row states it because the car states it: the phone reduces, it does not
/// re-fold a hundred rows to draw a list.
const _tripWithRollup = {
  ..._trip,
  'rollupTractionWh': 8100.0,
  'rollupRegenWh': 1520.0,
  'rollupAuxiliaryWh': 550.0,
  'rollupDistanceKm': 42.0,
};

void main() {
  testWidgets('an empty archive says so, and does not read as a fault', (
    tester,
  ) async {
    final archive = await _real(tester, memoryArchive);
    await tester.pumpWidget(
      _host(
        HistoryScreen(
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          tab: HistoryTab.trips,
        ),
      ),
    );
    await _readsLand(tester);

    expect(find.text('Nothing here yet. Sync with the car.'), findsOneWidget);
  });

  testWidgets('each destination lists its own records', (tester) async {
    final archive = await _real(tester, memoryArchive);
    await _real(tester, () async {
      await archive.upsertTrip(_tripWithRollup);
      // The car's own minutes. The rollup above is their sum.
      // 4 000 - 900 + 300 = 3 400 Wh, then 3 730 Wh: 7.13 kWh in total.
      await archive.upsertInterval({
        'sessionId': 'trip-1',
        'startUtcMillis': 1750000000000,
        'tractionWh': 4000.0,
        'regeneratedWh': 900.0,
        'auxiliaryWh': 300.0,
      });
      await archive.upsertInterval({
        'sessionId': 'trip-1',
        'startUtcMillis': 1750000060000,
        'tractionWh': 4100.0,
        'regeneratedWh': 620.0,
        'auxiliaryWh': 250.0,
      });
      await archive.upsertCharge({
        'id': 'chg-1',
        'status': 'CLOSED',
        // As the car sends it: endpoints, no duration. The plug going in is
        // where the session starts, so it is `startedAt*` on the row.
        'startedAtUtcMillis': 1750100000000,
        'startedAtElapsedNanos': 9000000000,
        'startedAtBootCount': 5,
        'plugDisconnectedAtUtcMillis': 1750107200000,
        'plugDisconnectedAtElapsedNanos': 7209000000000,
        'plugDisconnectedAtBootCount': 5,
        'startSocPercent': 40,
        'endSocPercent': 80,
        'rollupDeliveredWh': 15500.0,
      });
    });

    await tester.pumpWidget(
      _host(
        HistoryScreen(
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          tab: HistoryTab.trips,
        ),
      ),
    );
    await _readsLand(tester);

    // 42 km, distance and energy derived from rollup.
    expect(find.byType(DaySectionHeader), findsOneWidget);
    expect(find.byType(TripSessionCard), findsOneWidget);
    expect(find.text('42.0'), findsOneWidget);
    expect(find.text('7.13'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        // Its own key: the shell builds one screen per destination and never
        // moves a mounted one to another tab, so this must be a second screen
        // rather than the first one handed a new argument.
        HistoryScreen(
          key: const ValueKey('charges'),
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          tab: HistoryTab.charges,
        ),
      ),
    );
    await _readsLand(tester);
    expect(find.textContaining('2 h 0 min'), findsOneWidget);
    expect(find.textContaining('15.50 kWh'), findsOneWidget);
    expect(find.textContaining('40 → 80%'), findsOneWidget);
  });

  testWidgets('a drive with no intervals shows no energy, and no zero', (
    tester,
  ) async {
    final archive = await _real(tester, memoryArchive);
    await _real(tester, () async {
      await archive.upsertTrip(_trip);
    });

    await tester.pumpWidget(
      _host(
        HistoryScreen(
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          tab: HistoryTab.trips,
        ),
      ),
    );
    await _readsLand(tester);

    // The card is still there and displays placeholders for missing energy.
    expect(find.byType(TripSessionCard), findsOneWidget);
    expect(find.text('--'), findsWidgets);
  });

  testWidgets('a drive with no fix says so instead of drawing an empty map', (
    tester,
  ) async {
    final archive = await _real(tester, memoryArchive);
    await _real(tester, () async {
      await archive.upsertTrip({..._trip, 'endSocPercent': 70});
    });

    await tester.pumpWidget(
      _host(
        HistoryScreen(
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          tab: HistoryTab.trips,
        ),
      ),
    );
    await _readsLand(tester);

    await tester.tap(find.byType(TripSessionCard));
    // The route transition, by hand: a settle would wait on the detail's own
    // spinner, which never stops on its own.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _readsLand(tester);

    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(find.text('This drive carries no position fix.'), findsOneWidget);
  });
}
