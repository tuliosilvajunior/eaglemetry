import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/incline_readout.dart';
import 'package:capy_ui/capy_ui.dart';

Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<double?> source, {
  CardStageController? stage,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          height: 200,
          child: InclineReadout(inclineSource: source, stage: stage),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the placeholder until the bus reports an angle', (
    tester,
  ) async {
    final source = ValueNotifier<double?>(null);
    await _pump(tester, source);

    expect(find.byType(TiltCard), findsOneWidget);
    expect(find.text('--'), findsOneWidget);

    source.dispose();
  });

  testWidgets('shows the angle the bus reports', (tester) async {
    final source = ValueNotifier<double?>(null);
    await _pump(tester, source);

    source.value = 5.4;
    await tester.pumpAndSettle();

    expect(find.text('5°'), findsOneWidget);

    source.dispose();
  });

  // A quiet bus is not a level road. The card has to withdraw, not hold the
  // last angle, because a car that is moved while the daemon is silent would
  // otherwise keep reporting the grade of where it used to stand.
  testWidgets('withdraws to the placeholder when the signal stops', (
    tester,
  ) async {
    final source = ValueNotifier<double?>(null);
    await _pump(tester, source);

    source.value = 4.0;
    await tester.pumpAndSettle();
    expect(find.text('4°'), findsOneWidget);

    source.value = null;
    await tester.pumpAndSettle();
    expect(find.text('--'), findsOneWidget);

    source.dispose();
  });

  testWidgets('pauses sampling when card stage is fullscreen', (tester) async {
    final source = ValueNotifier<double?>(null);
    const vsync = TestVSync();
    final stage = CardStageController(vsync: vsync);

    await _pump(tester, source, stage: stage);

    source.value = 3.0;
    await tester.pumpAndSettle();
    expect(find.text('3°'), findsOneWidget);

    stage.expand();
    await tester.pumpAndSettle();

    source.value = 8.0;
    await tester.pumpAndSettle();

    expect(find.text('3°'), findsOneWidget);

    stage.collapse();
    await tester.pumpAndSettle();

    source.value = 10.0;
    await tester.pumpAndSettle();
    expect(find.text('10°'), findsOneWidget);

    stage.dispose();
    source.dispose();
  });
}
