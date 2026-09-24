import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/energy_monitor_controller.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/telemetry_api.dart';

import 'support/session_records.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/energy_session_panel.dart';
import 'package:capy_energy/screens_v2/trips/energy_monitor_panel.dart';
import 'package:capy_energy/screens_v2/trips/range_drop_panel.dart';
import 'package:capy_energy/screens_v2/trips/trips_v2_screen.dart';
import 'package:capy_ui/capy_ui.dart';

final _base = DateTime(2026, 8, 3, 13);

EnergyBucket _minute(
  int minute, {
  double traction = 600,
  double regenerated = 0,
  double auxiliary = 60,
  double seconds = 60,
  double speedDistanceKm = 0,
  double odometerDistanceKm = 0,
  double speedSeconds = 0,
}) => EnergyBucket(
  start: _base.add(Duration(minutes: minute)),
  width: EnergyBucket.oneMinute,
  tractionWh: traction,
  regeneratedWh: regenerated,
  auxiliaryWh: auxiliary,
  integratedSeconds: seconds,
  speedDistanceKm: speedDistanceKm,
  odometerDistanceKm: odometerDistanceKm,
  speedIntegratedSeconds: speedSeconds,
);

class _FakeTelemetryApi extends TelemetryApi {
  /// A fake still needs a source named. Without one it inherits the channel
  /// source, whose session-change stream reaches a real `EventChannel`.
  _FakeTelemetryApi({this.buckets = const [], this.failStored = false})
    : super(
        source: MockTelemetrySource(),
        // Without a store named it inherits the Room store, which reaches a
        // real Pigeon channel.
        store: MockTelemetryStore(
          sessions: [
            chargeRecord(
              id: 'charge-before',
              startedAtUtcMillis: 0,
              plugDisconnectedAtUtcMillis: 1,
              costPerKwh: 0.92,
              costCurrency: 'BRL',
            ),
          ],
        ),
      );

  static const sessionId = 'trip-1';
  final List<EnergyBucket> buckets;
  final bool failStored;

  @override
  Future<LiveEnergyBucketsResult> getLiveEnergyBuckets() async =>
      LiveEnergyBucketsResult(
        sessionId: sessionId,
        startedAt: _base,
        buckets: const [],
      );

  @override
  Future<TelemetrySeries> getSeries(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    if (failStored) throw StateError('database unavailable');
    return TelemetrySeries(
      sessionId: id,
      intervals: [
        for (final bucket in buckets)
          intervalRecord(
            sessionId: id,
            startUtcMillis: bucket.start.millisecondsSinceEpoch,
            tractionWh: bucket.tractionWh,
            regenWh: bucket.regeneratedWh,
            auxiliaryWh: bucket.auxiliaryWh,
            climateWh: bucket.climateWh,
            // The stored row keeps one distance, and the odometer is what it
            // holds: the speed integral is a fallback the car applies before
            // it writes the minute, not a second column.
            distanceKm: bucket.odometerDistanceKm,
            coveredSeconds: bucket.integratedSeconds,
            climateCoveredSeconds: bucket.climateIntegratedSeconds,
            speedCoveredSeconds: bucket.speedIntegratedSeconds,
          ),
      ],
      samples: const {},
    );
  }

  @override
  Future<EnergyWindowBucketsResult> getEnergyBucketsInWindow(
    EnergyWindow window,
  ) async {
    if (failStored) throw StateError('database unavailable');
    return EnergyWindowBucketsResult(
      start: _base,
      end: _base.add(Duration(minutes: window.minutes!)),
      buckets: buckets,
      costPerKwh: 0.92,
      costCurrency: 'BRL',
    );
  }
}

/// A Range Drop controller with no sources behind it.
///
/// The screen's default one reads the process-wide range and vehicle
/// singletons, which reach real channels; these tests are about the layout the
/// panel sits in, so they hand it a state instead.
Future<EnergyMonitorController> _pump(
  WidgetTester tester,
  _FakeTelemetryApi api, {
  Size size = const Size(1280, 720),
  DateTime Function()? now,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final controller = EnergyMonitorController(
    telemetryApi: api,
    now:
        now ??
        () => _base.add(
          Duration(
            minutes: api.buckets.isEmpty ? 0 : api.buckets.length - 1,
            seconds: 30,
          ),
        ),
    // Long enough that no timer fires during a test; the screen is driven by
    // explicit refreshes instead.
    livePollInterval: const Duration(hours: 1),
    storedReloadInterval: const Duration(hours: 1),
  );
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: TripsV2Screen(title: 'Trips', controller: controller),
      ),
    ),
  );
  await controller.refresh();
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('a hidden tab does not start the energy monitor', (tester) async {
    final api = _FakeTelemetryApi();
    final controller = EnergyMonitorController(
      telemetryApi: api,
      livePollInterval: const Duration(milliseconds: 10),
      storedReloadInterval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TripsV2Screen(
            title: 'Trips',
            controller: controller,
            isActive: false,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(controller.isPolling, isFalse);
  });

  testWidgets('the drive is drawn as bars and summed in the donut', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(
      buckets: [
        for (var i = 0; i < 10; i++)
          _minute(i, traction: 600, auxiliary: 60, regenerated: i * 10),
      ],
    );
    await _pump(tester, api);

    final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
    expect(chart.bars, hasLength(chart.slotCount));
    expect(chart.bars.take(10).every((bar) => bar.value.isFinite), isTrue);
    expect(chart.bars.skip(10).every((bar) => bar.value.isNaN), isTrue);
    expect(chart.xTicks, hasLength(3));
    expect(chart.xTicks.map((tick) => tick.position), [0, 0.4, 0.8]);

    // Traction stacks on auxiliary; regeneration hangs below the axis rather
    // than being netted off the column.
    expect(chart.bars.first.value, closeTo(0.6, 1e-9));
    expect(chart.bars.first.base, closeTo(0.06, 1e-9));
    expect(chart.bars[5].counter, closeTo(-0.05, 1e-9));

    // The donut totals the same series: 10 × (600 + 60) Wh.
    expect(find.text('6.6'), findsOneWidget);
    final donut = tester.widget<SegmentedDonut>(find.byType(SegmentedDonut));
    expect(donut.segments, hasLength(2));
    expect(donut.innerArc, isNotNull);
  });

  testWidgets('shows power efficiency, distance, and average speed', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(
      buckets: [
        for (var i = 0; i < 10; i++)
          _minute(
            i,
            traction: 188.67924528301887,
            auxiliary: 0,
            // One distance, because the stored minute holds one.
            speedDistanceKm: 0.4,
            odometerDistanceKm: 0.4,
            speedSeconds: 32.36842105263158,
          ),
      ],
    );
    // The head unit's own width. The stats row and the footer align across the
    // card's full width, and the card is the centre column of a three-column
    // dashboard — on a 1280 px test viewport that column is narrow enough for
    // the stats to scroll, which is a viewport this screen never runs at.
    await _pump(tester, api, size: const Size(1920, 720));

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text('2.12'), findsOneWidget);
    expect(find.text(loc.unitKmPerKwh), findsOneWidget);
    expect(find.text('4.0'), findsOneWidget);
    expect(find.text(loc.unitKm), findsOneWidget);
    expect(find.text('44'), findsOneWidget);
    expect(find.text(loc.unitKmh), findsOneWidget);
    expect(find.text('\$ 1.74'), findsOneWidget);
    expect(find.text(loc.energyStatCost), findsOneWidget);

    final selectorCenter = tester.getCenter(
      find.byType(DropdownField<EnergyWindow>),
    );
    final statColumns = find.byType(StatColumn);
    expect(statColumns, findsNWidgets(4));
    for (final element in statColumns.evaluate()) {
      expect(
        tester.getCenter(find.byWidget(element.widget)).dy,
        closeTo(selectorCenter.dy, 0.01),
      );
    }

    final selectorRect = tester.getRect(
      find.byType(DropdownField<EnergyWindow>),
    );
    final statRects = [
      for (final element in statColumns.evaluate())
        tester.getRect(find.byWidget(element.widget)),
    ];
    final gaps = [
      statRects[0].left - selectorRect.right,
      statRects[1].left - statRects[0].right,
      statRects[2].left - statRects[1].right,
      statRects[3].left - statRects[2].right,
    ];
    for (final gap in gaps.skip(1)) {
      expect(gap, closeTo(gaps.first, 0.01));
    }

    final footerScroll = find.descendant(
      of: find.byType(EnergyUsePanel),
      matching: find.byType(SingleChildScrollView),
    );
    final footerRect = tester.getRect(footerScroll);
    expect(selectorRect.left, closeTo(footerRect.left, 0.01));
    expect(statRects.last.right, closeTo(footerRect.right, 0.01));
  });

  testWidgets('does not invent efficiency when distance is unavailable', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(buckets: [_minute(0)]);
    await _pump(tester, api);

    final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
    expect(chart.xTicks.first.position, 0);
    expect(chart.xTicks.last.position, 0.8);

    // Efficiency, distance, and speed stay unavailable. Cost can still use
    // the measured pack energy and the known charge rate.
    expect(find.text('--'), findsNWidgets(3));
  });

  testWidgets('window metrics use the same selected clock cut as the chart', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(
      buckets: [
        _minute(
          0,
          traction: 500,
          auxiliary: 0,
          speedDistanceKm: 1,
          odometerDistanceKm: 1,
          speedSeconds: 60,
        ),
        _minute(
          1,
          traction: 500,
          auxiliary: 0,
          speedDistanceKm: 1,
          odometerDistanceKm: 1,
          speedSeconds: 60,
        ),
      ],
    );
    final controller = await _pump(tester, api);

    controller.selectWindow(EnergyWindow.lastHour);
    await controller.refresh();
    await tester.pumpAndSettle();

    expect(find.text('2.00'), findsOneWidget);
    expect(find.text('2.0'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('\$ 0.92'), findsOneWidget);
  });

  testWidgets('the filling minute keeps its colors and says so on tap', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(
      buckets: [_minute(0), _minute(1), _minute(2, traction: 200, seconds: 20)],
    );
    await _pump(
      tester,
      api,
      now: () => _base.add(const Duration(minutes: 2, seconds: 20)),
    );

    final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
    // No column may enter gray and turn colored a minute later. Every bar is
    // drawn in its own series colors, including the one still accumulating.
    expect(
      chart.bars.every((bar) => bar.state == EnergyBarState.actual),
      isTrue,
    );
    // Each column carries the interval it plots, which is what lets the chart
    // tell an appended bar from one already on screen.
    expect(chart.bars.take(3).map((bar) => bar.id).toList(), [
      (_base, EnergyBucket.oneMinute),
      (_base.add(const Duration(minutes: 1)), EnergyBucket.oneMinute),
      (_base.add(const Duration(minutes: 2)), EnergyBucket.oneMinute),
    ]);

    // The interval being open is said in words, where it cannot be mistaken
    // for the column having a different meaning.
    final rect = tester.getRect(find.byType(EnergyBarChart));
    final pitch = AppSizes.chartBarProfile.pitch;
    await tester.tapAt(
      Offset(
        rect.left +
            AppSizes.chartAxisGutter +
            AppSizes.chartBarWidth / 2 +
            2 * pitch,
        rect.center.dy,
      ),
    );
    await tester.pumpAndSettle();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.textContaining(loc.energyBarOpen), findsOneWidget);
  });

  testWidgets('an unusable auxiliary residual leaves the ring to traction', (
    tester,
  ) async {
    // `pack - drive` can come out negative. That is a reading the split cannot
    // use, not a share of the ring.
    final api = _FakeTelemetryApi(
      buckets: [for (var i = 0; i < 5; i++) _minute(i, auxiliary: -40)],
    );
    await _pump(tester, api);

    final donut = tester.widget<SegmentedDonut>(find.byType(SegmentedDonut));
    expect(donut.segments, hasLength(1));
    expect(donut.segments.single.color, AppColors.energyDraw);
  });

  testWidgets('an empty window says so instead of drawing an empty chart', (
    tester,
  ) async {
    await _pump(tester, _FakeTelemetryApi(buckets: const []));

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.energyChartEmpty), findsWidgets);
    expect(find.byType(EnergyBarChart), findsNothing);
  });

  testWidgets('a failed read is distinct from a car that did not drive', (
    tester,
  ) async {
    await _pump(tester, _FakeTelemetryApi(failStored: true));

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    // Both panels report the failure. Neither may claim the car did not drive:
    // the app never managed to look that up.
    expect(find.text(loc.energyChartFailed), findsNWidgets(2));
    expect(find.text(loc.energyChartEmpty), findsNothing);
  });

  testWidgets('choosing a window re-reads and relabels the selector', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(
      buckets: [for (var i = 0; i < 20; i++) _minute(i)],
    );
    final controller = await _pump(tester, api);

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.energyWindowCurrentDrive), findsOneWidget);

    await tester.tap(find.byType(DropdownField<EnergyWindow>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(loc.energyWindowLast8Hours).last);
    await tester.pumpAndSettle();

    expect(controller.window, EnergyWindow.last8Hours);
    expect(find.text(loc.energyWindowLast8Hours), findsOneWidget);
  });

  testWidgets('a pinned bar survives the once-a-second rebuild', (
    tester,
  ) async {
    // The live poll rebuilds the chart's subtree every tick. A selection owned
    // below would be dropped on each one, while the reader is still reading it.
    final api = _FakeTelemetryApi(
      buckets: [for (var i = 0; i < 8; i++) _minute(i)],
    );
    final controller = await _pump(tester, api);

    final rect = tester.getRect(find.byType(EnergyBarChart));
    final pitch = AppSizes.chartBarProfile.pitch;
    await tester.tapAt(
      Offset(
        rect.left +
            AppSizes.chartAxisGutter +
            AppSizes.chartBarWidth / 2 +
            4 * pitch,
        rect.center.dy,
      ),
    );
    await tester.pumpAndSettle();
    final pinned = tester
        .widget<EnergyBarChart>(find.byType(EnergyBarChart))
        .selectedIndex;
    expect(pinned, isNotNull);

    await controller.refresh();
    await tester.pumpAndSettle();

    expect(
      tester.widget<EnergyBarChart>(find.byType(EnergyBarChart)).selectedIndex,
      pinned,
    );
  });

  testWidgets('the session info explains every icon on the ring', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(
      buckets: [for (var i = 0; i < 5; i++) _minute(i, regenerated: 40)],
    );
    await _pump(tester, api);

    await tester.tap(
      find.descendant(
        of: find.byType(EnergySessionPanel),
        matching: find.byType(InfoIconButton),
      ),
    );
    await tester.pumpAndSettle();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.sessionDetailsInfoTitle), findsOneWidget);
    // All three, including a bucket that happens to be absent from this ring:
    // the panel is where the glyphs are learned, and a legend that comes and
    // goes with the data cannot teach them.
    expect(find.text(loc.sessionDetailsInfoTraction), findsOneWidget);
    expect(find.text(loc.sessionDetailsInfoAuxiliary), findsOneWidget);
    expect(find.text(loc.sessionDetailsInfoRegeneration), findsOneWidget);
  });

  testWidgets('the dashboard is the two-column grid, 3/4 and 1/4', (
    tester,
  ) async {
    final api = _FakeTelemetryApi(buckets: [_minute(0)]);
    await _pump(tester, api, size: const Size(1920, 720));

    // The leading column is out while issue 170 reworks Range Drop. What has
    // to hold is that the two panels that stayed kept their widths, which is
    // the whole reason TwoColumnLayout exists beside ThreeColumnLayout.
    expect(find.byType(TwoColumnLayout), findsOneWidget);
    expect(find.byType(RangeDropPanel), findsNothing);
    expect(find.byType(EnergyUsePanel), findsOneWidget);
    expect(find.byType(EnergySessionPanel), findsOneWidget);

    final energy = tester.getRect(find.byType(EnergyUsePanel));
    final session = tester.getRect(find.byType(EnergySessionPanel));

    expect(energy.right, lessThanOrEqualTo(session.left));
    expect(energy.width, closeTo(session.width * 3, 0.01));
  });

  testWidgets('the dashboard fits its narrowest supported width', (
    tester,
  ) async {
    // 960 px is the documented floor. Nothing may overflow at it.
    final api = _FakeTelemetryApi(
      buckets: [for (var i = 0; i < 60; i++) _minute(i)],
    );
    await _pump(tester, api, size: const Size(960, 600));

    expect(tester.takeException(), isNull);
  });
}
