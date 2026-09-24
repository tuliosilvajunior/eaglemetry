import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Center(child: SizedBox(width: 300, height: 300, child: child)),
      ),
    ),
  );
}

/// Captures what the painter emits so geometry can be asserted directly,
/// without golden files. Everything other than the draw calls is discarded.
class _ArcRecorder implements Canvas {
  final arcs = <({double start, double sweep, int argb, double radius})>[];
  final paths =
      <
        ({Path path, PaintingStyle style, double strokeWidth, StrokeJoin join})
      >[];

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    arcs.add((
      start: startAngle,
      sweep: sweepAngle,
      argb: paint.color.toARGB32(),
      radius: rect.width / 2,
    ));
  }

  @override
  void drawPath(Path path, Paint paint) {
    paths.add((
      path: path,
      style: paint.style,
      strokeWidth: paint.strokeWidth,
      join: paint.strokeJoin,
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

_ArcRecorder _record(WidgetTester tester) {
  final painter = tester.widget<CustomPaint>(
    find
        .descendant(
          of: find.byType(SegmentedDonut),
          matching: find.byType(CustomPaint),
        )
        .first,
  );
  final canvas = _ArcRecorder();
  painter.painter!.paint(canvas, const Size(300, 300));
  return canvas;
}

List<({double start, double sweep, int argb, double radius})> _paintArcs(
  WidgetTester tester,
) => _record(tester).arcs;

void main() {
  testWidgets('segments sweep in proportion to their value', (tester) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          gap: 0,
          capRadius: 0,
          segments: [
            DonutSegment(value: 50, color: AppColors.energyDraw),
            DonutSegment(value: 25, color: AppColors.energyDrawSoft),
            DonutSegment(value: 25, color: AppColors.energyGain),
          ],
        ),
      ),
    );

    final arcs = _paintArcs(tester);
    expect(arcs, hasLength(3));
    expect(arcs[0].sweep, closeTo(math.pi, 0.001));
    expect(arcs[1].sweep, closeTo(math.pi / 2, 0.001));
    expect(arcs[2].sweep, closeTo(math.pi / 2, 0.001));

    // First arc opens at twelve o'clock and the ring closes on itself.
    expect(arcs.first.start, closeTo(-math.pi / 2, 0.001));
    expect(
      arcs.last.start + arcs.last.sweep,
      closeTo(-math.pi / 2 + 2 * math.pi, 0.001),
    );
  });

  testWidgets('a gap is carved between arcs but not around a lone ring', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          gap: 0.2,
          capRadius: 0,
          taper: false,
          segments: [
            DonutSegment(value: 1, color: AppColors.energyGain),
            DonutSegment(value: 1, color: AppColors.energyGainSoft),
          ],
        ),
      ),
    );
    final paired = _paintArcs(tester);
    expect(paired, hasLength(2));
    expect(paired[0].sweep, closeTo(math.pi - 0.2, 0.001));

    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          gap: 0.2,
          capRadius: 0,
          taper: false,
          segments: [DonutSegment(value: 1, color: AppColors.energyGain)],
        ),
      ),
    );
    final lone = _paintArcs(tester);
    expect(lone, hasLength(1));
    expect(lone.single.sweep, closeTo(2 * math.pi, 0.001));
  });

  testWidgets('a rebuilt marker does not restart the sweep', (tester) async {
    // A caller that builds its marker inline produces a new widget instance on
    // every rebuild. Treating that as changed data restarted the animation on
    // each tick of a live parent, which reads as a permanently flickering ring
    // and center value.
    Widget build() => _host(
      SegmentedDonut(
        value: '0.2',
        segments: [
          DonutSegment(
            value: 0.2,
            color: AppColors.energyGain,
            marker: Semantics(
              label: 'battery',
              child: const Icon(Icons.battery_full),
            ),
          ),
        ],
      ),
    );

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    final settled = _paintArcs(tester).single.sweep;

    await tester.pumpWidget(build());
    await tester.pump();

    // Still the settled ring, not a sweep restarted from zero.
    expect(_paintArcs(tester).single.sweep, closeTo(settled, 0.001));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('total turns the ring into a meter over a continuous track', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          gap: 0,
          capRadius: 0,
          total: 100,
          showTrack: true,
          segments: [DonutSegment(value: 25, color: AppColors.energyGain)],
        ),
      ),
    );

    final arcs = _paintArcs(tester);
    expect(arcs, hasLength(2));
    // The track is the whole ring, drawn first: the shortfall is what stays
    // uncovered, not a gray arc with ends of its own.
    expect(arcs[0].argb, AppColors.track.toARGB32());
    expect(arcs[0].sweep, closeTo(2 * math.pi, 0.001));
    expect(arcs[1].argb, AppColors.energyGain.toARGB32());
    expect(arcs[1].sweep, closeTo(math.pi / 2, 0.001));
  });

  testWidgets('a rounded meter keeps the track continuous under the fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          strokeWidth: 28,
          capRadius: 6,
          total: 100,
          showTrack: true,
          segments: [DonutSegment(value: 67, color: AppColors.energyGain)],
        ),
      ),
    );

    // Cap rounding applies to the fill only. The track must not pick up ends
    // of its own, which is what made the remainder read as a second category.
    final arcs = _paintArcs(tester);
    expect(arcs, hasLength(1));
    expect(arcs.single.argb, AppColors.track.toARGB32());
    expect(arcs.single.sweep, closeTo(2 * math.pi, 0.001));
    expect(_record(tester).paths, hasLength(2));
  });

  testWidgets('a ring that closes has no cap notch at the seam', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          strokeWidth: 28,
          capRadius: 6,
          segments: [DonutSegment(value: 0.2, color: AppColors.energyGain)],
        ),
      ),
    );

    // A lone full segment has no ends, so it is stroked as a closed circle
    // instead of a rounded sector shortened by two cap angles.
    final recorder = _record(tester);
    expect(recorder.paths, isEmpty);
    expect(recorder.arcs, hasLength(1));
    expect(recorder.arcs.single.sweep, closeTo(2 * math.pi, 0.001));
  });

  testWidgets('rounded caps are compensated so the gap survives them', (
    tester,
  ) async {
    const stroke = 30.0;
    const gap = 0.3;

    Widget build({required bool rounded}) => _host(
      SegmentedDonut(
        animate: false,
        gap: gap,
        taper: false,
        strokeWidth: stroke,
        capRadius: rounded ? stroke / 2 : 0,
        segments: const [
          DonutSegment(value: 2, color: AppColors.energyDraw),
          DonutSegment(value: 1, color: AppColors.energyGain),
        ],
      ),
    );

    await tester.pumpWidget(build(rounded: false));
    final butt = _paintArcs(tester);

    await tester.pumpWidget(build(rounded: true));
    final round = _paintArcs(tester);

    expect(round, hasLength(butt.length));

    // The cap bulges half a stroke past each end, so the drawn sweep has to
    // give that back on both sides for the visible gap to stay put.
    // No markers here, so no perimeter band is reserved: the stroke sits on a
    // centerline half a stroke inside the box.
    const radius = 300 / 2 - stroke / 2;
    const capAngle = stroke / 2 / radius;
    expect(capAngle, greaterThan(0.05), reason: 'compensation is not trivial');

    for (var i = 0; i < butt.length; i++) {
      expect(round[i].sweep, closeTo(butt[i].sweep - 2 * capAngle, 0.001));
      expect(round[i].start, closeTo(butt[i].start + capAngle, 0.001));
    }
  });

  testWidgets('a segment too small for its rounding collapses to a dot rather '
      'than vanishing', (tester) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          gap: 0,
          strokeWidth: 30,
          capRadius: 15,
          segments: [
            DonutSegment(value: 999, color: AppColors.energyDraw),
            DonutSegment(value: 0.4, color: AppColors.energyGain),
          ],
        ),
      ),
    );

    final arcs = _paintArcs(tester);
    expect(arcs, hasLength(2));
    expect(arcs[1].sweep, 0);
    expect(arcs[1].argb, AppColors.energyGain.toARGB32());
  });

  group('partial corner rounding', () {
    const stroke = 30.0;
    const capRadius = 6.0;
    const center = Offset(150, 150);
    const radius = 300 / 2 - stroke / 2;

    Future<_ArcRecorder> pumpHalves(
      WidgetTester tester, {
      double gap = 0,
    }) async {
      await tester.pumpWidget(
        _host(
          SegmentedDonut(
            animate: false,
            gap: gap,
            strokeWidth: stroke,
            capRadius: capRadius,
            segments: const [
              DonutSegment(value: 1, color: AppColors.energyDraw),
              DonutSegment(value: 1, color: AppColors.energyGain),
            ],
          ),
        ),
      );
      return _record(tester);
    }

    testWidgets('the arc is a dilated sector, not a stroke cap', (
      tester,
    ) async {
      final recorded = await pumpHalves(tester);

      // No stroke caps: partial rounding cannot be expressed by drawArc.
      expect(recorded.arcs, isEmpty);

      // Two segments, each filled and then grown back by a round-joined
      // stroke of exactly twice the corner radius.
      expect(recorded.paths, hasLength(4));
      expect(
        recorded.paths.where((p) => p.style == PaintingStyle.fill),
        hasLength(2),
      );
      for (final stroked in recorded.paths.where(
        (p) => p.style == PaintingStyle.stroke,
      )) {
        expect(stroked.strokeWidth, closeTo(capRadius * 2, 0.001));
        expect(stroked.join, StrokeJoin.round);
      }
    });

    testWidgets('rounding stays inside the ring instead of overshooting it', (
      tester,
    ) async {
      final recorded = await pumpHalves(tester);

      // The drawn shape is the core dilated by capRadius, so every point of
      // the core has to sit exactly that far inside the ring's edges for the
      // dilation to land back on them. Sampled along the path rather than
      // read off getBounds(), which reports conservative control-point bounds
      // and overshoots a curve by design.
      const innerLimit = radius - stroke / 2 + capRadius;
      const outerLimit = radius + stroke / 2 - capRadius;

      for (final drawn in recorded.paths) {
        for (final metric in drawn.path.computeMetrics()) {
          for (var i = 0; i <= 40; i++) {
            final point = metric
                .getTangentForOffset(metric.length * i / 40)!
                .position;
            final distance = (point - center).distance;
            expect(distance, greaterThanOrEqualTo(innerLimit - 0.5));
            expect(distance, lessThanOrEqualTo(outerLimit + 0.5));
          }
        }
      }
    });

    testWidgets('the gap survives the rounding', (tester) async {
      const gap = 0.4;
      final recorded = await pumpHalves(tester, gap: gap);
      final core = recorded.paths.first.path;

      Offset at(double angle) =>
          center + Offset(math.cos(angle), math.sin(angle)) * radius;

      // Twelve o'clock is the seam between the two halves, so it must be
      // clear; a quarter turn later is the middle of the first arc.
      expect(core.contains(at(-math.pi / 2)), isFalse);
      expect(core.contains(at(0)), isTrue);

      // And the far side of the gap belongs to neither arc.
      expect(core.contains(at(-math.pi / 2 + gap / 4)), isFalse);
    });
  });

  testWidgets('a tapered gap keeps one width, so the arc ends slant', (
    tester,
  ) async {
    const stroke = 30.0;
    const gap = 0.4;
    const center = Offset(150, 150);
    const radius = 300 / 2 - stroke / 2;

    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          gap: gap,
          strokeWidth: stroke,
          capRadius: 0,
          segments: [
            DonutSegment(value: 1, color: AppColors.energyDraw),
            DonutSegment(value: 1, color: AppColors.energyGain),
          ],
        ),
      ),
    );

    final arc = _record(tester).paths.first.path;

    // The end of the first arc on the stroke centerline. The taper is measured
    // from there: it takes angle away from the inner edge and gives the same
    // width back at the outer one.
    const end = -math.pi / 2 + math.pi - gap / 2;
    Offset at(double angle, double r) =>
        center + Offset(math.cos(angle), math.sin(angle)) * r;

    // Just short of the centerline end the arc is whole, across the stroke.
    expect(arc.contains(at(end - 0.05, radius - stroke / 2 + 2)), isTrue);
    expect(arc.contains(at(end - 0.05, radius + stroke / 2 - 2)), isTrue);

    // At the end itself only the outer half is left: the inner wall was cut
    // back first. A radial end would have stopped both at once.
    expect(arc.contains(at(end, radius - stroke / 2 + 2)), isFalse);
    expect(arc.contains(at(end, radius + stroke / 2 - 2)), isTrue);
  });

  testWidgets('the inner arc keeps square ends', (tester) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          segments: [DonutSegment(value: 3, color: AppColors.energyDraw)],
          innerArc: DonutInnerArc(value: 1, color: AppColors.energyGain),
        ),
      ),
    );

    // Rounding is what would make the inner arc read as one more slice of the
    // ring. It is stroked butt-capped instead, which drawArc expresses
    // directly — no dilated path.
    final recorded = _record(tester);
    expect(recorded.paths, isEmpty);
    final inner = recorded.arcs.last;
    expect(inner.argb, AppColors.energyGain.toARGB32());
    expect(inner.sweep, closeTo(2 * math.pi / 3, 0.001));
  });

  testWidgets('the ring sweeps up from zero on first build', (tester) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          gap: 0,
          capRadius: 0,
          duration: Duration(milliseconds: 400),
          segments: [DonutSegment(value: 1, color: AppColors.energyGain)],
        ),
      ),
    );

    // Nothing is drawn at t=0 because every value starts at zero.
    expect(_paintArcs(tester), isEmpty);

    await tester.pump(const Duration(milliseconds: 200));
    final midway = _paintArcs(tester).single.sweep;
    expect(midway, greaterThan(0));
    expect(midway, lessThan(2 * math.pi));

    await tester.pumpAndSettle();
    expect(_paintArcs(tester).single.sweep, closeTo(2 * math.pi, 0.001));
  });

  testWidgets('a value change tweens instead of snapping', (tester) async {
    Widget build(double value) => _host(
      SegmentedDonut(
        gap: 0,
        capRadius: 0,
        total: 100,
        duration: const Duration(milliseconds: 400),
        segments: [DonutSegment(value: value, color: AppColors.energyGain)],
      ),
    );

    await tester.pumpWidget(build(25));
    await tester.pumpAndSettle();
    expect(_paintArcs(tester).single.sweep, closeTo(math.pi / 2, 0.001));

    await tester.pumpWidget(build(75));
    await tester.pump(const Duration(milliseconds: 200));
    final midway = _paintArcs(tester).single.sweep;
    expect(midway, greaterThan(math.pi / 2));
    expect(midway, lessThan(3 * math.pi / 2));

    await tester.pumpAndSettle();
    expect(_paintArcs(tester).single.sweep, closeTo(3 * math.pi / 2, 0.001));
  });

  testWidgets('reduced motion renders the final state immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          gap: 0,
          capRadius: 0,
          segments: [DonutSegment(value: 1, color: AppColors.energyGain)],
        ),
        disableAnimations: true,
      ),
    );

    expect(_paintArcs(tester).single.sweep, closeTo(2 * math.pi, 0.001));
  });

  testWidgets('markers ride their arc and the center block renders', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          gap: 0,
          capRadius: 0,
          value: '60.6',
          unit: 'kWh',
          delta: '+12.2 kWh',
          segments: [
            DonutSegment(
              value: 1,
              color: AppColors.energyDraw,
              marker: Icon(Icons.grid_view),
            ),
            DonutSegment(
              value: 1,
              color: AppColors.energyGain,
              marker: Icon(Icons.trending_up),
            ),
          ],
        ),
      ),
    );

    expect(find.text('60.6'), findsOneWidget);
    expect(find.text('kWh'), findsOneWidget);
    expect(find.text('+12.2 kWh'), findsOneWidget);

    // Two equal halves starting at twelve o'clock put the first marker on the
    // right of the ring and the second on the left.
    final first = tester.getCenter(find.byIcon(Icons.grid_view));
    final second = tester.getCenter(find.byIcon(Icons.trending_up));
    final donut = tester.getCenter(find.byType(SegmentedDonut));
    expect(first.dx, greaterThan(donut.dx));
    expect(second.dx, lessThan(donut.dx));
    expect(first.dy, closeTo(donut.dy, 1));

    // Markers stay inside the widget's own bounds.
    final bounds = tester.getRect(find.byType(SegmentedDonut));
    expect(bounds.contains(first), isTrue);
    expect(bounds.contains(second), isTrue);
  });

  testWidgets('a stretched box measures the ring and its markers alike', (
    tester,
  ) async {
    // A parent that gives tight, unequal constraints — a stretched column with
    // a fixed height — cannot be squared by `AspectRatio`, which hands tight
    // constraints straight back. The painter then centered the ring on the full
    // box while the markers were placed against the shorter side, and the icons
    // drifted off their arcs and onto the ring.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 400,
              child: SegmentedDonut(
                animate: false,
                gap: 0,
                capRadius: 0,
                segments: [
                  DonutSegment(
                    value: 1,
                    color: AppColors.energyDraw,
                    marker: Icon(Icons.grid_view),
                  ),
                  DonutSegment(
                    value: 1,
                    color: AppColors.energyGain,
                    marker: Icon(Icons.trending_up),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final plot = tester.getRect(
      find
          .descendant(
            of: find.byType(SegmentedDonut),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    // The painter's box is what `size` means inside `paint`, so it has to be
    // the same square the markers are placed against.
    expect(plot.width, plot.height);
    expect(plot.width, 240);

    const markerBand = AppSizes.iconLg + AppSpacing.x2;
    final outerRadius = plot.width / 2 - markerBand;
    for (final icon in [Icons.grid_view, Icons.trending_up]) {
      final marker = tester.getCenter(find.byIcon(icon));
      expect((marker - plot.center).distance, greaterThan(outerRadius));
    }
  });

  testWidgets('the center fades in once, not on every live update', (
    tester,
  ) async {
    Widget build(double auxiliary, String value) => _host(
      SegmentedDonut(
        value: value,
        segments: [
          const DonutSegment(value: 300, color: AppColors.energyDraw),
          DonutSegment(value: auxiliary, color: AppColors.energyDrawSoft),
        ],
      ),
    );

    Iterable<double> centerOpacities(String value) => tester
        .widgetList<Opacity>(
          find.ancestor(of: find.text(value), matching: find.byType(Opacity)),
        )
        .map((widget) => widget.opacity);

    await tester.pumpWidget(build(140, '4.4'));
    await tester.pump(const Duration(milliseconds: 40));
    // The introductory sweep still resolves the value in as the ring lands.
    expect(centerOpacities('4.4').any((opacity) => opacity < 1), isTrue);
    await tester.pumpAndSettle();

    // A live caller updates this widget every second. Re-running that fade on
    // each update is read as the number blinking, not as the ring settling.
    await tester.pumpWidget(build(150, '4.5'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(centerOpacities('4.5').every((opacity) => opacity == 1), isTrue);
  });

  group('inner arc', () {
    // Regeneration is a second reading of the same total, not a slice of the
    // breakdown, so it gets its own concentric arc rather than a segment.
    const stroke = 28.0;
    const innerStroke = 14.0;
    const innerGap = 8.0;
    const ringRadius = 300 / 2 - stroke / 2;
    const innerRadius = ringRadius - stroke / 2 - innerGap - innerStroke / 2;

    Widget build({
      required double regen,
      bool animate = false,
      Duration duration = AppMotion.slow,
    }) => _host(
      SegmentedDonut(
        animate: animate,
        duration: duration,
        gap: 0,
        capRadius: 0,
        strokeWidth: stroke,
        innerStrokeWidth: innerStroke,
        innerGap: innerGap,
        segments: const [
          DonutSegment(value: 45, color: AppColors.energyDraw),
          DonutSegment(value: 15, color: AppColors.energyDrawSoft),
        ],
        innerArc: DonutInnerArc(value: regen, color: AppColors.energyGain),
      ),
    );

    testWidgets('sweeps against the ring total on a smaller radius', (
      tester,
    ) async {
      await tester.pumpWidget(build(regen: 15));

      final arcs = _paintArcs(tester);
      expect(arcs, hasLength(3));

      final inner = arcs.last;
      expect(inner.argb, AppColors.energyGain.toARGB32());

      // 15 of a 60 kWh ring is a quarter turn, measured against the segments'
      // own denominator so the two readings are directly comparable.
      expect(inner.sweep, closeTo(math.pi / 2, 0.001));
      expect(inner.start, closeTo(-math.pi / 2, 0.001));

      // And it sits inside the ring rather than on it.
      expect(inner.radius, closeTo(innerRadius, 0.001));
      expect(arcs[0].radius, closeTo(ringRadius, 0.001));
      expect(
        inner.radius + innerStroke / 2,
        lessThanOrEqualTo(ringRadius - stroke / 2),
      );
    });

    testWidgets('is absent when there is nothing to report', (tester) async {
      // No regeneration measured and no arc at all are both "no green arc",
      // and neither may borrow the ring's geometry to draw a stub.
      await tester.pumpWidget(build(regen: 0));
      expect(_paintArcs(tester), hasLength(2));

      await tester.pumpWidget(
        _host(
          const SegmentedDonut(
            animate: false,
            gap: 0,
            capRadius: 0,
            segments: [DonutSegment(value: 45, color: AppColors.energyDraw)],
          ),
        ),
      );
      expect(_paintArcs(tester), hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not displace the segments above it', (tester) async {
      // The arc shares the denominator but is not part of the series: adding
      // it must not shorten the ring it sits inside.
      await tester.pumpWidget(build(regen: 0));
      final without = _paintArcs(tester).take(2).map((a) => a.sweep).toList();

      await tester.pumpWidget(build(regen: 15));
      final with_ = _paintArcs(tester).take(2).map((a) => a.sweep).toList();

      expect(with_[0], closeTo(without[0], 0.001));
      expect(with_[1], closeTo(without[1], 0.001));
    });

    testWidgets('tweens with the ring instead of snapping', (tester) async {
      const duration = Duration(milliseconds: 400);

      await tester.pumpWidget(
        build(regen: 15, animate: true, duration: duration),
      );
      await tester.pumpAndSettle();
      expect(_paintArcs(tester).last.sweep, closeTo(math.pi / 2, 0.001));

      await tester.pumpWidget(
        build(regen: 30, animate: true, duration: duration),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final midway = _paintArcs(tester).last.sweep;
      expect(midway, greaterThan(math.pi / 2));
      expect(midway, lessThan(math.pi));

      await tester.pumpAndSettle();
      expect(_paintArcs(tester).last.sweep, closeTo(math.pi, 0.001));
    });

    testWidgets('a value beyond the total stops at a closed ring', (
      tester,
    ) async {
      // Regeneration above the energy drawn is physically impossible, but a
      // bad reading must not wrap the arc back over itself.
      await tester.pumpWidget(build(regen: 90));
      final inner = _paintArcs(tester).last;
      expect(inner.sweep, closeTo(2 * math.pi, 0.001));
      expect(inner.radius, closeTo(innerRadius, 0.001));
    });
  });

  testWidgets('an empty or zeroed ring paints nothing and does not throw', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const SegmentedDonut(animate: false, segments: [])),
    );
    expect(_paintArcs(tester), isEmpty);

    await tester.pumpWidget(
      _host(
        const SegmentedDonut(
          animate: false,
          segments: [DonutSegment(value: 0, color: AppColors.energyGain)],
        ),
      ),
    );
    expect(_paintArcs(tester), isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('the center block stays inside the ring, however small the box', (
    tester,
  ) async {
    // Small enough that the untethered block used to run straight through the
    // stroke — which is what a session card squeezed above a map looked like.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 160,
              child: SegmentedDonut(
                animate: false,
                segments: [DonutSegment(value: 1, color: AppColors.energyDraw)],
                value: '28.3',
                unit: 'kWh',
                delta: '+1.6 kWh',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ring = tester.getRect(find.byType(SegmentedDonut));
    final value = tester.getRect(find.text('28.3'));
    // The hole is what is left inside the stroke; the block has to fit the
    // square inscribed in it, so half its width must clear the ring's inner
    // edge on both axes.
    final holeRadius = 160 / 2 - AppSizes.donutStroke;
    expect(value.width / 2, lessThan(holeRadius));
    expect(value.center.dx, closeTo(ring.center.dx, 0.5));
    expect(tester.takeException(), isNull);
  });
}
