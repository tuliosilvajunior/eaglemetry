import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/projection_touch_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/l10n/app_localizations_en.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:capy_energy/widgets/projection_touch_calibration_panel.dart';

/// The calibration exists because Android Auto's draw path and touch path
/// disagree and neither is readable from this process. What this suite pins is
/// that the correction is honest about itself: it writes through at once, it
/// shows what the native side really applied rather than what was asked, and it
/// cannot offer a value that would be silently brought back.
void main() {
  group('ProjectionTouchCalibration', () {
    test('the identity is the default, and says so', () {
      expect(ProjectionTouchCalibration.identity.isIdentity, isTrue);
      expect(const ProjectionTouchCalibration().scaleX, 1.0);
      expect(const ProjectionTouchCalibration().offsetY, 0.0);
    });

    test('Android Auto starts shifted up, CarPlay starts at the identity', () {
      // Measured on the car: AA lands one keyboard row low at every card size.
      expect(
        ProjectionTouchCalibration.defaultFor(ProjectionStack.androidAuto),
        const ProjectionTouchCalibration(offsetY: -80),
      );
      expect(
        ProjectionTouchCalibration.defaultFor(ProjectionStack.carplay),
        ProjectionTouchCalibration.identity,
      );
    });

    test('a nudge past the bounds stops at them', () {
      const far = ProjectionTouchCalibration(scaleX: 2.0);
      expect(
        far.copyWith(scaleX: 3.0).scaleX,
        ProjectionTouchCalibration.maxScale,
      );
      expect(
        const ProjectionTouchCalibration().copyWith(offsetY: -9999.0).offsetY,
        -ProjectionTouchCalibration.offsetLimit,
      );
    });

    test('a missing field reads as the identity, never as zero', () {
      // The trap: a scale defaulting to 0.0 would collapse the whole axis onto
      // its centre line, and every touch would land on one stripe.
      final parsed = ProjectionTouchCalibration.fromMap(const {'offsetY': -96});
      expect(parsed.scaleX, 1.0);
      expect(parsed.scaleY, 1.0);
      expect(parsed.offsetY, -96.0);
    });

    test('a status with no calibration key still yields the identity', () {
      final status = ProjectionTouchStackStatus.fromMap(const {'bound': true});
      expect(status.calibration, ProjectionTouchCalibration.identity);
    });

    test('the calibration survives a round trip through the wire map', () {
      const original = ProjectionTouchCalibration(
        scaleX: 1.02,
        offsetX: -12,
        scaleY: 0.97,
        offsetY: 96,
      );
      expect(ProjectionTouchCalibration.fromMap(original.toMap()), original);
    });
  });

  group('ProjectionTouchCalibrationPanel', () {
    Future<ProjectionTouchCalibration?> pumpAndNudge(
      WidgetTester tester, {
      required ProjectionTouchCalibration start,
      required ProjectionTouchCalibrationStep step,
      required String label,
      required IconData icon,
    }) async {
      ProjectionTouchCalibration? seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: ProjectionTouchCalibrationPanel(
                calibration: start,
                step: step,
                onStepChanged: (_) {},
                onChanged: (value) => seen = value,
              ),
            ),
          ),
        ),
      );
      final row = find.ancestor(
        of: find.text(label),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(of: row.first, matching: find.byIcon(icon)),
      );
      await tester.pump();
      return seen;
    }

    testWidgets('a coarse vertical nudge moves by the coarse step', (
      tester,
    ) async {
      final seen = await pumpAndNudge(
        tester,
        start: ProjectionTouchCalibration.identity,
        step: ProjectionTouchCalibrationStep.coarse,
        label: AppLocalizationsEn().v2ProjectionTouchOffsetY,
        icon: Icons.remove,
      );

      // The measured fault on this head unit is vertical and downward: a touch
      // on the keyboard's top row registers on the row below it. Correcting it
      // means sending a smaller y, so the minus key must subtract.
      expect(
        seen?.offsetY,
        -ProjectionTouchCalibrationStep.coarse.offsetPixels,
      );
      expect(seen?.offsetX, 0.0);
      expect(seen?.scaleY, 1.0);
    });

    testWidgets('the fine step is smaller than the coarse one', (tester) async {
      final seen = await pumpAndNudge(
        tester,
        start: ProjectionTouchCalibration.identity,
        step: ProjectionTouchCalibrationStep.fine,
        label: AppLocalizationsEn().v2ProjectionTouchOffsetY,
        icon: Icons.add,
      );

      expect(seen?.offsetY, ProjectionTouchCalibrationStep.fine.offsetPixels);
      expect(
        ProjectionTouchCalibrationStep.fine.offsetPixels,
        lessThan(ProjectionTouchCalibrationStep.coarse.offsetPixels),
      );
    });

    testWidgets('a nudge at the bound does not pass it', (tester) async {
      final seen = await pumpAndNudge(
        tester,
        start: const ProjectionTouchCalibration(
          scaleX: ProjectionTouchCalibration.maxScale,
        ),
        step: ProjectionTouchCalibrationStep.coarse,
        label: AppLocalizationsEn().v2ProjectionTouchScaleX,
        icon: Icons.add,
      );

      expect(seen?.scaleX, ProjectionTouchCalibration.maxScale);
    });

    testWidgets('reset goes back to the stack default, not the identity', (
      tester,
    ) async {
      // On Android Auto the identity is the state known to be wrong, so a
      // reset to it would undo a correction the car needs.
      const target = ProjectionTouchCalibration.androidAutoDefault;
      ProjectionTouchCalibration? seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: ProjectionTouchCalibrationPanel(
                calibration: const ProjectionTouchCalibration(offsetY: -8),
                step: ProjectionTouchCalibrationStep.fine,
                resetTarget: target,
                onStepChanged: (_) {},
                onChanged: (value) => seen = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(SoftActionTile));
      await tester.pump();
      expect(seen, target);
    });

    testWidgets('reset is offered only when something is being corrected', (
      tester,
    ) async {
      Widget panel(ProjectionTouchCalibration calibration) => MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: ProjectionTouchCalibrationPanel(
              calibration: calibration,
              step: ProjectionTouchCalibrationStep.fine,
              onStepChanged: (_) {},
              onChanged: (_) {},
            ),
          ),
        ),
      );

      await tester.pumpWidget(panel(ProjectionTouchCalibration.identity));
      expect(
        tester.widget<SoftActionTile>(find.byType(SoftActionTile)).onPressed,
        isNull,
      );

      await tester.pumpWidget(
        panel(const ProjectionTouchCalibration(offsetY: -96)),
      );
      expect(
        tester.widget<SoftActionTile>(find.byType(SoftActionTile)).onPressed,
        isNotNull,
      );
    });

    testWidgets('the sign of a shift is on the screen', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: ProjectionTouchCalibrationPanel(
                calibration: const ProjectionTouchCalibration(
                  offsetY: -96,
                  offsetX: 12,
                ),
                step: ProjectionTouchCalibrationStep.fine,
                onStepChanged: (_) {},
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      // Which way it moved is the whole reading mid-calibration.
      expect(find.text('-96 px'), findsOneWidget);
      expect(find.text('+12 px'), findsOneWidget);
    });
  });
}
