import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/own_average_insight.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host(InsightRead read) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: OwnAverageInsight(read: read)),
  );
}

InsightSupport get _support => const InsightSupport(
  window: kInsightOwnAverageWindow,
  considered: 8,
  excluded: {},
);

void main() {
  testWidgets('a supported saving names the window and the count', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        InsightRead.present(
          Insight(
            claim: InsightClaim.tripVsOwnAverage30d,
            magnitude: const Measurement.measured(-75, unit: 'Wh/km'),
            subject: const Measurement.measured(50, unit: 'Wh/km'),
            reference: const Measurement.measured(125, unit: 'Wh/km'),
            baseline: InsightBaseline.ownAverage30d,
            support: _support,
            aggregationVersion: 1,
            confidence: InsightConfidence.supported,
          ),
        ),
      ),
    );

    expect(
      find.text(
        'This trip used 75.0 Wh/km less than your last 30 days (8 trips).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a gap inside the IQR is not printed as a saving', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        InsightRead.present(
          Insight(
            claim: InsightClaim.tripVsOwnAverage30d,
            magnitude: const Measurement.measured(-18.75, unit: 'Wh/km'),
            subject: const Measurement.measured(106.25, unit: 'Wh/km'),
            reference: const Measurement.measured(125, unit: 'Wh/km'),
            baseline: InsightBaseline.ownAverage30d,
            support: _support,
            aggregationVersion: 1,
            confidence: InsightConfidence.notDistinguishable,
          ),
        ),
      ),
    );

    expect(
      find.text(
        'This trip cannot yet be told apart from your last 30 days (8 trips).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('too few neighbours is not an invented average', (tester) async {
    await tester.pumpWidget(
      _host(
        InsightRead.none(
          absence: InsightAbsence.insufficientSupport,
          support: const InsightSupport(
            window: kInsightOwnAverageWindow,
            considered: 3,
            excluded: {},
          ),
        ),
      ),
    );

    expect(
      find.text(
        'Not enough measured trips in the last 30 days yet (3 usable).',
      ),
      findsOneWidget,
    );
  });

  test('a supported variant claim names the other place', () {
    final loc = lookupAppLocalizations(const Locale('en'));
    final line = insightPhraseText(
      insightPhrase(
        InsightRead.present(
          Insight(
            claim: InsightClaim.variantVsVariant,
            magnitude: const Measurement.measured(-60, unit: 'Wh/km'),
            subject: const Measurement.measured(80, unit: 'Wh/km'),
            reference: const Measurement.measured(140, unit: 'Wh/km'),
            baseline: InsightBaseline.otherVariantSameRoute,
            support: const InsightSupport(
              window: kInsightRouteWindow,
              considered: 4,
              excluded: {},
            ),
            aggregationVersion: 2,
            confidence: InsightConfidence.supported,
          ),
        ),
        placeName: 'Work',
      ),
      loc,
    );
    expect(
      line,
      'This way used 60.0 Wh/km less than the other way to Work (4 compared).',
    );
  });
}
