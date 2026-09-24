import 'package:capy_companion/abrp/abrp_settings_store.dart';
import 'package:capy_companion/auth/account_gateway.dart';
import 'package:capy_companion/auth/auth_controller.dart';
import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/settings_screen.dart';
import 'package:capy_companion/settings/companion_theme_controller.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/fake_account_gateway.dart';
import 'support/memory_archive.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Future<CompanionArchive> _archive(WidgetTester tester) async {
  late CompanionArchive archive;
  await tester.runAsync(() async => archive = await memoryArchive());
  return archive;
}

void main() {
  testWidgets('choosing a theme stores it and queues it for the car', (
    tester,
  ) async {
    final archive = await _archive(tester);
    final theme = CompanionThemeController(archive);

    await tester.pumpWidget(_host(SettingsScreen(theme: theme)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-appearance')), findsOneWidget);

    await tester.runAsync(() => theme.select(AppThemeId.midnight));
    await tester.pumpAndSettle();

    expect(theme.themeId, AppThemeId.midnight);
    // The mode is not a second choice: it is the chosen theme's brightness.
    expect(theme.themeMode, ThemeMode.dark);

    late List<Map<String, Object?>> stored;
    late List<({int id, String stream, Map<String, Object?> row})> queued;
    await tester.runAsync(() async {
      stored = await archive.database.allPreferences();
      queued = await archive.database.pendingAnnotationPush();
    });

    final row = stored.singleWhere((r) => r['key'] == 'theme_id');
    expect(row['scope'], kPreferenceScopeAccount);
    expect(row['value'], 'midnight');
    expect(row['origin'], kAnnotationOriginPhone);

    // The car learns about it by the channel the annotations already use.
    expect(queued, hasLength(1));
    expect(queued.single.stream, SyncStreamType.preferences.name);
  });

  testWidgets('a stored theme is what the app opens with', (tester) async {
    final archive = await _archive(tester);
    await tester.runAsync(
      () => archive.upsertPreference({
        'scope': kPreferenceScopeAccount,
        'key': 'theme_id',
        'value': 'sepia',
        'updatedAtUtcMillis': 10,
        'origin': kAnnotationOriginCar,
      }),
    );

    final theme = CompanionThemeController(archive);
    await tester.runAsync(theme.load);

    expect(theme.themeId, AppThemeId.sepia);
    expect(theme.themeMode, ThemeMode.light);
  });

  testWidgets('a theme this build does not know keeps the stored value', (
    tester,
  ) async {
    final archive = await _archive(tester);
    final theme = CompanionThemeController(archive);
    theme.applyStoredValue('a_theme_from_a_later_build');
    expect(theme.themeId, AppThemeId.light);
  });

  testWidgets('the account card signs the reader out', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    final gateway = FakeAccountGateway(
      existing: const AccountSession(
        email: 'reader@example.com',
        confirmed: true,
      ),
    );
    final auth = AuthController(gateway)..restore();
    final archive = await _archive(tester);

    await tester.pumpWidget(
      _host(
        SettingsScreen(theme: CompanionThemeController(archive), auth: auth),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Signed in as reader@example.com', skipOffstage: false),
      findsOneWidget,
    );

    // The nine theme tiles sit above it, so on a test viewport the account
    // card starts below the fold.
    await tester.ensureVisible(find.byKey(const Key('settings-sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(auth.isSignedIn, isFalse);
    expect(
      find.text('No account is signed in on this phone.', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('a build with no account server offers no sign-out', (
    tester,
  ) async {
    final archive = await _archive(tester);
    await tester.pumpWidget(
      _host(SettingsScreen(theme: CompanionThemeController(archive))),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings-account'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-sign-out')), findsNothing);
  });

  testWidgets('the abrp card toggles forwarding and updates token', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    final archive = await _archive(tester);
    final abrpStore = FileAbrpSettingsStore(enabled: false, userToken: null);

    await tester.pumpWidget(
      _host(
        SettingsScreen(
          theme: CompanionThemeController(archive),
          abrpSettings: abrpStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings-beta'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-abrp-token-input')), findsNothing);

    // Ensure toggle is visible and toggle switch ON
    await tester.ensureVisible(find.byKey(const Key('settings-abrp-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-abrp-toggle')));
    await tester.pumpAndSettle();

    expect(abrpStore.enabled, isTrue);
    expect(find.byKey(const Key('settings-abrp-token-input')), findsOneWidget);

    // Enter token
    await tester.ensureVisible(
      find.byKey(const Key('settings-abrp-token-input')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-abrp-token-input')),
      'abrp-test-token-123',
    );
    await tester.pumpAndSettle();

    expect(abrpStore.userToken, 'abrp-test-token-123');

    // The api key is required: the app carries no key of its own.
    await tester.ensureVisible(
      find.byKey(const Key('settings-abrp-api-key-input')),
    );
    await tester.pumpAndSettle();
    expect(abrpStore.apiKey, isNull);
    await tester.enterText(
      find.byKey(const Key('settings-abrp-api-key-input')),
      'abrp-own-api-key-456',
    );
    await tester.pumpAndSettle();

    expect(abrpStore.apiKey, 'abrp-own-api-key-456');
  });

  testWidgets(
    'the ABRP info button explains where both credentials come from',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      final archive = await _archive(tester);
      final abrpStore = FileAbrpSettingsStore(enabled: false, userToken: null);

      await tester.pumpWidget(
        _host(
          SettingsScreen(
            theme: CompanionThemeController(archive),
            abrpSettings: abrpStore,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('settings-abrp-info')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-abrp-info')));
      await tester.pumpAndSettle();

      expect(find.text('How to connect ABRP'), findsOneWidget);
      expect(find.text('API key'), findsOneWidget);
      expect(find.text('User token'), findsOneWidget);
      expect(
        find.textContaining(
          'https://abetterrouteplanner.com/home/app/api-keys/telemetry',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Copy Token'), findsOneWidget);
    },
  );
}
