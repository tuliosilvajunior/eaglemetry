import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/energy_monitor_controller.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/trips/energy_monitor_panel.dart';
import 'package:capy_ui/capy_ui.dart';

/// A "Since power on" window with a drive, a charge and standing time all in
/// one continuous session, for the ledger footer (issue 199/210).
class _FakeLedgerApi extends TelemetryApi {
  _FakeLedgerApi()
    : super(source: MockTelemetrySource(), store: MockTelemetryStore());

  static final _base = DateTime(2026, 8, 3, 6);

  @override
  Future<LiveEnergyBucketsResult> getLiveContinuousEnergyBuckets() async =>
      LiveEnergyBucketsResult(
        sessionId: 'continuous-1',
        startedAt: _base,
        buckets: const [],
      );

  @override
  Future<TelemetrySeries> getSeries(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    return TelemetrySeries(
      sessionId: id,
      intervals: [
        IntervalRecord(
          sessionId: id,
          startUtcMillis: _base.millisecondsSinceEpoch,
          widthMillis: EnergyBucket.oneMinute.inMilliseconds,
          traction: const Measurement.measured(300, unit: 'Wh'),
          regen: const Measurement.measured(20, unit: 'Wh'),
          auxiliary: const Measurement.measured(40, unit: 'Wh'),
          climate: const Measurement.measured(0, unit: 'Wh'),
          delivered: const Measurement.measured(0, unit: 'Wh'),
          distance: const Measurement.measured(2, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 0,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
          startSoc: const Measurement.measured(82, unit: '%'),
        ),
        IntervalRecord(
          sessionId: id,
          startUtcMillis: _base
              .add(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          widthMillis: EnergyBucket.oneMinute.inMilliseconds,
          traction: const Measurement.measured(0, unit: 'Wh'),
          regen: const Measurement.measured(0, unit: 'Wh'),
          auxiliary: const Measurement.measured(5, unit: 'Wh'),
          climate: const Measurement.measured(0, unit: 'Wh'),
          delivered: const Measurement.measured(1800, unit: 'Wh'),
          distance: const Measurement.measured(0, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 0,
          speedCoveredSeconds: 0,
          deliveredCoveredSeconds: 60,
        ),
        IntervalRecord(
          sessionId: id,
          startUtcMillis: _base
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
          widthMillis: EnergyBucket.oneMinute.inMilliseconds,
          traction: const Measurement.measured(0, unit: 'Wh'),
          regen: const Measurement.measured(0, unit: 'Wh'),
          auxiliary: const Measurement.measured(8, unit: 'Wh'),
          climate: const Measurement.measured(0, unit: 'Wh'),
          delivered: const Measurement.measured(0, unit: 'Wh'),
          distance: const Measurement.measured(0, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 0,
          speedCoveredSeconds: 0,
          deliveredCoveredSeconds: 0,
          endSoc: const Measurement.measured(84, unit: '%'),
        ),
      ],
      samples: const {},
    );
  }
}

/// A "Since power on" window with one measured minute and a genuine gap a
/// PARKED span's sleep-gap estimate covers, for issue 199/211.
class _FakeLedgerApiWithSleepGap extends TelemetryApi {
  _FakeLedgerApiWithSleepGap()
    : super(source: MockTelemetrySource(), store: MockTelemetryStore());

  static final _base = DateTime(2026, 8, 3, 6);

  @override
  Future<LiveEnergyBucketsResult> getLiveContinuousEnergyBuckets() async =>
      LiveEnergyBucketsResult(
        sessionId: 'continuous-1',
        startedAt: _base,
        buckets: const [],
      );

  @override
  Future<TelemetrySeries> getSeries(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    return TelemetrySeries(
      sessionId: id,
      intervals: [
        IntervalRecord(
          sessionId: id,
          startUtcMillis: _base.millisecondsSinceEpoch,
          widthMillis: EnergyBucket.oneMinute.inMilliseconds,
          traction: const Measurement.measured(0, unit: 'Wh'),
          regen: const Measurement.measured(0, unit: 'Wh'),
          auxiliary: const Measurement.measured(2, unit: 'Wh'),
          climate: const Measurement.measured(0, unit: 'Wh'),
          delivered: const Measurement.measured(0, unit: 'Wh'),
          distance: const Measurement.measured(0, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 0,
          speedCoveredSeconds: 0,
          deliveredCoveredSeconds: 0,
        ),
      ],
      samples: const {},
    );
  }

  static const _emptyRollup = SessionRollup(
    distance: Measurement.unreported(unit: 'km'),
    traction: Measurement.unreported(unit: 'Wh'),
    regen: Measurement.unreported(unit: 'Wh'),
    auxiliary: Measurement.unreported(unit: 'Wh'),
    climate: Measurement.unreported(unit: 'Wh'),
    delivered: Measurement.unreported(unit: 'Wh'),
    integratedSeconds: Measurement.unreported(unit: 's'),
  );

  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) async {
    return SessionListPage(
      sessions: [
        SessionRecord(
          id: 'parked-1',
          vehicleId: 'v',
          kind: SessionKind.parked,
          status: 'CLOSED',
          startedAtUtcMillis: _base.millisecondsSinceEpoch,
          startedAtElapsedNanos: 0,
          endedAtUtcMillis: _base
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
          rollup: _emptyRollup,
          startOdometer: const Measurement.unreported(unit: 'km'),
          endOdometer: const Measurement.unreported(unit: 'km'),
          startSoc: const Measurement.unreported(unit: '%'),
          endSoc: const Measurement.unreported(unit: '%'),
          minSoc: const Measurement.unreported(unit: '%'),
          maxSoc: const Measurement.unreported(unit: '%'),
          startAmbientTemp: const Measurement.unreported(unit: '°C'),
          endAmbientTemp: const Measurement.unreported(unit: '°C'),
          meanAmbientTemp: const Measurement.unreported(unit: '°C'),
          createdAtUtcMillis: _base.millisecondsSinceEpoch,
          updatedAtUtcMillis: _base.millisecondsSinceEpoch,
          sleepSeconds: 60,
          sleepSocDeltaPercent: 0.5,
          sleepEnergyWhEstimate: 10,
        ),
      ],
      totalCount: 1,
      page: page ?? const PageRequest(),
      hasMore: false,
    );
  }
}

/// Reads through the real mock source rather than a hand-built fake, so the
/// panel is exercised over the same series the web build draws.
Future<EnergyMonitorController> _controller(EnergyWindow window) async {
  final controller = EnergyMonitorController(
    telemetryApi: TelemetryApi(source: MockTelemetrySource()),
  );
  controller.selectWindow(window);
  await controller.refresh();
  return controller;
}

Widget _host(
  EnergyMonitorController controller, {
  required Size size,
  Locale? locale,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => EnergyUsePanel(
              controller: controller,
              selectedIndex: null,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the track control rides in the card header', (tester) async {
    final controller = await _controller(EnergyWindow.lastHour);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller, size: const Size(1100, 420)));
    await tester.pump();

    expect(find.byType(TrackSegmentedControl<EnergyTrack>), findsOneWidget);

    // Beside the info button, not above the plot. The two share the header's
    // right-aligned slot, so they sit on the same band of the card.
    final toggle = tester.getRect(
      find.byType(TrackSegmentedControl<EnergyTrack>),
    );
    final info = tester.getRect(find.byType(InfoIconButton));
    expect(toggle.right, lessThanOrEqualTo(info.left));
    expect(toggle.center.dy, closeTo(info.center.dy, 4));

    // And right-aligned: nothing of the card lies to the right of the button.
    final card = tester.getRect(find.byType(EnergyUsePanel));
    expect(info.right, lessThan(card.right));
    expect(card.right - info.right, lessThan(48));
  });

  testWidgets('a window with no parked minute shows no control', (
    tester,
  ) async {
    // `currentDrive` is bounded by a trip, which is the one thing a parked
    // session is not, so that window can never offer the track.
    final controller = await _controller(EnergyWindow.currentDrive);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller, size: const Size(1100, 420)));
    await tester.pump();

    expect(find.byType(TrackSegmentedControl<EnergyTrack>), findsNothing);
    expect(find.byType(InfoIconButton), findsOneWidget);
  });

  testWidgets('choosing parked swaps the chart and the stats row', (
    tester,
  ) async {
    final controller = await _controller(EnergyWindow.lastHour);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller, size: const Size(1100, 420)));
    await tester.pump();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.energyStatEfficiency), findsOneWidget);

    await tester.tap(find.text(loc.energyModeParked));
    await tester.pumpAndSettle();

    expect(controller.track, EnergyTrack.parked);
    // Efficiency, distance and speed are questions about movement, so they are
    // gone rather than showing `--` under bars of a car standing still.
    expect(find.text(loc.energyStatEfficiency), findsNothing);
    expect(find.text(loc.energyStatDistance), findsNothing);
    expect(find.text(loc.energyStatParkedDrain), findsOneWidget);
    expect(find.text(loc.energyStatParkedTotal), findsOneWidget);
  });

  testWidgets('a card too narrow for the header drops the control below it', (
    tester,
  ) async {
    // The header carries the title, the control and the button. The control is
    // as wide as its localized labels, so a narrow card cannot hold all three
    // and the control takes its own row rather than clipping.
    final controller = await _controller(EnergyWindow.lastHour);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller, size: const Size(400, 420)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    final toggle = tester.getRect(
      find.byType(TrackSegmentedControl<EnergyTrack>),
    );
    final info = tester.getRect(find.byType(InfoIconButton));
    expect(toggle.top, greaterThan(info.bottom));
    // Still right-aligned, so it stays under the button it came from.
    expect(toggle.right, closeTo(info.right, 24));
  });

  for (final locale in [Locale('en'), Locale('pt'), Locale('ru')]) {
    testWidgets('the header holds the control at car width in $locale', (
      tester,
    ) async {
      // Portuguese is the widest of the three by a long way — 429 px against
      // 283 in English — so a placement that fits only in English would look
      // right here and be wrong on the owner's own car.
      final controller = await _controller(EnergyWindow.lastHour);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(controller, size: const Size(1100, 420), locale: locale),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final toggle = tester.getRect(
        find.byType(TrackSegmentedControl<EnergyTrack>),
      );
      final info = tester.getRect(find.byType(InfoIconButton));
      expect(toggle.center.dy, closeTo(info.center.dy, 4));
    });
  }

  group('ledger footer (issue 199/210)', () {
    testWidgets(
      'shows in, out and the balance over a drive, a charge and standing time',
      (tester) async {
        final controller = EnergyMonitorController(
          telemetryApi: _FakeLedgerApi(),
        );
        addTearDown(controller.dispose);
        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();

        await tester.pumpWidget(_host(controller, size: const Size(1100, 420)));
        await tester.pump();

        // in = regen (20) + delivered (1800); out = traction (300) +
        // auxiliary (40 + 5 + 8); balance = in - out.
        expect(find.text('1.82'), findsOneWidget);
        expect(find.text('0.35'), findsOneWidget);
        expect(find.text('1.47'), findsOneWidget);
        expect(find.text('82→84'), findsOneWidget);
        // Not the drive or parked footer.
        expect(find.text('Avg.'), findsNothing);
        expect(find.text('Avg. drain'), findsNothing);
        // No sleep-gap estimate folded in here, so the ledger says nothing
        // about one.
        expect(find.text('Includes the sleep estimate.'), findsNothing);
      },
    );

    testWidgets(
      'names the sleep estimate when it is folded into the total (issue '
      '199/211)',
      (tester) async {
        final controller = EnergyMonitorController(
          telemetryApi: _FakeLedgerApiWithSleepGap(),
        );
        addTearDown(controller.dispose);
        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();

        await tester.pumpWidget(_host(controller, size: const Size(1100, 420)));
        await tester.pump();

        expect(find.text('Includes the sleep estimate.'), findsOneWidget);
      },
    );
  });
}
