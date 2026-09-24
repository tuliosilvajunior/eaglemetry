import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/app_experience_controller.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/app_shell_v2.dart';
import 'package:capy_energy/screens_v2/shell_climate_bar.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shell end of the climate bar: one Settings switch decides whether it is
/// there at all, and when it is there, nothing on any screen can move it.
///
/// `app_journey_scaffold_test.dart` pins the layout contract itself. This file
/// pins that the shell puts the bar in the slot that carries that contract,
/// and that the switch reaches it without a restart.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppExperienceController.instance.reset();
  });

  tearDown(() async {
    await AppExperienceController.instance.reset();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // The shell opens the welcome announcement on its first frame, and that
    // dialog is modal: it absorbs the pointer over the whole screen, the bar
    // included. Marking it seen is what leaves the shell reachable — the bar
    // being unreachable behind a modal is correct, not a defect to work
    // around.
    await AppExperienceController.instance.setWelcomeSeen(true);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AppShellV2(),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the bar is absent until the reader asks for it', (tester) async {
    await pumpShell(tester);

    expect(AppExperienceController.instance.climateBarEnabled, isFalse);
    expect(find.byType(ClimateTemperatureBar), findsNothing);
  });

  testWidgets('the switch brings the bar in without a restart', (tester) async {
    await pumpShell(tester);

    await AppExperienceController.instance.setClimateBarEnabled(true);
    await tester.pump();

    expect(find.byType(ClimateTemperatureBar), findsOneWidget);
  });

  testWidgets('the bar is the scaffold static strip, not its footer', (
    tester,
  ) async {
    await AppExperienceController.instance.setClimateBarEnabled(true);
    await pumpShell(tester);

    // The slot is what carries the "a fullscreen card cannot take it away"
    // contract. Passing the bar as `footer` instead would render identically
    // and lose exactly that, so the slot is what this asserts.
    final scaffold = tester.widget<AppJourneyScaffold<Object?>>(
      find.byWidgetPredicate((w) => w is AppJourneyScaffold<Object?>),
    );
    expect(scaffold.staticBar, isA<ShellClimateBar>());
  });

  testWidgets('a chevron steps its own zone and leaves the other alone', (
    tester,
  ) async {
    await AppExperienceController.instance.setClimateBarEnabled(true);
    await pumpShell(tester);

    expect(find.text('21.5°'), findsNWidgets(2));

    await tester.tap(
      find.byKey(const Key('climate-temperature-bar-driver-increase')),
    );
    await tester.pump();

    expect(find.text('22.0°'), findsOneWidget);
    expect(find.text('21.5°'), findsOneWidget);
  });
}
