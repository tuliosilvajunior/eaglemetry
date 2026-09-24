import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:capy_energy/core/app_experience_controller.dart';
import 'package:capy_energy/core/carplay_api.dart';
import 'package:capy_energy/core/theme_controller.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/main.dart';
import 'package:capy_energy/screens_v2/app_shell_v2.dart';
import 'package:capy_energy/screens_v2/carplay_home_v2_screen.dart';
import 'package:capy_energy/screens_v2/carplay_v2_screen.dart';
import 'package:capy_energy/screens_v2/charging/charging_v2_screen.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    // Without a mock store, `SharedPreferences.getInstance()` never completes
    // inside the `FakeAsync` zone `testWidgets` runs in, so `ThemeController`
    // would stay pending forever. Seeding an empty store makes the persisted
    // path real in these tests.
    SharedPreferences.setMockInitialValues({});
    await ThemeController.instance.setThemeMode(ThemeMode.dark);
    await AppExperienceController.instance.reset();
    await AppExperienceController.instance.setWelcomeSeen(true);
  });
  tearDown(() async {
    await AppExperienceController.instance.reset();
  });

  testWidgets('app shell boots on the trips destination', (
    WidgetTester tester,
  ) async {
    await AppExperienceController.instance.setNewUiEnabled(false);

    await tester.pumpWidget(const CapyEnergyApp());
    await tester.pump();

    // The deleted debug/diagnostics rail entries must not come back, and the
    // shell must land on a destination that exists in every build.
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    expect(find.text('Debug'), findsNothing);
  });

  testWidgets('the new shell is what boots by default', (
    WidgetTester tester,
  ) async {
    // The head unit. The footer strip is a quarter of the viewport, and at the
    // 600-tall test default that quarter is shorter than the efficiency card
    // it holds — see `EfficiencyCard` on the height it needs.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const CapyEnergyApp());
    await tester.pump();

    expect(find.byType(AppShellV2), findsOneWidget);
  });

  testWidgets('the new shell replaces the previous app shell', (
    WidgetTester tester,
  ) async {
    // The head unit, like the neighbouring shell tests. The default test
    // viewport is 600 tall, and the instant-readout footer takes a quarter of
    // whatever it is given — at 600 the destinations are left less height than
    // any of them is composed against.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setNewUiEnabled(true);

    await tester.pumpWidget(const CapyEnergyApp());
    await tester.pump();

    expect(find.byType(AppShellV2), findsOneWidget);
    // Only the tab now. The trips destination used to be a placeholder that
    // repeated its own title; it is the energy monitor since.
    //
    // CarPlay is left unchecked here: it only appears once the head unit's
    // OEM service is actually bound, which `CapyEnergyApp` has no seam to
    // fake — that behavior is exercised directly against `AppShellV2` with an
    // injected `CarplayApi` further down this file.
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Charging'), findsOneWidget);
    // Settings stopped being a destination. It is the gear beside the row,
    // and it opens a floating menu instead of a page the roll can land on.
    expect(find.text('Settings'), findsNothing);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    await _rollTo(tester, 'Charging');

    expect(find.byType(ChargingV2Screen), findsOneWidget);
    expect(find.text('Vehicle range'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the previous shell can be picked without restarting the app', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setNewUiEnabled(true);

    await tester.pumpWidget(const CapyEnergyApp());
    await tester.pump();
    expect(find.byType(AppShellV2), findsOneWidget);

    // The settings menu owns the switch back. The new shell must not cost
    // access to the previous app until the process is killed.
    await _openSettings(tester);
    await tester.tap(find.text('Developer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use the previous interface'));
    // Plain pumps, not `pumpAndSettle`: the previous shell this lands on keeps
    // a repeating clock running, so there is no settled frame to wait for.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(AppExperienceController.instance.newUiEnabled, isFalse);
    expect(find.byType(AppShellV2), findsNothing);
    expect(find.text('Trips'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('V2 Config switches between the persistent app themes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setNewUiEnabled(true);

    await tester.pumpWidget(const CapyEnergyApp());
    await tester.pump();
    // Displays is the category the menu opens on, and appearance is its one
    // section — so the theme control is reachable in a single tap.
    await _openSettings(tester);

    expect(
      Theme.of(tester.element(find.byType(AppShellV2))).brightness,
      Brightness.dark,
    );
    expect(find.text('App theme'), findsOneWidget);
    // Appearance is a section of Displays, so it is a card title — that is
    // what carries the bold Inter face the reference sets sections in.
    final sectionTitle = tester.renderObject<RenderParagraph>(
      find.text('Appearance'),
    );
    final sectionStyle = (sectionTitle.text as TextSpan).style!;
    expect(sectionStyle.fontFamily, 'Inter');
    expect(sectionStyle.fontWeight, FontWeight.w700);

    // The picker offers the whole catalogue, so a theme is chosen by its own
    // name rather than by a brightness.
    await tester.tap(find.text('Sepia'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(ThemeController.instance.themeId, AppThemeId.sepia);
    expect(
      Theme.of(tester.element(find.byType(AppShellV2))).brightness,
      Brightness.light,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_id'), 'sepia');
    // The pre-catalogue key still follows the brightness, so a downgrade
    // finds the theme the reader left the app on.
    expect(prefs.getString('theme_mode'), 'light');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the CarPlay tab leads the row once the head unit connects, and owns the '
    'video surface',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await AppExperienceController.instance.setProjectionEnabled(true);
      final api = _RecordingCarplayApi();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppShellV2(carplayApi: api),
        ),
      );
      await tester.pump();

      expect(find.text('Trips'), findsOneWidget);
      expect(find.text('Charging'), findsOneWidget);
      expect(find.text('CarPlay'), findsOneWidget);
      // Pills are laid out left to right; CarPlay leads the row.
      expect(
        tester.getTopLeft(_tab('CarPlay')).dx,
        lessThan(tester.getTopLeft(_tab('Trips')).dx),
      );

      // Nothing holds the OEM renderer until the tab is actually rolled to.
      expect(api.activateCount, 0);

      await _rollTo(tester, 'CarPlay');

      expect(find.byType(CarplayHomeV2Screen), findsOneWidget);
      final surface = tester.widget<CarplayV2Screen>(
        find.byType(CarplayV2Screen),
      );
      expect(surface.surfaceOnly, isTrue);
      expect(surface.isActive, isTrue);
      expect(api.activateCount, 1);

      await _rollTo(tester, 'Trips');
      expect(api.deactivateCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving CarPlay keeps its surface mounted but inactive', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setProjectionEnabled(true);
    final api = _RecordingCarplayApi();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(carplayApi: api),
      ),
    );
    await tester.pump();

    await _rollTo(tester, 'CarPlay');
    await _rollTo(tester, 'Trips');

    // The child stays mounted (kept alive by the rolling `PageView`), but its
    // flag must flip so it never holds the OEM renderer (R1).
    //
    // `skipOffstage: false` is required. Scrolled away from, the child is
    // still in the tree — kept alive, not rebuilt — but no longer onstage, so
    // the default finder reports it absent even though it is still mounted,
    // which is exactly the state this test exists to assert.
    final finder = find.byType(CarplayV2Screen, skipOffstage: false);
    expect(finder, findsOneWidget);
    expect(tester.widget<CarplayV2Screen>(finder).isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the CarPlay tab stays hidden until the head unit actually connects',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await AppExperienceController.instance.setProjectionEnabled(true);
      final api = _RecordingCarplayApi(connected: false);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppShellV2(carplayApi: api),
        ),
      );
      await tester.pump();

      expect(find.text('CarPlay'), findsNothing);
      // `skipOffstage: false`: prove the screen was never built at all, not
      // just that it is the unselected child of the roll.
      expect(
        find.byType(CarplayHomeV2Screen, skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      // The stream, not just the seed read, has to be able to bring it in.
      api.setConnected(true);
      await tester.pump();
      await tester.pump();

      expect(find.text('CarPlay'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('V2 Config carries the projection beta switch', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _RecordingCarplayApi();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(carplayApi: api),
      ),
    );
    await tester.pump();
    await _openSettings(tester);
    await tester.tap(find.text('Developer'));
    await tester.pumpAndSettle();

    // The settings menu is the only way in: the beta is opt-in, so a user who
    // never comes here never gets CarPlay. The title is what says it is a beta
    // and must not be dropped to a bare "CarPlay" heading.
    expect(find.text('CarPlay / Android Auto (Beta)'), findsOneWidget);
    expect(AppExperienceController.instance.projectionEnabled, isFalse);

    await tester.tap(find.text('CarPlay / Android Auto (Beta)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(AppExperienceController.instance.projectionEnabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the projection beta being off keeps the services unstarted and the tabs away',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Connected head unit on purpose: the beta being off has to win over a
      // service that would otherwise answer. It is off by default, so nothing
      // needs switching here — that absence is the state under test.
      final api = _RecordingCarplayApi();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppShellV2(carplayApi: api),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(api.getStatusCount, 0);
      expect(api.statusStreamCount, 0);
      expect(find.text('CarPlay'), findsNothing);
      expect(
        find.byType(CarplayHomeV2Screen, skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching the projection beta takes effect without a restart', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setProjectionEnabled(true);
    final api = _RecordingCarplayApi();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(carplayApi: api),
      ),
    );
    await tester.pump();
    expect(find.text('CarPlay'), findsOneWidget);

    // Standing on the tab, holding the OEM renderer, when it is switched off:
    // the worst moment for it.
    await _rollTo(tester, 'CarPlay');
    expect(api.activateCount, 1);

    await AppExperienceController.instance.setProjectionEnabled(false);
    await tester.pump();
    await tester.pump();
    expect(find.text('CarPlay'), findsNothing);
    // The renderer must go back to the OEM, not stay taken by a tab that no
    // longer exists.
    expect(api.deactivateCount, greaterThanOrEqualTo(1));

    // Back on, the shell re-runs the same probe `initState` would have, so the
    // tab returns without the process being killed.
    final probesBeforeReenable = api.getStatusCount;
    await AppExperienceController.instance.setProjectionEnabled(true);
    await tester.pump();
    await tester.pump();
    expect(find.text('CarPlay'), findsOneWidget);
    expect(api.getStatusCount, greaterThan(probesBeforeReenable));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tab the user is standing on can stop being shown', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setProjectionEnabled(true);
    final api = _RecordingCarplayApi();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(carplayApi: api),
      ),
    );
    await tester.pump();
    await _rollTo(tester, 'CarPlay');
    expect(
      find.byType(CarplayHomeV2Screen, skipOffstage: false),
      findsOneWidget,
    );

    // The connection can drop live, while the user is already standing on the
    // destination it removes. CarPlay leads the row, so losing it shifts every
    // later index — a body indexed by `_selected.index` would have reached
    // past a list that had just shrunk.
    api.setConnected(false);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(CarplayHomeV2Screen, skipOffstage: false), findsNothing);
    // Fell back to the first destination that is still shown.
    expect(find.text('Trips'), findsWidgets);
  });

  testWidgets('the body follows the tab row, not the enum', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setProjectionEnabled(true);
    final api = _RecordingCarplayApi();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(carplayApi: api),
      ),
    );
    await tester.pump();

    // `CarPlay` leads the row and is the last enum constant declared. Only
    // the destination the roll is actually resting on is onstage in the
    // `PageView`, so each of these fails if the body is indexed in a
    // different order from the one the user is reading.
    await _rollTo(tester, 'CarPlay');
    expect(find.byType(CarplayHomeV2Screen), findsOneWidget);

    await _rollTo(tester, 'Charging');
    expect(find.byType(CarplayHomeV2Screen), findsNothing);
    expect(find.byType(ChargingV2Screen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the footer strip waits for the roll before it gives up space', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _RecordingCarplayApi(connected: false);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(carplayApi: api),
      ),
    );
    await tester.pump();

    final docked = tester.getSize(find.byType(PageView));

    // History is the one destination that takes the footer's strip. Collapsing
    // it *during* the roll would re-measure the body on every frame, and both
    // pages crossing the screen re-layout and re-shape their text with it — so
    // the strip must not move until the roll has landed.
    await tester.tap(_tab('History'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.getSize(find.byType(PageView)), docked);

    // The roll lands, and only then does the strip start travelling.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getSize(find.byType(PageView)).height,
      greaterThan(docked.height),
    );
    expect(tester.takeException(), isNull);
  });
}

/// The tab label, not the card title of the same name.
///
/// Once a destination is visited both are in the tree, and the tab bar is built
/// before the body, so the first match is the tab.
Finder _tab(String label) => find.text(label).first;

/// Taps a tab pill and settles the roll it starts.
///
/// A tab switch drives a `PageView` roll (`AppMotion.slow`), not an instant
/// `IndexedStack` swap, so a single `pump()` right after the tap can land
/// before the destination's page has even entered the viewport — a plain
/// `PageView` only builds pages near the current scroll position, same as any
/// other sliver list. The first `pump()` lets the roll's ticker actually
/// start; a lone `pump(duration)` issued directly after the tap observes no
/// motion at all, one call short of the animation beginning.
/// Opens the floating settings menu from the gear beside the tab row.
Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pumpAndSettle();
}

Future<void> _rollTo(WidgetTester tester, String label) async {
  await tester.tap(_tab(label));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Connected by default — most tests need the CarPlay destination visible to
/// exercise it. Pass `connected: false` for tests that need the
/// head unit absent instead, and drive [setConnected] to simulate it
/// connecting or dropping live, the way the real status stream would.
class _RecordingCarplayApi extends CarplayApi {
  _RecordingCarplayApi({bool connected = true})
    : _status = _statusFor(connected);

  static CarplayStatus _statusFor(bool connected) =>
      CarplayStatus.empty.copyWith(available: connected, bound: connected);

  CarplayStatus _status;
  final _statusController = StreamController<CarplayStatus>.broadcast();

  int activateCount = 0;
  int deactivateCount = 0;

  /// How often the shell reached for the platform side at all. Both stay at
  /// zero while the projection beta is off — that is what "the service never
  /// starts" means from Dart, since binding happens on the first call.
  int getStatusCount = 0;
  int statusStreamCount = 0;

  void setConnected(bool connected) {
    _status = _statusFor(connected);
    _statusController.add(_status);
  }

  @override
  Future<CarplayStatus> getStatus() async {
    getStatusCount++;
    return _status;
  }

  @override
  Future<CarplayStatus> activate({int? width, int? height}) async {
    activateCount++;
    return _status;
  }

  @override
  Future<CarplayStatus> deactivate() async {
    deactivateCount++;
    return _status;
  }

  @override
  Future<CarplayStatus> refresh() async => _status;

  @override
  Stream<CarplayStatus> statusStream() {
    statusStreamCount++;
    return _statusController.stream;
  }
}
