import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/range_drop_controller.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/trips/range_drop_panel.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:capy_ui/capy_ui.dart';

/// The Range Drop card, on its own.
///
/// These cases used to run through `TripsV2Screen`, which mounted the card in
/// its leading column. The dashboard dropped that column while issue 170
/// reworks what the card measures, and the card outlived it: what is asked
/// here is what the panel prints for a given stretch, which never needed a
/// dashboard around it.

/// The polls the controller reads through, as one notifier a test can drive.
class _RangeDropSources extends ChangeNotifier {
  RangeEstimate? estimate;
  double? odometerKm;
  String? activeSessionId;

  void publish({
    RangeEstimate? estimate,
    double? odometerKm,
    String? activeSessionId,
  }) {
    this.estimate = estimate;
    this.odometerKm = odometerKm;
    this.activeSessionId = activeSessionId;
    notifyListeners();
  }
}

/// A range estimate through the DTO's own gates, so the panel never sees a
/// reading the app would refuse to show.
RangeEstimate _rangeEstimate({
  required double? carRangeKm,
  required double ownRangeKm,
  String? carReason,
}) {
  const capacityKwh = 60.0;
  const efficiencyKmPerKwh = 7.18;
  return RangeEstimate.fromMap({
    'timestampMillis': 0,
    'carRangeKm': carRangeKm,
    'carRangeQuality': carRangeKm == null ? 'UNAVAILABLE' : 'AVAILABLE',
    'carRangeReason': carReason,
    'carRangePropertyId': RangeEstimate.rangeRemainingPropertyId,
    'carRangeSignalSource': carRangeKm == null ? null : 'VHAL_CALLBACK',
    'carRangeReceivedAtUtcMillis': 0,
    'carRangeSourceTimestampNanos': 0,
    'socPercent': 50.0,
    'capacityKwh': capacityKwh,
    'capacitySource': 'SETTINGS',
    'efficiencyKmPerKwh': efficiencyKmPerKwh,
    'efficiencySource': 'CLOSED_TRIPS_7D',
    'efficiencyWindowDays': 7,
    'efficiencyTripCount': 2,
    'efficiencyDistanceKm': 24.7,
    'efficiencyNetEnergyKwh': 3.44,
    'efficiencyUpdatedAtUtcMillis': 0,
    'fullRangeKm': capacityKwh * efficiencyKmPerKwh,
    'ownRangeKm': ownRangeKm,
    'ownRangeQuality': 'AVAILABLE',
    'ownRangeReason': null,
  });
}

void main() {
  /// Mounts the panel over a controller the case drives, and returns the
  /// sources to publish through.
  Future<_RangeDropSources> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final sources = _RangeDropSources();
    final drop = RangeDropController(
      source: sources,
      readEstimate: () => sources.estimate,
      readOdometerKm: () => sources.odometerKm,
      readActiveSessionId: () => sources.activeSessionId,
      clock: () => DateTime(2026, 8, 26, 14, 32),
    );
    addTearDown(drop.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AnimatedBuilder(
            animation: drop,
            builder: (context, _) => RangeDropPanel(state: drop.state),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return sources;
  }

  testWidgets('the range drop panel prints the measured stretch', (
    tester,
  ) async {
    final sources = await pump(tester);

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.rangeDropWaiting), findsOneWidget);

    sources.publish(
      estimate: _rangeEstimate(carRangeKm: 266, ownRangeKm: 200),
      odometerKm: 12800,
      activeSessionId: 'trip-1',
    );
    sources.publish(
      estimate: _rangeEstimate(carRangeKm: 226, ownRangeKm: 174),
      odometerKm: 12825,
      activeSessionId: 'trip-1',
    );
    await tester.pump();

    expect(find.text(loc.rangeDropDistance), findsOneWidget);
    expect(find.text('25.0 ${loc.unitKm}'), findsOneWidget);
    expect(find.text(loc.rangeDropCarSpent), findsOneWidget);
    expect(find.text('40.0 ${loc.unitKm}'), findsOneWidget);
    expect(find.text(loc.rangeDropAppSpent), findsOneWidget);
    expect(find.text('26.0 ${loc.unitKm}'), findsOneWidget);
    expect(find.text(loc.rangeDropStretch('14:32')), findsOneWidget);
  });

  testWidgets('recovered range flips the verb, not the sign', (tester) async {
    final sources = await pump(tester);

    sources.publish(
      estimate: _rangeEstimate(carRangeKm: 200, ownRangeKm: 150),
      odometerKm: 12800,
      activeSessionId: 'trip-1',
    );
    sources.publish(
      estimate: _rangeEstimate(carRangeKm: 203, ownRangeKm: 151),
      odometerKm: 12802,
      activeSessionId: 'trip-1',
    );
    await tester.pump();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.rangeDropCarGained), findsOneWidget);
    expect(find.text('3.0 ${loc.unitKm}'), findsOneWidget);
    expect(find.text(loc.rangeDropAppGained), findsOneWidget);
    expect(find.text('1.0 ${loc.unitKm}'), findsOneWidget);
  });

  testWidgets('an unavailable car line reads in the reader\'s language', (
    tester,
  ) async {
    final sources = await pump(tester);

    sources.publish(
      estimate: _rangeEstimate(carRangeKm: 266, ownRangeKm: 200),
      odometerKm: 12800,
      activeSessionId: 'trip-1',
    );
    sources.publish(
      estimate: _rangeEstimate(
        carRangeKm: null,
        ownRangeKm: 174,
        carReason: 'SIGNAL_ERROR',
      ),
      odometerKm: 12825,
      activeSessionId: 'trip-1',
    );
    await tester.pump();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      find.descendant(
        of: find.byType(RangeDropPanel),
        matching: find.text('--'),
      ),
      findsOneWidget,
    );
    expect(find.text(loc.rangeReasonSignalError), findsOneWidget);
    // The other line is untouched by its neighbour's dead signal.
    expect(find.text('26.0 ${loc.unitKm}'), findsOneWidget);
  });
}
