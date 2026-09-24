import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/energy_session_panel.dart';
import 'package:capy_ui/capy_ui.dart';

/// One minute of driving with a climate share, so the ring has three arcs and
/// the legend four rows.
EnergyBucket _bucket() {
  return EnergyBucket(
    start: DateTime.utc(2026, 8, 10, 9),
    width: const Duration(minutes: 1),
    tractionWh: 400,
    regeneratedWh: 60,
    auxiliaryWh: 120,
    integratedSeconds: 60,
    climateWh: 40,
    climateIntegratedSeconds: 60,
  );
}

Widget _host({required double height, bool showTitle = true}) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 420,
          height: height,
          child: EnergySessionPanel(
            buckets: [_bucket()],
            loading: false,
            failed: false,
            showTitle: showTitle,
          ),
        ),
      ),
    ),
  );
}

/// How far a marker glyph sits from the middle of the ring — which is the ring
/// itself plus a fixed band, so it is the one measurement that says the ring
/// grew without the test having to re-derive the geometry.
double _markerRadius(WidgetTester tester) {
  final box = tester.getRect(find.byType(SegmentedDonut).first);
  final glyph = tester.getRect(find.byIcon(Icons.grid_view).first);
  return (glyph.center - box.center).distance;
}

void main() {
  testWidgets('a tall card keeps the legend under the ring', (tester) async {
    await tester.pumpWidget(_host(height: 560));
    await tester.pumpAndSettle();

    expect(find.byType(IconValueGrid), findsOneWidget);
    // The reading appears once, in the legend.
    expect(find.text('0.4 kWh'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short card drops the legend and reads on the arcs', (
    tester,
  ) async {
    await tester.pumpWidget(_host(height: 300));
    await tester.pumpAndSettle();

    expect(find.byType(IconValueGrid), findsNothing);
    // Still exactly once, now on its own arc rather than in a footer row.
    expect(find.text('0.4 kWh'), findsOneWidget);
    // The ring is still the panel: its glyph and its reading sit together
    // outside the stroke.
    final donut = tester.getRect(find.byType(SegmentedDonut));
    final reading = tester.getRect(find.text('0.4 kWh'));
    expect(donut.contains(reading.center), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unnamed card hands the header band to the ring', (
    tester,
  ) async {
    // The session detail's own cell. Named, it is too short for the legend and
    // the ring closes down to make room for the readings on its arcs.
    await tester.pumpWidget(_host(height: 420));
    await tester.pumpAndSettle();
    expect(find.byType(IconValueGrid), findsNothing);
    final named = _markerRadius(tester);

    // Unnamed, the same box draws the ring the named card needs 84 more pixels
    // to draw — the header row plus its gap — and the legend fits under it
    // again. The button that explains the legend moves down beside it, so it
    // is never the thing that is lost.
    await tester.pumpWidget(_host(height: 420, showTitle: false));
    await tester.pumpAndSettle();
    final unnamed = _markerRadius(tester);
    expect(find.byType(IconValueGrid), findsOneWidget);
    expect(find.byType(InfoIconButton), findsOneWidget);
    expect(unnamed, greaterThan(named));

    await tester.pumpWidget(_host(height: 504));
    await tester.pumpAndSettle();
    expect(_markerRadius(tester), unnamed);
  });

  testWidgets('a card with no room for either still explains its glyphs', (
    tester,
  ) async {
    // No header to carry the button and no footer to carry it either, which is
    // the one case where it has to be placed by hand.
    await tester.pumpWidget(_host(height: 300, showTitle: false));
    await tester.pumpAndSettle();

    expect(find.byType(IconValueGrid), findsNothing);
    expect(find.byType(InfoIconButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the headline stays inside the ring in both', (tester) async {
    for (final height in [560.0, 300.0]) {
      await tester.pumpWidget(_host(height: height));
      await tester.pumpAndSettle();

      // 0.52 kWh drawn: traction plus the auxiliary that holds climate.
      expect(find.text('0.5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
