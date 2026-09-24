import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/compass_readout.dart';
import 'package:capy_ui/capy_ui.dart';

/// A source whose heading the test sets, so the card is exercised against a
/// stated course rather than against the mock's own rotation.
class _HeadingSource extends MockTelemetrySource {
  HeadingReading next = HeadingReading.fromMap(const {
    'timestampMillis': 0,
    'availability': 'NO_FIX',
  });

  int reads = 0;

  @override
  Future<HeadingReading> heading() async {
    reads += 1;
    return next;
  }
}

HeadingReading _moving(double bearing, int atMillis) => HeadingReading.fromMap({
  'timestampMillis': atMillis,
  'availability': 'OK',
  'bearingDeg': bearing,
  'speedMps': 12.0,
  'fixAgeMillis': 200,
});

HeadingReading _stopped(int atMillis) => HeadingReading.fromMap({
  'timestampMillis': atMillis,
  'availability': 'NO_BEARING',
  'speedMps': 0.0,
  'fixAgeMillis': 300,
});

Future<void> _pump(
  WidgetTester tester,
  _HeadingSource source, {
  CardStageController? stage,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: 280,
          child: CompassReadout(
            telemetryApi: TelemetryApi(source: source),
            stage: stage,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows the placeholder before a course arrives', (tester) async {
    final source = _HeadingSource();
    await _pump(tester, source);

    expect(find.byType(CompassCard), findsOneWidget);
    expect(find.text('--'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('shows the course the receiver reports', (tester) async {
    final source = _HeadingSource()..next = _moving(75, 1000);
    await _pump(tester, source);
    await tester.pump();

    expect(find.text('75°'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a stop keeps the course and says it is held', (tester) async {
    final source = _HeadingSource()..next = _moving(75, 1000);
    await _pump(tester, source);
    await tester.pump();

    source.next = _stopped(2000);
    // One interval, so the loop takes the stopped reading.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    // The number stays: a stationary car still faces the way it arrived. The
    // caption is what tells the reader it is remembered, not measured.
    expect(find.text('75°'), findsOneWidget);
    expect(find.text('Stopped. Last direction.'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('names the reason when there is no course at all', (
    tester,
  ) async {
    final source = _HeadingSource()
      ..next = HeadingReading.fromMap(const {
        'timestampMillis': 1000,
        'availability': 'GPS_DISABLED',
      });
    await _pump(tester, source);
    await tester.pump();

    expect(find.text('--'), findsOneWidget);
    expect(find.text('GPS is off'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('a fullscreen card stops the reading', (tester) async {
    const vsync = TestVSync();
    final stage = CardStageController(vsync: vsync);
    addTearDown(stage.dispose);
    final source = _HeadingSource()..next = _moving(75, 1000);
    await _pump(tester, source, stage: stage);
    await tester.pump();
    final readsWhileVisible = source.reads;
    expect(readsWhileVisible, greaterThan(0));

    stage.expand();
    await tester.pumpAndSettle();
    final readsAtPause = source.reads;

    await tester.pump(const Duration(seconds: 3));
    // Nothing was asked while the strip was off screen.
    expect(source.reads, readsAtPause);
    // And the held course was dropped: nothing sampled the movement that may
    // have happened behind the fullscreen card.
    expect(find.text('--'), findsOneWidget);
  });
}
