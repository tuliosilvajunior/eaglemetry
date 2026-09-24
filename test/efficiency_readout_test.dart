import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/efficiency_readout.dart';
import 'package:capy_ui/capy_ui.dart';

EnergyBucket _bucket(
  DateTime start, {
  double traction = 100,
  Duration width = const Duration(seconds: 10),
}) => EnergyBucket(
  start: start,
  width: width,
  tractionWh: traction,
  regeneratedWh: 0,
  auxiliaryWh: 5,
  integratedSeconds: width.inSeconds.toDouble(),
  speedDistanceKm: 0.15,
  odometerDistanceKm: 0,
  speedIntegratedSeconds: width.inSeconds.toDouble(),
);

class _FakeTelemetryApi extends TelemetryApi {
  _FakeTelemetryApi({
    this.buckets = const [],
    this.width = const Duration(seconds: 10),
    this.timeUnsynced = false,
  });

  final List<EnergyBucket> buckets;
  final Duration width;
  final bool timeUnsynced;
  int calls = 0;

  @override
  Future<LiveEnergyBucketsResult> getLiveEfficiencyBuckets() async {
    calls++;
    return LiveEnergyBucketsResult(
      sessionId: 'trip-1',
      startedAt: buckets.isEmpty ? null : buckets.first.start,
      width: width,
      buckets: buckets,
      timeUnsynced: timeUnsynced,
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  TelemetryApi api, {
  CardStageController? stage,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          height: 270,
          child: EfficiencyReadout(telemetryApi: api, stage: stage),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  /// Six buckets ending on the newest boundary, at [width].
  ///
  /// They have to start on the grid. `fillEnergyBucketSlots` places a bucket by
  /// its exact slot start, so a fixture built from a bare `DateTime.now()` lands
  /// in no slot at all and reduces to an empty series — which reads as a passing
  /// test that never exercised the card.
  List<EnergyBucket> aligned({Duration width = const Duration(seconds: 10)}) {
    final end = ceilEnergyBucketBoundary(DateTime.now(), width);
    return [
      for (var index = 6; index >= 1; index--)
        _bucket(end.subtract(width * index), width: width),
    ];
  }

  testWidgets('the card reads the ten-second buckets on mount', (tester) async {
    final api = _FakeTelemetryApi(buckets: aligned());

    await _pump(tester, api);

    expect(api.calls, 1);
    expect(find.byType(EfficiencyChart), findsOneWidget);

    final chart = tester.widget<EfficiencyChart>(find.byType(EfficiencyChart));
    expect(chart.series.averageKmPerKwh, isNotNull);
  });

  testWidgets('the grid follows the width the native side states', (
    tester,
  ) async {
    // The card used to hold its own width and slot count. A native cut at a
    // different width then landed no bucket in any slot: an assert in debug, and
    // an empty card with nothing to say why in release.
    const width = Duration(seconds: 20);
    final api = _FakeTelemetryApi(
      width: width,
      buckets: aligned(width: width),
    );

    await _pump(tester, api);

    final chart = tester.widget<EfficiencyChart>(find.byType(EfficiencyChart));
    // Fifteen minutes at twenty seconds is forty-five slots, not the ninety the
    // card used to assume.
    expect(chart.series.points, hasLength(45));
    expect(
      chart.series.points.where(
        (point) => point.state != EfficiencyState.unreported,
      ),
      isNotEmpty,
    );
  });

  testWidgets(
    'the line is not given the smoothness, so it stays off the fast clock',
    (tester) async {
      await _pump(tester, _FakeTelemetryApi());

      final chart = tester.widget<EfficiencyChart>(
        find.byType(EfficiencyChart),
      );

      // The pill is composed beside the chart rather than inside it. Handing
      // the chart a `smoothness` would put the line painter inside the
      // five-times-a-second rebuild.
      expect(chart.smoothness, isNull);
      expect(find.byType(SmoothnessLevel), findsOneWidget);
    },
  );

  testWidgets('a card taking over the screen stops the polling', (
    tester,
  ) async {
    final api = _FakeTelemetryApi();
    final stage = CardStageController(vsync: const TestVSync());
    addTearDown(stage.dispose);

    await _pump(tester, api, stage: stage);
    expect(api.calls, 1);

    stage.expand();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));

    // Three poll intervals passed with the strip off screen.
    expect(api.calls, 1);

    stage.collapse();
    await tester.pumpAndSettle();

    expect(api.calls, 2);
  });

  testWidgets('no range estimate withdraws the reference instead of guessing', (
    tester,
  ) async {
    await _pump(tester, _FakeTelemetryApi());

    final chart = tester.widget<EfficiencyChart>(find.byType(EfficiencyChart));

    // Null neutral makes the chart fall back to the middle of its own axis for
    // colour. The pill is unaffected: it measures technique and takes no
    // efficiency reference, which is what removed the unit error between a
    // traction-only numerator and an SOC-derived divisor.
    expect(chart.neutral, isNull);
    expect(find.byType(SmoothnessLevel), findsOneWidget);
  });

  testWidgets('the pill says what it measures, so it cannot read as km/kWh', (
    tester,
  ) async {
    await _pump(tester, _FakeTelemetryApi());

    // The numeral on this card is km/kWh. An unlabelled pill beside it reads
    // as a second efficiency figure disagreeing with the first.
    expect(find.text('Driving smoothness'), findsOneWidget);
    expect(find.text('last 30 s'), findsOneWidget);
  });

  testWidgets('the card fits the footer it is given', (tester) async {
    // With a reading, not empty. The footer is a quarter of a 1080 screen, and
    // the numeral is the tallest thing on the card, so `--` is the one state
    // that cannot overflow.
    await _pump(tester, _FakeTelemetryApi(buckets: aligned()));

    expect(tester.takeException(), isNull);
  });

  testWidgets('the card explains itself, and says it is not the car figure', (
    tester,
  ) async {
    await _pump(tester, _FakeTelemetryApi(buckets: aligned()));

    await tester.tap(find.byType(InfoIconButton));
    await tester.pumpAndSettle();

    expect(find.byType(InformationTooltipPanel), findsOneWidget);
    // The card and the instrument cluster answer the same question in the same
    // unit and disagree, because the car averages the literal last 100 km. A
    // reader with two figures and no explanation has to decide which one lies.
    expect(find.textContaining('last 100 km'), findsOneWidget);
    expect(find.textContaining('last 15 minutes'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pill takes its speed from the VHAL, not from CAN', (
    tester,
  ) async {
    // `ESC_VehicleSpeed` was withdrawn on 2026-08-07 — it stops arriving for
    // whole trips, and a missing speed is indistinguishable from a stopped car.
    // Listening on this channel is what proves the card did not go back to it.
    var listens = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockStreamHandler(
      const EventChannel('com.timhss.capyenergy/telemetry/vehicle-speed'),
      _CountingStreamHandler(() => listens++),
    );
    addTearDown(
      () => messenger.setMockStreamHandler(
        const EventChannel('com.timhss.capyenergy/telemetry/vehicle-speed'),
        null,
      ),
    );

    await _pump(tester, _FakeTelemetryApi());
    await tester.pump();

    expect(listens, 1);
  });
  group('G5 pending series (clock late truth)', () {
    /// Six buckets on the car's birth clock: May 2025, while now is 2026.
    /// The boot-142 trip: stamps the sweeper still has to correct, served
    /// live before any truth source arrived.
    List<EnergyBucket> birthClock({
      Duration width = const Duration(seconds: 10),
    }) {
      final end = DateTime.utc(2025, 5, 24, 1, 17, 0);
      final aligned = ceilEnergyBucketBoundary(end, width);
      return [
        for (var index = 6; index >= 1; index--)
          _bucket(aligned.subtract(width * index), width: width),
      ];
    }

    testWidgets('a pending series still draws its line', (tester) async {
      await _pump(
        tester,
        _FakeTelemetryApi(buckets: birthClock(), timeUnsynced: true),
      );

      final chart = tester.widget<EfficiencyChart>(
        find.byType(EfficiencyChart),
      );
      expect(
        chart.series.points.where(
          (point) => point.state != EfficiencyState.unreported,
        ),
        isNotEmpty,
        reason: 'buckets on the birth clock grid on themselves while pending',
      );
      expect(chart.series.averageKmPerKwh, isNotNull);
    });

    testWidgets('a pending line says the time is not synced', (tester) async {
      await _pump(
        tester,
        _FakeTelemetryApi(buckets: birthClock(), timeUnsynced: true),
      );

      expect(find.textContaining('not synced'), findsOneWidget);
    });

    testWidgets('a synced series far from now keeps the old answer', (
      tester,
    ) async {
      // Stale buckets with no pending flag are a dead feed, not a lying
      // clock: the card stays empty rather than inventing a grid for them.
      await _pump(tester, _FakeTelemetryApi(buckets: birthClock()));

      final chart = tester.widget<EfficiencyChart>(
        find.byType(EfficiencyChart),
      );
      expect(
        chart.series.points.where(
          (point) => point.state != EfficiencyState.unreported,
        ),
        isEmpty,
      );
      expect(find.textContaining('not synced'), findsNothing);
    });

    testWidgets('a clock jump inside the series keeps order, never empties', (
      tester,
    ) async {
      // The native guard projects a jumped wall back onto the anchor's line,
      // so Dart can see one side on the birth clock and the other near now.
      // Anchored on the newest bucket, the grid holds the tail in order.
      final width = const Duration(seconds: 10);
      final nowEnd = ceilEnergyBucketBoundary(DateTime.now(), width);
      final buckets = [
        ...birthClock().take(3),
        for (var index = 3; index >= 1; index--)
          _bucket(nowEnd.subtract(width * index), width: width),
      ];

      await _pump(
        tester,
        _FakeTelemetryApi(buckets: buckets, timeUnsynced: true),
      );

      final chart = tester.widget<EfficiencyChart>(
        find.byType(EfficiencyChart),
      );
      final measured = chart.series.points
          .where((point) => point.state != EfficiencyState.unreported)
          .toList();
      expect(measured, isNotEmpty);
      for (var index = 1; index < measured.length; index++) {
        expect(
          measured[index].start.isAfter(measured[index - 1].start),
          isTrue,
          reason: 'a wall jump must not scramble the line order',
        );
      }
    });
  });
}

class _CountingStreamHandler extends MockStreamHandler {
  _CountingStreamHandler(this.onListenCalled);

  final void Function() onListenCalled;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) =>
      onListenCalled();

  @override
  void onCancel(Object? arguments) {}
}
