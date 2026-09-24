import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The chart draws its own axis, so nothing it puts on the card can be found by
/// a finder. These tests read the recorded canvas calls instead.
///
/// `paints..everything` receives every call the painter made, in order, with its
/// arguments. That gives the paragraph offsets, the path bounds and the paint on
/// each stroke, which is enough to hold the properties that inspection cannot be
/// trusted with: that a label stays on the card, that the trace does not cross
/// the text, that a gap really breaks the line, and that a reading past the
/// ceiling stops at it.
///
/// It is not a pixel test. `toImage()` hung a previous attempt, and nothing here
/// needs rasterization.
void main() {
  final origin = DateTime.utc(2026, 8, 7, 15, 0);
  const tenSeconds = Duration(seconds: 10);

  // The size the chart is pumped at, so the assertions can name the edges.
  const chartWidth = 360.0;
  const chartHeight = 148.0;

  /// Thickness of the cost line, and of the halo under it. Both are private to
  /// the painter; they are repeated here because they are what identifies a
  /// cost stroke among the guides and the demand line.
  const costStroke = 3.5;
  const costHalo = 2.5;

  EnergyBucket bucket({
    required int index,
    double tractionWh = 0,
    double regeneratedWh = 0,
    double auxiliaryWh = 0,
    double speedDistanceKm = 0,
    double integratedSeconds = 10,
  }) => EnergyBucket(
    start: origin.add(tenSeconds * index),
    width: tenSeconds,
    tractionWh: tractionWh,
    regeneratedWh: regeneratedWh,
    auxiliaryWh: auxiliaryWh,
    integratedSeconds: integratedSeconds,
    speedDistanceKm: speedDistanceKm,
    speedIntegratedSeconds: integratedSeconds,
  );

  Future<void> pump(
    WidgetTester tester,
    EfficiencySeries series, {
    DrivingSmoothness? smoothness,
    double? neutral = 8,
    String? floorLabel = 'Less range',
    String? unitLabel = 'Wh/km',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: chartWidth,
              child: EfficiencyChart(
                series: series,
                smoothness: smoothness,
                neutral: neutral,
                floorLabel: floorLabel,
                unitLabel: unitLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Every canvas call the chart made, in paint order.
  ///
  /// The predicate always accepts, so the matcher never fails here — it is used
  /// only as a way in to the recording.
  List<(Symbol, List<Object?>)> record(WidgetTester tester) {
    final calls = <(Symbol, List<Object?>)>[];
    expect(
      find.byType(EfficiencyChart),
      paints..everything((Symbol name, List<Object?> arguments) {
        calls.add((name, arguments));
        return true;
      }),
    );
    return calls;
  }

  /// Bounds of every cost stroke, identified by its thickness.
  ///
  /// The cost line is the only stroke at [costStroke]: the guides are 2.0, the
  /// demand line 1.8, and the halo under the cost line is wider by twice
  /// [costHalo]. One run produces two of these, because the line is drawn once
  /// clipped above the colour divider and once below it.
  List<Rect> costStrokes(List<(Symbol, List<Object?>)> calls) => [
    for (final (name, arguments) in calls)
      if (name == #drawPath &&
          (arguments[1] as Paint).style == PaintingStyle.stroke &&
          (arguments[1] as Paint).strokeWidth == costStroke)
        (arguments[0] as Path).getBounds(),
  ];

  /// Every label, as the rectangle its glyphs occupy.
  List<Rect> labels(List<(Symbol, List<Object?>)> calls) => [
    for (final (name, arguments) in calls)
      if (name == #drawParagraph)
        () {
          final paragraph = arguments[0] as ui.Paragraph;
          final at = arguments[1] as Offset;
          return Rect.fromLTWH(
            at.dx,
            at.dy,
            paragraph.longestLine,
            paragraph.height,
          );
        }(),
  ];

  EfficiencySeries driving(int count, {double distanceKm = 0.14}) =>
      readEfficiency([
        for (var i = 0; i < count; i++)
          bucket(index: i, tractionWh: 40, speedDistanceKm: distanceKm),
      ], window: Duration.zero);

  testWidgets('every label stays inside the chart', (tester) async {
    // The clip caption used to be anchored by its top edge on the bottom guide,
    // so three quarters of it fell off a canvas `CustomPaint` does not clip.
    await pump(tester, driving(20));

    final boxes = labels(record(tester));
    expect(boxes, hasLength(6)); // four guide numerals, the unit, the caption
    for (final box in boxes) {
      expect(box.top, greaterThanOrEqualTo(0));
      expect(box.bottom, lessThanOrEqualTo(chartHeight));
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(chartWidth));
    }
  });

  testWidgets('the axis unit does not share a row with the gain strip', (
    tester,
  ) async {
    // A stretch that gave everything back draws in the strip above zero, at the
    // trailing edge — which is where the unit is. The unit needs its own row
    // above that strip, or a long descent goes through the text.
    final series = readEfficiency([
      for (var i = 0; i < 20; i++)
        bucket(index: i, regeneratedWh: 40, speedDistanceKm: 0.14),
    ], window: Duration.zero);
    expect(series.points.map((point) => point.state).toSet(), {
      EfficiencyState.regenerating,
    });

    await pump(tester, series);
    final calls = record(tester);

    // The unit is the rightmost label; the guide numerals sit in the gutter and
    // the caption starts just past it.
    final unit = labels(calls).reduce((a, b) => a.left >= b.left ? a : b);
    final traces = costStrokes(calls);
    expect(traces, isNotEmpty);
    for (final trace in traces) {
      // The halo widens the ink beyond the path itself, so it is the top of the
      // halo that must clear the text.
      expect(trace.top - (costStroke / 2 + costHalo), greaterThan(unit.bottom));
    }
  });

  testWidgets('a lower cost draws higher on the card', (tester) async {
    // The axis descends: zero at the top. Everything else on the card — the
    // pill, the colours — assumes up is good, and a flipped axis is the only
    // reason that stays true for a "lower is better" unit.
    await pump(tester, driving(20, distanceKm: 0.5));
    final efficient = costStrokes(record(tester)).first;

    await pump(tester, driving(20, distanceKm: 0.2));
    final wasteful = costStrokes(record(tester)).first;

    expect(efficient.top, lessThan(wasteful.top));
  });

  testWidgets('a gap breaks the trace instead of drawing through it', (
    tester,
  ) async {
    // Joining across an interval the car did not report would invent driving.
    final unbroken = <EnergyBucket>[
      for (var i = 0; i < 9; i++)
        bucket(index: i, tractionWh: 40, speedDistanceKm: 0.14),
    ];
    await pump(tester, readEfficiency(unbroken, window: Duration.zero));
    final whole = costStrokes(record(tester));

    final broken = [...unbroken]..[4] = bucket(index: 4, integratedSeconds: 0);
    final series = readEfficiency(broken, window: Duration.zero);
    expect(series.points[4].state, EfficiencyState.unreported);

    await pump(tester, series);
    expect(costStrokes(record(tester)).length, greaterThan(whole.length));
  });

  testWidgets('the recovered band is drawn under both lines', (tester) async {
    // The band is what braking gave back. It is a Gouraud-shaded mesh under
    // the two lines, so either line drawn first would be buried by it.
    final series = readEfficiency([
      for (var i = 0; i < 9; i++)
        bucket(
          index: i,
          tractionWh: 40,
          regeneratedWh: 15,
          speedDistanceKm: 0.14,
        ),
    ], window: Duration.zero);

    await pump(tester, series);
    final names = [for (final (name, _) in record(tester)) name];
    final band = names.indexOf(#drawVertices);
    final firstStroke = names.indexOf(#drawPath);
    expect(band, greaterThanOrEqualTo(0));
    expect(firstStroke, greaterThanOrEqualTo(0));
    expect(band, lessThan(firstStroke));
  });

  test('the recovered band floor keeps the hue and drops to a fifth of the '
      'alpha', () {
    // `Vertices` does not expose its colours back out once built, so the
    // fade is pinned at the pure function the painter draws it from
    // instead of by inspecting the canvas call.
    const green = Color(0xFF6DC24B);
    final floor = recoveredBandFloorColor(green);
    expect(floor.r, green.r);
    expect(floor.g, green.g);
    expect(floor.b, green.b);
    expect(floor.a, closeTo(green.a * 0.2, 1e-6));
  });

  testWidgets('draws every state the reducer can produce', (tester) async {
    // One of each, read at the bucket so the states survive to the painter.
    final series = readEfficiency([
      bucket(index: 0, tractionWh: 40, speedDistanceKm: 0.14), // consuming
      bucket(index: 1, tractionWh: 0.2, speedDistanceKm: 0.14), // coasting
      bucket(index: 2, tractionWh: 40), // idle
      bucket(
        index: 3,
        regeneratedWh: 40,
        speedDistanceKm: 0.14,
      ), // regenerating
      bucket(index: 4, integratedSeconds: 0), // unreported
      bucket(index: 5), // still: reported, and reported a red light
      bucket(index: 6, tractionWh: 40, speedDistanceKm: 0.14),
    ], window: Duration.zero);

    expect(
      series.points.map((point) => point.state).toSet(),
      containsAll(EfficiencyState.values),
    );

    await pump(tester, series);
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives an empty series and a single reading', (tester) async {
    await pump(tester, EfficiencySeries.empty);
    // The axis and its captions are the whole card when there is no data. An
    // empty series used to return before the caption was drawn.
    expect(labels(record(tester)), hasLength(6));
    expect(costStrokes(record(tester)), isEmpty);

    await pump(
      tester,
      readEfficiency([bucket(index: 0, tractionWh: 40, speedDistanceKm: 0.14)]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('omits the captions it was not given', (tester) async {
    await pump(tester, driving(9), floorLabel: null, unitLabel: null);
    expect(labels(record(tester)), hasLength(4)); // the guide numerals only
  });

  testWidgets('a reference of zero does not divide by it', (tester) async {
    // `neutral` arrives in km/kWh and is used as a reciprocal. A car with no
    // usable estimate must fall back, not produce an infinite axis position.
    await pump(tester, driving(6), neutral: 0);

    for (final trace in costStrokes(record(tester))) {
      expect(trace.top.isFinite, isTrue);
      expect(trace.bottom, lessThanOrEqualTo(chartHeight));
    }
  });

  testWidgets('a cost past the ceiling clips instead of stretching the axis', (
    tester,
  ) async {
    // Crawling with a load: 3.6 km/h and 400 W is 111 Wh over ten seconds for
    // ten metres, which is 11 100 Wh/km. The axis must not follow it.
    final series = readEfficiency([
      for (var i = 0; i < 6; i++)
        bucket(index: i, tractionWh: 111, speedDistanceKm: 0.01),
    ], window: Duration.zero);

    await pump(tester, series);

    final traces = costStrokes(record(tester));
    expect(traces, isNotEmpty);
    for (final trace in traces) {
      expect(trace.bottom, lessThanOrEqualTo(chartHeight));
    }
  });

  group('the smoothness pill', () {
    const pillWidth = 26.0;
    const pillHeight = 100.0;

    Future<List<(Symbol, List<Object?>)>> pumpPill(
      WidgetTester tester,
      DrivingSmoothness smoothness,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: pillHeight,
                child: SmoothnessLevel(smoothness: smoothness),
              ),
            ),
          ),
        ),
      );
      // The marks chase their readings, so the pill is only at its new
      // position once the tweens have run out.
      await tester.pumpAndSettle();

      final calls = <(Symbol, List<Object?>)>[];
      expect(
        find.byType(SmoothnessLevel),
        paints..everything((Symbol name, List<Object?> arguments) {
          calls.add((name, arguments));
          return true;
        }),
      );
      return calls;
    }

    DrivingSmoothness measured(double standing, {double? instant}) =>
        DrivingSmoothness(
          state: SmoothnessState.measured,
          standing: standing,
          instant: instant,
          rampKwPerKm: 2 * kSmoothnessReferenceRampKwPerKm * (1 - standing),
        );

    /// The knob, or null when there is none.
    Offset? knob(List<(Symbol, List<Object?>)> calls) {
      for (final (name, arguments) in calls) {
        if (name == #drawCircle) return arguments[0] as Offset;
      }
      return null;
    }

    testWidgets('no reading leaves an empty track and no knob', (tester) async {
      // The data-honesty rule: a knob resting at the middle would read as a
      // measured neutral. There is no measurement at all here.
      final calls = await pumpPill(tester, DrivingSmoothness.unavailable);

      expect(DrivingSmoothness.unavailable.standing, isNull);
      expect(knob(calls), isNull);
      // The track and the neutral mark, and nothing filled between them.
      expect(calls.where((call) => call.$1 == #drawRect), isEmpty);
      // The track alone: no fill, so no second rounded rect.
      expect(calls.where((call) => call.$1 == #drawRRect), hasLength(1));
    });

    testWidgets('smooth fills upward and harsh downward', (tester) async {
      final gain = await pumpPill(tester, measured(0.8));
      final loss = await pumpPill(tester, measured(0.2));

      // The track is the first rounded rect and the fill the second: the fill
      // now ends in a round cap of its own around the knob, so it is no longer
      // a plain rect.
      Rect fill(List<(Symbol, List<Object?>)> calls) =>
          (calls.where((call) => call.$1 == #drawRRect).elementAt(1).$2[0]
                  as RRect)
              .outerRect;

      // The fill grows from the bottom, so a smoother reading starts higher.
      expect(fill(gain).top, lessThan(pillHeight / 2));
      expect(fill(loss).top, greaterThan(pillHeight / 2));
      expect(fill(gain).bottom, pillHeight);
      expect(fill(loss).bottom, pillHeight);

      expect(knob(gain)!.dy, lessThan(knob(loss)!.dy));
    });

    testWidgets('the knob stays inside the pill at both ends', (tester) async {
      // The same rule LimitSlider keeps: a reading at the ceiling must not look
      // like it left the control.
      for (final standing in [0.0, 1.0]) {
        final calls = await pumpPill(tester, measured(standing));
        final radius = pillWidth / 2 - 5;
        final center = knob(calls)!;
        expect(center.dy - radius, greaterThanOrEqualTo(0));
        expect(center.dy + radius, lessThanOrEqualTo(pillHeight));
      }
    });

    /// The instant tick, or null when it was not drawn.
    ///
    /// The tick is the only plain rectangle in the pill: it runs the full
    /// width and is cut by the pill's edges. The track and the fill are
    /// rounded rects, the neutral mark is a line, and the knob is a circle.
    Offset? tick(List<(Symbol, List<Object?>)> calls) {
      for (final (name, arguments) in calls) {
        if (name == #drawRect) return (arguments[0] as Rect).center;
      }
      return null;
    }

    testWidgets('no instant reading draws no tick', (tester) async {
      // A stopped car has no "now" to set against its standing. Drawing the
      // mark anyway would imply a measurement that was never taken.
      final calls = await pumpPill(tester, measured(0.7));
      expect(tick(calls), isNull);
      expect(knob(calls), isNotNull);
    });

    testWidgets('the tick sits above the knob when improving', (tester) async {
      // The gap between the two marks is the whole coaching, and it has to be
      // legible without any text: tick above knob means this moment is
      // smoother than the recent average.
      final improving = await pumpPill(tester, measured(0.3, instant: 0.9));
      final worsening = await pumpPill(tester, measured(0.9, instant: 0.3));

      expect(tick(improving)!.dy, lessThan(knob(improving)!.dy));
      expect(tick(worsening)!.dy, greaterThan(knob(worsening)!.dy));
    });

    testWidgets('the colour follows the knob, not the tick', (tester) async {
      // The defect this replaced carried one bit twice: its colour was exactly
      // its position. Here the colour is the standing, so a smooth moment
      // inside a harsh window must not turn the pill green.
      Color fillColour(List<(Symbol, List<Object?>)> calls) =>
          (calls.where((call) => call.$1 == #drawRRect).elementAt(1).$2[1]
                  as Paint)
              .color;

      final harshNow = await pumpPill(tester, measured(0.2, instant: 1.0));
      final smoothNow = await pumpPill(tester, measured(0.8, instant: 0.0));

      expect(fillColour(harshNow), isNot(fillColour(smoothNow)));
      expect(
        measured(0.2, instant: 1.0).aboveNeutral,
        isFalse,
        reason: 'a smooth instant must not lift a harsh standing',
      );
    });
  });
}
