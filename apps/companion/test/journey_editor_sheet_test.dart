import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/journey_editor_sheet.dart';
import 'package:capy_companion/sync/journey_store.dart';
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

void main() {
  testWidgets('validates required name field and saves journey', (
    tester,
  ) async {
    final archive = await _real(tester, memoryArchive);
    final store = SqfliteStore(archive.database);
    final journeyStore = JourneyStore(archive);

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () => showJourneyEditorSheet(
                context: context,
                store: store,
                journeyStore: journeyStore,
              ),
              child: const Text('Open Editor'),
            );
          },
        ),
      ),
    );

    // Open sheet
    await tester.tap(find.text('Open Editor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _readsLand(tester);

    expect(find.text('New journey'), findsOneWidget);

    // Attempt save with empty name
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('Informe um nome para a jornada'), findsOneWidget);

    // Enter name and note
    await tester.enterText(find.byType(TextField).first, 'Family Weekend');
    await tester.enterText(
      find.byType(TextField).last,
      'Visiting grandparents',
    );
    await tester.pump();

    // Save
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await _readsLand(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final all = await _real(tester, journeyStore.journeys);
    expect(all.length, 1);
    expect(all.first.name, 'Family Weekend');
    expect(all.first.note, 'Visiting grandparents');
  });
}
