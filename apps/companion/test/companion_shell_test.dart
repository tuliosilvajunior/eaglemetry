import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/companion_shell.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:capy_companion/settings/companion_theme_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_device_pairing_gateway.dart';
import 'support/memory_archive.dart';

PairingController _pairing() => PairingController(
  store: PairingStore(),
  gateway: FakeDevicePairingGateway(),
);

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Future<CompanionArchive> _archive(WidgetTester tester) async {
  late CompanionArchive archive;
  await tester.runAsync(() async => archive = await memoryArchive());
  return archive;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'every destination has a pill, and none of them is empty chrome',
    (tester) async {
      final archive = await _archive(tester);
      await tester.pumpWidget(
        _host(
          CompanionShell(
            pairing: _pairing(),
            store: SqfliteStore(archive.database),
            source: LocalTelemetrySource(archive),
            theme: CompanionThemeController(archive),
          ),
        ),
      );
      await _settle(tester);

      for (final label in [
        'Trips',
        'Charges',
        'Journeys',
        'Insights',
        'Sync',
        'Settings',
      ]) {
        expect(find.text(label), findsWidgets, reason: 'no pill for $label');
      }

      // Battery has no screen yet, so it has no pill. A pill that opens a
      // line saying "coming soon" costs a tap to tell the reader nothing.
      expect(find.text('Battery'), findsNothing);
    },
  );

  testWidgets('an unpaired phone opens on sync, not on an empty trip list', (
    tester,
  ) async {
    final archive = await _archive(tester);
    final pairing = _pairing();
    await tester.pumpWidget(
      _host(
        CompanionShell(
          pairing: pairing,
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          theme: CompanionThemeController(archive),
        ),
      ),
    );
    await _settle(tester);

    expect(pairing.isPaired, isFalse);
    expect(
      find.byKey(const Key('pairing-code-field'), skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('the pill row is a strip, and the body keeps the screen', (
    tester,
  ) async {
    final archive = await _archive(tester);
    await tester.pumpWidget(
      _host(
        CompanionShell(
          pairing: _pairing(),
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          theme: CompanionThemeController(archive),
        ),
      ),
    );
    await _settle(tester);

    // A horizontal scroll view is unbounded across its scroll axis. Left
    // unstated, the pill row grew to the whole screen and nothing else was
    // visible, which no `find` in this file could see.
    final screen = tester.getSize(find.byType(CompanionShell)).height;
    final bar = tester.getSize(find.byType(PillTabBar<CompanionTab>)).height;
    expect(bar, lessThan(screen / 4));
  });

  testWidgets('tapping a pill rolls the body to that destination', (
    tester,
  ) async {
    final archive = await _archive(tester);
    await tester.pumpWidget(
      _host(
        CompanionShell(
          pairing: _pairing(),
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          theme: CompanionThemeController(archive),
        ),
      ),
    );
    await _settle(tester);

    expect(find.byKey(const Key('settings-appearance')), findsNothing);

    await tester.ensureVisible(find.text('Settings').first);
    await tester.tap(find.text('Settings').first);
    await _settle(tester);

    // Settings is the last destination, so landing on it also proves the
    // roll counted the visible pills rather than the enum's ordinals: with
    // Battery still counted, this tap would stop one page short.
    expect(find.byKey(const Key('settings-appearance')), findsOneWidget);
  });

  testWidgets('tapping Journeys pill rolls to the Journeys destination', (
    tester,
  ) async {
    final archive = await _archive(tester);
    await tester.pumpWidget(
      _host(
        CompanionShell(
          pairing: _pairing(),
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          theme: CompanionThemeController(archive),
        ),
      ),
    );
    await _settle(tester);

    final pill = find.descendant(
      of: find.byType(PillTabBar<CompanionTab>),
      matching: find.text('Journeys'),
    );
    await tester.ensureVisible(pill);
    await tester.tap(pill);
    await _settle(tester);

    expect(find.text('No journeys yet'), findsOneWidget);
  });

  testWidgets('tapping Insights pill rolls to the Insights destination', (
    tester,
  ) async {
    final archive = await _archive(tester);
    await tester.pumpWidget(
      _host(
        CompanionShell(
          pairing: _pairing(),
          store: SqfliteStore(archive.database),
          source: LocalTelemetrySource(archive),
          theme: CompanionThemeController(archive),
        ),
      ),
    );
    await _settle(tester);

    await tester.ensureVisible(find.text('Insights').first);
    await tester.tap(find.text('Insights').first);
    await _settle(tester);

    expect(find.text('No routes yet'), findsOneWidget);
  });
}
