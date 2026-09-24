import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/history/session_mosaic.dart';
import 'package:capy_ui/capy_ui.dart';

import 'support/session_records.dart';

void main() {
  /// The wall is sized for two rows — see `SessionMosaic._columns`. A tile
  /// added without taking one out silently buys a third row, and at a quarter
  /// of the screen that leaves every tile too short to read.
  void expectTwoRows(WidgetTester tester) {
    final mosaic = tester.widget<MetricMosaic>(find.byType(MetricMosaic));
    final packed = packMosaic(mosaic.tiles, columns: mosaic.columns);
    final rows = packed.fold<int>(
      0,
      (rows, placement) => rows > placement.bottom ? rows : placement.bottom,
    );
    expect(rows, 2);
  }

  testWidgets('a drive packs into two rows, duration between the two times', (
    tester,
  ) async {
    await tester.pumpWidget(_app(SessionMosaic.trip(reading: _tripReading())));
    await tester.pumpAndSettle();

    expectTwoRows(tester);

    // The three read left to right as one sentence.
    final start = tester.getRect(find.text('Start'));
    final duration = tester.getRect(find.text('Duration'));
    final end = tester.getRect(find.text('End'));
    expect(start.left, lessThan(duration.left));
    expect(duration.left, lessThan(end.left));
    expect(duration.top, start.top);
    expect(end.top, start.top);
  });

  testWidgets('a charge packs into two rows', (tester) async {
    await tester.pumpWidget(
      _app(SessionMosaic.charge(reading: _chargeReading())),
    );
    await tester.pumpAndSettle();

    expectTwoRows(tester);
  });

  testWidgets('the readings taken out stay out', (tester) async {
    await tester.pumpWidget(
      _app(SessionMosaic.charge(reading: _chargeReading(measured: false))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Plug'), findsNothing);
    expect(find.text('Consumed'), findsNothing);
    expect(find.text('Regenerated'), findsNothing);
  });
}

Widget _app(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    // A quarter of a 1080p head unit, which is the box this wall is built for.
    home: Scaffold(
      body: Center(child: SizedBox(width: 1800, height: 260, child: child)),
    ),
  );
}

/// A drive of 12.5 km at 5.2 km/kWh, stated the way the store answers.
TripDetailReading _tripReading() {
  final session = tripRecord(
    id: 'trip-1',
    startedAtUtcMillis: 1770000000000,
    startedAtElapsedNanos: 1000000000,
    endedAtUtcMillis: 1770001800000,
    endedAtElapsedNanos: 1801000000000,
    startSoc: 80.0,
    endSoc: 74.0,
    startOdometerKm: 1000.0,
    endOdometerKm: 1012.5,
    sessionRollup: rollup(
      distanceKm: 12.5,
      tractionWh: 2404.0,
      regenWh: 0.0,
      auxiliaryWh: 0.0,
      integratedSeconds: 1800.0,
    ),
  );
  return TripDetailReading(
    session: session,
    series: TelemetrySeries(
      sessionId: session.id,
      intervals: const [],
      samples: const {},
    ),
  );
}

/// A charge of 7.25 kWh at about 7 kW.
///
/// With [measured] false the car reported no minutes at all, which is what the
/// wall must show as an absent reading rather than as a zero.
ChargeDetailReading _chargeReading({bool measured = true}) {
  final session = chargeRecord(
    id: 'charge-1',
    status: 'ENDED',
    startedAtUtcMillis: 1770010000000,
    startedAtElapsedNanos: 1000000000,
    plugDisconnectedAtUtcMillis: 1770013600000,
    plugDisconnectedAtElapsedNanos: 3601000000000,
    startSoc: 40.0,
    endSoc: 60.0,
    deliveredWh: measured ? 7250.0 : null,
  );
  return ChargeDetailReading(
    session: session,
    series: TelemetrySeries(
      sessionId: session.id,
      intervals: [
        if (measured)
          for (var minute = 0; minute < 60; minute++)
            intervalRecord(
              sessionId: session.id,
              startUtcMillis: 1770010000000 + minute * 60000,
              deliveredWh: (minute == 0 ? 7.4 : 6.9) * 1000 / 60,
              deliveredCoveredSeconds: 60,
            ),
      ],
      samples: const {},
    ),
  );
}
