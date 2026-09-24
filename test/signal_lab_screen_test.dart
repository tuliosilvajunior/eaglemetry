import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/can_bridge_models.dart';
import 'package:capy_energy/core/signal_lab_controller.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/signal_lab_screen.dart';

const int kSecond = 1000000000;

/// A source with a fixed schema and a settable read, so the screen can be
/// driven without a daemon.
class FakeSignalSource implements SignalLabSource {
  FakeSignalSource(this.entries);

  @override
  final List<RoadcastSchemaEntry> entries;

  CanBridgeReading? next;
  int now = 10 * kSecond;
  bool alive = true;
  int connectCount = 0;
  int disposeCount = 0;

  @override
  bool get isAlive => alive;

  @override
  Future<void> connect() async => connectCount++;

  @override
  CanBridgeReading? read() => next;

  @override
  int nowNanos() => now;

  @override
  void dispose() => disposeCount++;
}

RoadcastSchemaEntry entry(
  String name, {
  required int index,
  int canId = 0x315,
  String unit = 'kW',
  bool calibrated = true,
}) {
  return RoadcastSchemaEntry(
    stableId: index,
    index: index,
    invalidSignalIndex: null,
    canId: canId,
    kind: 0,
    source: 0,
    width: 12,
    flags: calibrated ? 0x02 : 0x00,
    scale: 0.1,
    offset: -204.0,
    name: name,
    unit: unit,
  );
}

CanBridgeReading reading(
  List<double> values,
  List<int> raws,
  List<int> changeNanos, {
  List<bool>? valid,
  List<bool>? calibrated,
}) {
  final flags = Uint8List(values.length);
  for (var i = 0; i < values.length; i++) {
    flags[i] =
        ((valid?[i] ?? true) ? 0x01 : 0x00) |
        ((calibrated?[i] ?? true) ? 0x02 : 0x00);
  }
  return CanBridgeReading(
    values: values,
    raws: raws,
    timestampsNs: Int64List.fromList(changeNanos),
    flags: flags,
  );
}

Widget host(SignalLabController controller) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SignalLabScreen(controller: controller),
  );
}

void main() {
  late FakeSignalSource source;
  late SignalLabController controller;

  setUp(() {
    source = FakeSignalSource([
      entry('VCU_DrvPwrAct', index: 0),
      entry('VCU_DCDCPwrAct', index: 1, unit: '-', calibrated: false),
      entry('IPU_MOTOR_TQ', index: 2, canId: 0x111, unit: 'Nm'),
    ]);
    source.next = reading(
      [5.6, 3.0, 0.0],
      [2096, 3, 0],
      [10 * kSecond - 100000000, 10 * kSecond - 200000000, 0],
      calibrated: const [true, false, true],
    );
    controller = SignalLabController(
      source: source,
      // Long enough that no timer fires during a test; every test steps the
      // controller itself, so nothing here depends on wall-clock timing.
      inspectorInterval: const Duration(hours: 1),
    );
  });

  tearDown(() => controller.dispose());

  testWidgets('lists the signals with their tier', (tester) async {
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    expect(find.text('VCU_DrvPwrAct'), findsOneWidget);
    expect(find.text('IPU_MOTOR_TQ'), findsOneWidget);
    expect(find.text('5.600'), findsOneWidget);

    // The never-published row shows no count and no value, rather than zeros.
    expect(find.text('0x111'), findsOneWidget);
    expect(find.text('--'), findsWidgets);
  });

  testWidgets('counts the three tiers in the header', (tester) async {
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    expect(find.textContaining('2'), findsWidgets);
    expect(find.textContaining('1'), findsWidgets);
  });

  testWidgets('badges an uncalibrated signal instead of decoding it', (
    tester,
  ) async {
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.signalLabUncalibrated), findsOneWidget);
    // 3.0 is what the daemon carries, but with no negotiated scale it must not
    // be printed as a plain measurement.
    expect(find.text('3.000'), findsNothing);
  });

  testWidgets('filters by name', (tester) async {
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'DCDC');
    await tester.pump();

    expect(find.text('VCU_DCDCPwrAct'), findsOneWidget);
    expect(find.text('VCU_DrvPwrAct'), findsNothing);
  });

  testWidgets('filters by frame id', (tester) async {
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '0x111');
    await tester.pump();

    expect(find.text('IPU_MOTOR_TQ'), findsOneWidget);
    expect(find.text('VCU_DrvPwrAct'), findsNothing);
  });

  testWidgets('warns when the bridge is not connected', (tester) async {
    source.alive = false;
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.signalLabDisconnected), findsOneWidget);
  });

  testWidgets('the scope tab asks for a trace before it draws one', (
    tester,
  ) async {
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(loc.signalLabTabScope));
    await tester.pump();

    expect(find.text(loc.signalLabScopeEmpty), findsOneWidget);
  });

  testWidgets('a traced signal appears on the scope', (tester) async {
    await tester.pumpWidget(host(controller));
    controller.tick();
    await tester.pump();

    controller.toggleTrace('VCU_DrvPwrAct');
    controller.tick();
    await tester.pump();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(loc.signalLabTabScope));
    await tester.pump();

    expect(find.text('VCU_DrvPwrAct'), findsOneWidget);
    expect(find.text(loc.signalLabFreeze), findsOneWidget);
  });

  group('SignalLabController', () {
    test('refuses a fifth trace rather than dropping one', () {
      for (var i = 0; i < SignalLabController.maxTraces; i++) {
        expect(controller.toggleTrace('signal$i'), isTrue);
      }
      expect(controller.toggleTrace('one too many'), isFalse);
      expect(controller.traces.length, SignalLabController.maxTraces);

      // Removing is always allowed, and frees a slot.
      expect(controller.toggleTrace('signal0'), isTrue);
      expect(controller.toggleTrace('one too many'), isTrue);
    });

    test('freezing holds the scope but not the inspector', () async {
      controller.toggleTrace('VCU_DrvPwrAct');
      controller.tick();
      final sampled = controller.traces.single.values.length;

      controller.setFrozen(true);
      source.next = reading(
        [9.9, 3.0, 0.0],
        [2139, 3, 0],
        [10 * kSecond, 10 * kSecond, 0],
        calibrated: const [true, false, true],
      );
      controller.tick();

      expect(controller.traces.single.values.length, sampled);
      // The table keeps reading, because a frozen table that looks live is the
      // one failure a diagnostic screen must not have.
      final row = controller.rows.firstWhere((r) => r.name == 'VCU_DrvPwrAct');
      expect(row.physical, closeTo(9.9, 1e-9));
    });

    test('a missing sample is a gap in the trace, not a zero', () {
      controller.toggleTrace('IPU_MOTOR_TQ');
      controller.tick();
      expect(controller.traces.single.values, [null]);
    });

    test('traces an uncalibrated signal as counts rather than not at all', () {
      // The scope exists partly to watch VCU_ThermalPwrAct and
      // VCU_DCDCPwrAct while a scale is found for them. Plotting only decoded
      // values left both of them as flat empty traces.
      controller.toggleTrace('VCU_DCDCPwrAct');
      controller.tick();

      final trace = controller.traces.single;
      expect(trace.values, [3.0]);
      expect(trace.isCount, isTrue);
    });

    test('an empty read empties the table instead of holding stale rows', () {
      controller.tick();
      expect(controller.rows, isNotEmpty);

      source.next = null;
      controller.tick();
      expect(controller.rows, isEmpty);
    });

    test('a bridge that stops answering leaves a hole in the trace', () {
      // The outage is a fact about the window. Skipping the point rather than
      // recording a gap would let the line join across it and draw a segment
      // that nothing sent.
      final paced = SignalLabController(
        source: source,
        inspectorInterval: const Duration(hours: 1),
        scopeInterval: Duration.zero,
      );
      addTearDown(paced.dispose);

      paced.toggleTrace('VCU_DrvPwrAct');
      paced.tick();
      source.next = null;
      paced.tick();

      expect(paced.traces.single.values, [closeTo(5.6, 1e-9), null]);
    });

    test('resetting forgets the session extremes and the traces', () {
      controller.toggleTrace('VCU_DrvPwrAct');
      controller.tick();
      expect(controller.extremes.maxOf('VCU_DrvPwrAct'), closeTo(5.6, 1e-9));

      controller.resetSession();
      expect(controller.extremes.maxOf('VCU_DrvPwrAct'), isNull);
      expect(controller.traces.single.isEmpty, isTrue);
    });
  });

  group('ScopeTrace', () {
    test('keeps only the window it can show', () {
      final trace = ScopeTrace('a', capacity: 3);
      for (var i = 0; i < 5; i++) {
        trace.add(i * 1000, i.toDouble());
      }
      expect(trace.values, [2.0, 3.0, 4.0]);
      expect(trace.millis, [2000, 3000, 4000]);
    });

    test('drops a point that has aged out of the window', () {
      // The window is what the reader was promised, so age decides before
      // count does. A trace with room to spare must still forget a point that
      // is older than the span the axis draws.
      final trace = ScopeTrace(
        'a',
        capacity: 100,
        window: const Duration(seconds: 5),
      );
      trace.add(0, 1.0);
      trace.add(4000, 2.0);
      trace.add(6000, 3.0);

      expect(trace.values, [2.0, 3.0]);
      expect(trace.millis, [4000, 6000]);
    });

    test('carries the real sampling time, not an ordinal', () {
      // The sampler polls at 100 ms and records at 1 s, so points land late
      // by up to one poll and the spacing drifts. An axis built from indices
      // would report even spacing the trace never had.
      final trace = ScopeTrace('a');
      trace.add(0, 1.0);
      trace.add(1040, 2.0);
      trace.add(2130, 3.0);

      expect(trace.millis, [0, 1040, 2130]);
      expect(trace.latestMillis, 2130);
    });

    test('ignores gaps when it reports its extremes', () {
      final trace = ScopeTrace('a')
        ..add(0, 4.0)
        ..add(1000, null)
        ..add(2000, -1.0);
      expect(trace.minimum, -1.0);
      expect(trace.maximum, 4.0);
    });

    test('has no extremes when every point is a gap', () {
      final trace = ScopeTrace('a')
        ..add(0, null)
        ..add(1000, null);
      expect(trace.minimum, isNull);
      expect(trace.maximum, isNull);
    });
  });
}
