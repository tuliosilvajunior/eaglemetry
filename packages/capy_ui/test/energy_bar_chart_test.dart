import 'dart:math' as math;
import 'dart:ui' show Paragraph;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

class _Recorder implements Canvas {
  final rrects = <({RRect shape, int argb})>[];
  final lines = <({Offset from, Offset to, double strokeWidth, int argb})>[];
  final circles = <({Offset center, double radius, int argb})>[];
  final paragraphs = <({Paragraph paragraph, Offset offset})>[];
  final paths =
      <
        ({
          Path path,
          PaintingStyle style,
          double strokeWidth,
          StrokeJoin join,
          int argb,
        })
      >[];

  @override
  void drawLine(Offset from, Offset to, Paint paint) => lines.add((
    from: from,
    to: to,
    strokeWidth: paint.strokeWidth,
    argb: paint.color.toARGB32(),
  ));

  @override
  void drawRRect(RRect rrect, Paint paint) =>
      rrects.add((shape: rrect, argb: paint.color.toARGB32()));

  @override
  void drawCircle(Offset center, double radius, Paint paint) => circles.add((
    center: center,
    radius: radius,
    argb: paint.color.toARGB32(),
  ));

  @override
  void drawParagraph(Paragraph paragraph, Offset offset) =>
      paragraphs.add((paragraph: paragraph, offset: offset));

  @override
  void drawPath(Path path, Paint paint) => paths.add((
    path: path,
    style: paint.style,
    strokeWidth: paint.strokeWidth,
    join: paint.strokeJoin,
    argb: paint.color.toARGB32(),
  ));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _signedTicks = [
  ChartTick(value: 10, label: '10'),
  ChartTick(value: 0, label: '0'),
  ChartTick(value: -10, label: '+10'),
];

Widget _host(
  Widget child, {
  bool disableAnimations = false,
  double width = 500,
  double height = 300,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    ),
  );
}

_Recorder _record(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(EnergyBarChart),
          matching: find.byType(CustomPaint),
        ),
      )
      .firstWhere((value) => value.painter != null);
  final recorder = _Recorder();
  paint.painter!.paint(recorder, tester.getSize(find.byType(EnergyBarChart)));
  return recorder;
}

List<({RRect shape, int argb})> _barsOf(_Recorder recorder, Color color) =>
    recorder.rrects.where((bar) => bar.argb == color.toARGB32()).toList();

List<({Paragraph paragraph, Offset offset})> _xLabelsOf(
  _Recorder recorder,
  double height,
) => recorder.paragraphs
    .where((entry) => entry.offset.dy >= height - AppSizes.chartLabelBand)
    .toList();

void main() {
  test('three time ticks cover 0, 40, and 80 percent of the slot domain', () {
    final ticks = buildChartXTimeTicks(
      domainStart: DateTime(2026, 8, 4, 12, 23),
      bucketWidth: const Duration(minutes: 1),
      slotCount: 30,
      labelBuilder: (value) =>
          '${value.hour}:${value.minute.toString().padLeft(2, '0')}',
    );

    expect(ticks.map((tick) => tick.position), [0, 0.4, 0.8]);
    expect(ticks.map((tick) => tick.label), ['12:23', '12:35', '12:47']);
  });
  test('three relative ticks count slots in minutes, never wall stamps', () {
    final ticks = buildChartXRelativeTicks(
      bucketWidth: const Duration(minutes: 5),
      slotCount: 10,
      labelBuilder: (minutes) => '+$minutes min',
    );

    expect(ticks.map((tick) => tick.position), [0, 0.4, 0.8]);
    expect(ticks.map((tick) => tick.label), ['+0 min', '+20 min', '+40 min']);
  });

  testWidgets('signed column lengths are proportional around the zero rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [
            EnergyBar(value: 5),
            EnergyBar(value: 10),
            EnergyBar(value: -5),
          ],
        ),
      ),
    );

    final recorder = _record(tester);
    final positive = _barsOf(recorder, AppColors.energyDraw);
    final negative = _barsOf(
      recorder,
      AppColors.energyGain,
    ).single.shape.outerRect;
    expect(positive, hasLength(2));

    final short = positive[0].shape.outerRect;
    final tall = positive[1].shape.outerRect;

    // The tip is where a value is read, and it stays exact. Heights are not
    // compared: every column is held clear of the rule by a constant gap, so a
    // column's length is its value minus that gap and lengths no longer scale.
    final zero = short.bottom + AppSizes.chartZeroGap;
    expect(zero - tall.top, closeTo((zero - short.top) * 2, 0.001));

    // Both directions start from the same rule, each on its own side.
    expect(tall.bottom, closeTo(short.bottom, 0.001));
    expect(negative.top - zero, closeTo(zero - short.bottom, 0.001));
    expect(negative.bottom, greaterThan(zero));
  });

  testWidgets('stacked segments meet flush as one continuous column', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 5, base: 2)],
        ),
      ),
    );

    final recorder = _record(tester);
    final base = _barsOf(recorder, AppColors.energyDrawSubtle).single;
    final main = _barsOf(recorder, AppColors.energyDraw).single;

    // No gap at the join: the two segments touch, so one column reads as one
    // bar rather than as two floating pills.
    expect(
      base.shape.outerRect.top,
      closeTo(main.shape.outerRect.bottom, 0.001),
    );

    // Square where they meet, capped at the outer ends.
    expect(base.shape.tlRadiusY, 0);
    expect(base.shape.blRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
    expect(main.shape.tlRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
    expect(main.shape.blRadiusY, 0);
  });

  testWidgets('three stacked segments read from the axis in order', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 5, base: 2, mid: 1)],
        ),
      ),
    );

    final recorder = _record(tester);
    final base = _barsOf(recorder, AppColors.energyDrawSubtle).single;
    final mid = _barsOf(recorder, AppColors.energyDrawSoft).single;
    final main = _barsOf(recorder, AppColors.energyDraw).single;

    // Stacked in the order the caller gave them, reading up from the axis.
    expect(
      mid.shape.outerRect.bottom,
      closeTo(base.shape.outerRect.top, 0.001),
    );
    expect(
      main.shape.outerRect.bottom,
      closeTo(mid.shape.outerRect.top, 0.001),
    );

    // Only the two outer ends are capped; both joins stay square, so the three
    // segments read as one column rather than three floating pills.
    expect(base.shape.blRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
    expect(base.shape.tlRadiusY, 0);
    expect(mid.shape.blRadiusY, 0);
    expect(mid.shape.tlRadiusY, 0);
    expect(main.shape.blRadiusY, 0);
    expect(main.shape.tlRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
  });

  testWidgets('the middle segment takes the axis without a base under it', (
    tester,
  ) async {
    // A minute whose whole remainder was attributed leaves no unnamed foot.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 5, base: 0, mid: 2)],
        ),
      ),
    );

    final recorder = _record(tester);
    expect(_barsOf(recorder, AppColors.energyDrawSubtle), isEmpty);
    final mid = _barsOf(recorder, AppColors.energyDrawSoft).single;
    final main = _barsOf(recorder, AppColors.energyDraw).single;

    // It is now the segment on the rule, so it takes the capped end the base
    // would have had.
    expect(mid.shape.blRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
    expect(mid.shape.tlRadiusY, 0);
    expect(
      main.shape.outerRect.bottom,
      closeTo(mid.shape.outerRect.top, 0.001),
    );
  });

  testWidgets('a middle segment against the column direction is dropped', (
    tester,
  ) async {
    // The same rule the base follows: a negative share is a reading the stack
    // cannot use, not a column that grows downward.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 5, base: 2, mid: -1)],
        ),
      ),
    );

    final recorder = _record(tester);
    expect(_barsOf(recorder, AppColors.energyDrawSoft), isEmpty);
    final base = _barsOf(recorder, AppColors.energyDrawSubtle).single;
    final main = _barsOf(recorder, AppColors.energyDraw).single;
    expect(
      main.shape.outerRect.bottom,
      closeTo(base.shape.outerRect.top, 0.001),
    );
  });

  testWidgets('columns clear the zero rule instead of sitting on it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [
            EnergyBar(value: 5, base: 2),
            EnergyBar(value: 5),
            EnergyBar(value: -5),
            EnergyBar(value: 5, counter: -3),
          ],
        ),
      ),
    );

    final recorder = _record(tester);
    // Orange: the stacked column's value, the plain one, and the one with a
    // counter. Green: the negative column and that counter.
    final up = _barsOf(recorder, AppColors.energyDraw);
    final down = _barsOf(recorder, AppColors.energyGain);
    final base = _barsOf(recorder, AppColors.energyDrawSubtle).single;
    expect(up, hasLength(3));
    expect(down, hasLength(2));

    // A column reaching up and one reaching down straddle the rule with a gap
    // on each side, so the baseline stays visible between them.
    expect(
      down[0].shape.outerRect.top - up[1].shape.outerRect.bottom,
      closeTo(AppSizes.chartZeroGap * 2, 0.001),
    );

    // Everything that meets the rule takes the same stand-off, whether it is a
    // plain column, the foot of a stack, or a counter on the far side.
    final nearZero = [up[1], up[2], base];
    for (final column in nearZero) {
      expect(
        column.shape.outerRect.bottom,
        closeTo(up[1].shape.outerRect.bottom, 0.001),
        reason: 'a column was drawn onto the baseline',
      );
    }
    expect(
      down[1].shape.outerRect.top,
      closeTo(down[0].shape.outerRect.top, 0.001),
    );

    // The stacked column's value starts on its base, not on the rule.
    expect(
      up[0].shape.outerRect.bottom,
      closeTo(base.shape.outerRect.top, 0.001),
    );
  });

  testWidgets('a base that opposes its value is dropped, not drawn downward', (
    tester,
  ) async {
    // The auxiliary residual can come out negative. That says the measurement
    // is unusable for the foot of the column, not that the column grows the
    // other way — so the value starts from the axis in its place.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 5, base: -2)],
        ),
      ),
    );

    final recorder = _record(tester);
    expect(_barsOf(recorder, AppColors.energyDrawSubtle), isEmpty);

    final main = _barsOf(recorder, AppColors.energyDraw).single;
    // Capped at both ends and standing off the rule, exactly as an unstacked
    // column does.
    expect(main.shape.tlRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
    expect(main.shape.blRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
  });

  testWidgets('a zero base leaves the value starting from the axis', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 5), EnergyBar(value: 5, base: 0)],
        ),
      ),
    );

    final recorder = _record(tester);
    expect(_barsOf(recorder, AppColors.energyDrawSubtle), isEmpty);
    final columns = _barsOf(recorder, AppColors.energyDraw);
    expect(columns, hasLength(2));
    expect(
      columns[0].shape.outerRect.height,
      closeTo(columns[1].shape.outerRect.height, 0.001),
    );
  });

  testWidgets('pill rounding stays on its value side of the zero rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 6), EnergyBar(value: -6)],
        ),
      ),
    );

    final recorder = _record(tester);
    final positiveShape = _barsOf(recorder, AppColors.energyDraw).single.shape;
    final positive = positiveShape.outerRect;
    final negative = _barsOf(
      recorder,
      AppColors.energyGain,
    ).single.shape.outerRect;
    // Each stops short of the rule by the same gap, so neither crosses it and
    // the two never touch.
    expect(
      negative.top - positive.bottom,
      closeTo(AppSizes.chartZeroGap * 2, 0.001),
    );
    expect(positiveShape.brRadiusX, AppSizes.chartBarWidth / 2);
  });

  testWidgets('a segment shorter than its caps becomes a visible dot', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: [
            ChartTick(value: 100, label: '100'),
            ChartTick(value: 0, label: '0'),
          ],
          bars: [EnergyBar(value: 1)],
        ),
      ),
    );

    final recorder = _record(tester);
    final dot = _barsOf(recorder, AppColors.energyDraw).single;

    // Held at the floor and fully capped, so it reads as a dot — but grown
    // away from the rule rather than centred on the value, which is what used
    // to let the cap reach back across the axis.
    expect(dot.shape.outerRect.height, closeTo(AppSizes.chartBarWidth, 0.001));
    expect(dot.shape.tlRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
    expect(dot.shape.blRadiusY, closeTo(AppSizes.chartBarWidth / 2, 0.001));
  });

  testWidgets('a tiny segment never reaches back across the zero rule', (
    tester,
  ) async {
    // Every one of these is a fraction of a percent of the axis, so all three
    // land on the minimum length. None may cross the baseline.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: [
            ChartTick(value: 100, label: '100'),
            ChartTick(value: 0, label: '0'),
            ChartTick(value: -100, label: '+100'),
          ],
          bars: [
            EnergyBar(value: 40, base: 0.3),
            EnergyBar(value: 0.3),
            EnergyBar(value: 40, counter: -0.3),
          ],
        ),
      ),
    );

    final recorder = _record(tester);
    final base = _barsOf(recorder, AppColors.energyDrawSubtle).single;
    final counter = _barsOf(recorder, AppColors.energyGain).single;

    // The pale foot touches the rule from above, which fixes where the rule is.
    final zero = base.shape.outerRect.bottom + AppSizes.chartZeroGap;

    for (final bar in recorder.rrects) {
      final rect = bar.shape.outerRect;
      final staysAbove = rect.bottom <= zero - AppSizes.chartZeroGap + 0.001;
      final staysBelow = rect.top >= zero + AppSizes.chartZeroGap - 0.001;
      expect(
        staysAbove || staysBelow,
        isTrue,
        reason: 'a segment straddled the baseline',
      );
    }

    // The pale foot and the green counter sit on opposite sides of the rule,
    // each standing off it, so the baseline stays visible between them.
    expect(
      counter.shape.outerRect.top - base.shape.outerRect.bottom,
      closeTo(AppSizes.chartZeroGap * 2, 0.001),
    );
    expect(base.shape.outerRect.height, closeTo(AppSizes.chartBarWidth, 0.001));
  });

  testWidgets('a stacked value starts where its clamped base actually ended', (
    tester,
  ) async {
    // The foot is held at the floor, so it no longer ends where its value says.
    // The segment above has to start from where it really finished or the two
    // would overlap.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: [
            ChartTick(value: 100, label: '100'),
            ChartTick(value: 0, label: '0'),
          ],
          bars: [EnergyBar(value: 40, base: 0.2)],
        ),
      ),
    );

    final recorder = _record(tester);
    final base = _barsOf(recorder, AppColors.energyDrawSubtle).single;
    final main = _barsOf(recorder, AppColors.energyDraw).single;

    expect(base.shape.outerRect.height, closeTo(AppSizes.chartBarWidth, 0.001));
    expect(
      main.shape.outerRect.bottom,
      closeTo(base.shape.outerRect.top, 0.001),
    );
  });

  testWidgets('projected and now states keep actual bar geometry', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [
            EnergyBar(value: 5),
            EnergyBar(value: 5, state: EnergyBarState.projected),
            EnergyBar(value: 5, state: EnergyBarState.now),
          ],
        ),
      ),
    );

    final recorder = _record(tester);
    final actual = _barsOf(
      recorder,
      AppColors.energyDraw,
    ).single.shape.outerRect;
    final projected = _barsOf(
      recorder,
      AppChartColors.projected,
    ).single.shape.outerRect;
    final now = _barsOf(
      recorder,
      AppChartColors.nowMarker,
    ).single.shape.outerRect;
    expect(projected.size, actual.size);
    expect(now.size, actual.size);
  });

  testWidgets('overlay is the straight polyline through the supplied samples', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: [
            ChartTick(value: 10, label: '10'),
            ChartTick(value: 0, label: '0'),
          ],
          bars: [EnergyBar(value: 2), EnergyBar(value: 4), EnergyBar(value: 6)],
          overlay: [0, 5, 10],
        ),
      ),
    );

    final overlay = _record(tester).paths.singleWhere(
      (path) => path.argb == AppChartColors.overlay.toARGB32(),
    );
    expect(overlay.style, PaintingStyle.stroke);
    expect(overlay.strokeWidth, AppSizes.chartOverlayStroke);
    expect(overlay.join, StrokeJoin.round);

    // Three samples at 20px column pitch. The 0→5 and 5→10 legs each span
    // half the 264px plot height. A spline would not have this polyline length.
    final expectedLeg = math.sqrt(math.pow(20, 2) + math.pow(132, 2));
    expect(
      overlay.path.computeMetrics().single.length,
      closeTo(expectedLeg * 2, 0.01),
    );
  });

  testWidgets('an anchor extends the curve to the baseline without '
      'replacing a sample', (tester) async {
    Widget build(ChartOverlayAnchor anchor) => _host(
      EnergyBarChart(
        animate: false,
        ticks: const [
          ChartTick(value: 10, label: '10'),
          ChartTick(value: 0, label: '0'),
        ],
        bars: const [
          EnergyBar(value: 2),
          EnergyBar(value: 4),
          EnergyBar(value: 6),
        ],
        // Both edge samples sit at full height. Anchoring must add descents to
        // the baseline, never rewrite these values to zero.
        overlay: const [10, 5, 10],
        overlayAnchor: anchor,
      ),
    );

    Path pathFor(WidgetTester tester) => _record(tester).paths
        .singleWhere((path) => path.argb == AppChartColors.overlay.toARGB32())
        .path;

    await tester.pumpWidget(build(ChartOverlayAnchor.none));
    final bare = pathFor(tester).computeMetrics().single.length;

    await tester.pumpWidget(build(ChartOverlayAnchor.start));
    final started = pathFor(tester).computeMetrics().single.length;

    await tester.pumpWidget(build(ChartOverlayAnchor.both));
    final anchored = pathFor(tester).computeMetrics().single.length;

    // Each anchor adds one leg from a half-column outside the edge sample down
    // to the baseline, and the second adds the same length as the first.
    expect(started, greaterThan(bare));
    expect(anchored - started, closeTo(started - bare, 0.01));

    final leg = math.sqrt(
      math.pow(AppSizes.chartBarWidth / 2, 2) + math.pow(264, 2),
    );
    expect(started - bare, closeTo(leg, 0.01));
  });

  testWidgets('an anchor is not drawn across a missing edge interval', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        EnergyBarChart(
          animate: false,
          ticks: const [
            ChartTick(value: 10, label: '10'),
            ChartTick(value: 0, label: '0'),
          ],
          bars: const [
            EnergyBar(value: 2),
            EnergyBar(value: 4),
            EnergyBar(value: 6),
          ],
          overlay: [double.nan, 5, 10],
          overlayAnchor: ChartOverlayAnchor.both,
        ),
      ),
    );

    // The first interval has no measurement, so the curve must not descend
    // from a session boundary that was never observed. Only the closing anchor
    // is drawn, leaving a single 5→10→baseline polyline.
    final path = _record(tester).paths
        .singleWhere((path) => path.argb == AppChartColors.overlay.toARGB32())
        .path;
    expect(path.computeMetrics(), hasLength(1));
  });

  testWidgets('a new live bar animates without moving an existing bar', (
    tester,
  ) async {
    Widget build(List<EnergyBar> bars) => _host(
      EnergyBarChart(
        duration: const Duration(milliseconds: 400),
        ticks: _signedTicks,
        bars: bars,
      ),
    );

    await tester.pumpWidget(build(const [EnergyBar(id: 'a', value: 5)]));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      build(const [
        EnergyBar(id: 'a', value: 5),
        EnergyBar(id: 'b', value: 10),
      ]),
    );

    final start = _barsOf(_record(tester), AppColors.energyDraw);
    expect(start, hasLength(1));
    expect(
      start.first.shape.outerRect.height,
      closeTo(66 - AppSizes.chartZeroGap, 0.001),
    );

    await tester.pump(const Duration(milliseconds: 100));
    final entering = _barsOf(_record(tester), AppColors.energyDraw);
    expect(entering, hasLength(2));
    expect(entering.first.shape.outerRect, start.first.shape.outerRect);
    expect(
      entering.last.shape.outerRect.height,
      lessThan(132 - AppSizes.chartZeroGap),
    );

    await tester.pump(const Duration(milliseconds: 240));
    final bouncing = _barsOf(_record(tester), AppColors.energyDraw);
    expect(bouncing.first.shape.outerRect, start.first.shape.outerRect);
    expect(
      bouncing.last.shape.outerRect.height,
      greaterThan(132 - AppSizes.chartZeroGap),
    );

    await tester.pumpAndSettle();
    final settled = _barsOf(_record(tester), AppColors.energyDraw);
    expect(settled.first.shape.outerRect, start.first.shape.outerRect);
    expect(
      settled.last.shape.outerRect.height,
      closeTo(132 - AppSizes.chartZeroGap, 0.001),
    );
  });

  testWidgets('a bucket that reports a larger reading travels to it', (
    tester,
  ) async {
    Widget build(double value) => _host(
      EnergyBarChart(
        ticks: _signedTicks,
        bars: [EnergyBar(id: 'a', value: value)],
      ),
    );

    await tester.pumpWidget(build(5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(build(10));

    double height() => _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).single.shape.outerRect.height;

    const from = 66 - AppSizes.chartZeroGap;
    const to = 132 - AppSizes.chartZeroGap;
    expect(height(), closeTo(from, 0.001));

    await tester.pump(const Duration(milliseconds: 60));
    final middle = height();
    expect(middle, greaterThan(from));
    expect(middle, lessThan(to));

    // Growth carries no bounce, so the bar never passes the value it plots.
    await tester.pump(const Duration(milliseconds: 60));
    expect(height(), lessThanOrEqualTo(to));

    await tester.pumpAndSettle();
    expect(height(), closeTo(to, 0.001));
  });

  testWidgets('a reading during travel continues from where the bar stands', (
    tester,
  ) async {
    Widget build(double value) => _host(
      EnergyBarChart(
        ticks: _signedTicks,
        bars: [EnergyBar(id: 'a', value: value)],
      ),
    );

    double height() => _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).single.shape.outerRect.height;

    await tester.pumpWidget(build(5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(build(10));
    await tester.pump(const Duration(milliseconds: 90));
    final interrupted = height();

    // The next reading arrives before the bar settles. It must carry on from
    // the height on screen rather than drop back to where the last one began.
    await tester.pumpWidget(build(15));
    await tester.pump();
    expect(height(), closeTo(interrupted, 1));

    await tester.pumpAndSettle();
    expect(height(), closeTo(198 - AppSizes.chartZeroGap, 0.001));
  });

  testWidgets('a chase is still travelling when the next reading lands', (
    tester,
  ) async {
    Widget build(double value) => _host(
      EnergyBarChart(
        growth: const ChartGrowth.chase(Duration(milliseconds: 1000)),
        ticks: _signedTicks,
        bars: [EnergyBar(id: 'a', value: value)],
      ),
    );

    double height() => _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).single.shape.outerRect.height;

    await tester.pumpWidget(build(5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(build(10));

    // A settle would be over by now. A chase over one 1000 ms period is not
    // halfway, so the next reading always finds the bar in motion.
    await tester.pump(const Duration(milliseconds: 300));
    final travelling = height();
    expect(travelling, greaterThan(66 - AppSizes.chartZeroGap));
    expect(travelling, lessThan(99 - AppSizes.chartZeroGap));

    // Linear, so equal time covers equal ground. An eased curve would already
    // have spent most of its travel by 300 ms.
    await tester.pump(const Duration(milliseconds: 300));
    final later = height();
    expect(
      later - travelling,
      closeTo(travelling - (66 - AppSizes.chartZeroGap), 0.5),
    );

    // The redirection takes over from the height on screen.
    await tester.pumpWidget(build(15));
    await tester.pump();
    expect(height(), closeTo(later, 1));

    await tester.pumpAndSettle();
    expect(height(), closeTo(198 - AppSizes.chartZeroGap, 0.001));
  });

  testWidgets('new bars enter left to right and finish with a small bounce', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          duration: Duration(milliseconds: 400),
          ticks: _signedTicks,
          bars: [
            EnergyBar(id: 'a', value: 10),
            EnergyBar(id: 'b', value: 10),
            EnergyBar(id: 'c', value: 10),
          ],
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 10));
    expect(_barsOf(_record(tester), AppColors.energyDraw), hasLength(1));

    await tester.pump(const Duration(milliseconds: 18));
    expect(_barsOf(_record(tester), AppColors.energyDraw), hasLength(2));

    await tester.pump(const Duration(milliseconds: 312));
    final bouncing = _barsOf(_record(tester), AppColors.energyDraw);
    expect(bouncing, hasLength(3));
    expect(
      bouncing.first.shape.outerRect.height,
      greaterThan(132 - AppSizes.chartZeroGap),
    );

    await tester.pumpAndSettle();
    final settled = _barsOf(_record(tester), AppColors.energyDraw);
    expect(settled, hasLength(3));
    expect(
      settled.first.shape.outerRect.height,
      closeTo(132 - AppSizes.chartZeroGap, 0.001),
    );
  });

  testWidgets('a bucket-width change rebuilds the complete entrance wave', (
    tester,
  ) async {
    Widget build(List<EnergyBar> bars) => _host(
      EnergyBarChart(
        duration: const Duration(milliseconds: 400),
        ticks: _signedTicks,
        bars: bars,
      ),
    );

    await tester.pumpWidget(
      build(const [
        EnergyBar(id: (0, 1), value: 4),
        EnergyBar(id: (1, 1), value: 6),
        EnergyBar(id: (2, 1), value: 8),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      build(const [
        EnergyBar(id: (0, 2), value: 10),
        EnergyBar(id: (2, 2), value: 8),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 10));

    expect(_barsOf(_record(tester), AppColors.energyDraw), hasLength(1));
    await tester.pumpAndSettle();
    expect(_barsOf(_record(tester), AppColors.energyDraw), hasLength(2));
  });

  testWidgets('reduced motion paints the final value immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(ticks: _signedTicks, bars: [EnergyBar(value: 10)]),
        disableAnimations: true,
      ),
    );

    final bar = _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).single.shape.outerRect;
    expect(bar.height, closeTo(132 - AppSizes.chartZeroGap, 0.001));
  });

  testWidgets('tap and drag report the nearest controlled column', (
    tester,
  ) async {
    int? selected = -1;
    await tester.pumpWidget(
      _host(
        EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: const [
            EnergyBar(value: 2),
            EnergyBar(value: 4),
            EnergyBar(value: 6),
          ],
          onSelected: (value) => selected = value,
        ),
      ),
    );

    final origin = tester.getTopLeft(find.byType(EnergyBarChart));
    await tester.tapAt(origin + const Offset(75, 100));
    expect(selected, 1);

    await tester.dragFrom(origin + const Offset(95, 100), const Offset(-20, 0));
    expect(selected, 1);
  });

  testWidgets('x axis keeps exactly three supplied time anchors', (
    tester,
  ) async {
    const xTicks = [
      ChartXTick(position: 0, label: '08:00'),
      ChartXTick(position: 0.4, label: '08:24'),
      ChartXTick(position: 0.8, label: '08:48'),
    ];

    Future<List<({Paragraph paragraph, Offset offset})>> labelsAt(
      double width,
    ) async {
      await tester.pumpWidget(
        _host(
          EnergyBarChart(
            animate: false,
            ticks: _signedTicks,
            xTicks: xTicks,
            slotCount: AppSizes.chartBarProfile.slotsIn(
              width - AppSizes.chartAxisGutter,
            ),
            bars: const [
              EnergyBar(value: 2),
              EnergyBar(value: 3),
              EnergyBar(value: 4),
              EnergyBar(value: 5),
              EnergyBar(value: 6),
              EnergyBar(value: 7),
            ],
          ),
          width: width,
        ),
      );
      await tester.pumpAndSettle();
      return _xLabelsOf(_record(tester), 300);
    }

    final narrow = await labelsAt(240);
    final wide = await labelsAt(700);

    expect(narrow, hasLength(3));
    expect(wide, hasLength(3));
    expect(wide.first.offset.dx, lessThan(70));
    expect(
      wide.last.offset.dx + wide.last.paragraph.maxIntrinsicWidth,
      lessThan(620),
    );
  });

  testWidgets('a dense bar profile changes pitch without changing the plot', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          profile: AppSizes.chartDenseBarProfile,
          bars: [EnergyBar(value: 2), EnergyBar(value: 3), EnergyBar(value: 4)],
        ),
      ),
    );

    final bars = _barsOf(_record(tester), AppColors.energyDraw);
    final pitch = bars[1].shape.center.dx - bars[0].shape.center.dx;
    expect(pitch, AppSizes.chartDenseBarProfile.pitch);
    expect(bars.first.shape.width, AppSizes.chartDenseBarWidth);
  });

  testWidgets('x-axis ticks do not change the fixed bar pitch', (tester) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          xTicks: [
            ChartXTick(position: 0, label: '08:00'),
            ChartXTick(position: 0.4, label: '08:24'),
            ChartXTick(position: 0.8, label: '08:48'),
          ],
          bars: [EnergyBar(value: 2), EnergyBar(value: 3), EnergyBar(value: 4)],
        ),
      ),
    );

    final bars = _barsOf(_record(tester), AppColors.energyDraw);
    final firstGap = bars[1].shape.center.dx - bars[0].shape.center.dx;
    final secondGap = bars[2].shape.center.dx - bars[1].shape.center.dx;
    expect(firstGap, AppSizes.chartBarProfile.pitch);
    expect(secondGap, firstGap);
  });

  // `slotsIn` counts the slots and `_ChartGeometry` places them. The two state
  // the same grid from opposite sides, so this pins them together: the last
  // bar the count promises must still land inside the plot, and one more must
  // not fit. Without this, a change to either side drifts silently.
  testWidgets('the last slot the profile counts still fits the plot', (
    tester,
  ) async {
    for (final profile in [
      AppSizes.chartBarProfile,
      AppSizes.chartDenseBarProfile,
    ]) {
      for (final width in [240.0, 359.0, 500.0, 594.0, 1024.0]) {
        final slots = profile.slotsIn(width - AppSizes.chartAxisGutter);
        expect(slots, greaterThan(0), reason: 'width $width, $profile');

        await tester.pumpWidget(
          _host(
            EnergyBarChart(
              animate: false,
              ticks: _signedTicks,
              profile: profile,
              slotCount: slots,
              bars: List.filled(slots, const EnergyBar(value: 2)),
            ),
            width: width,
          ),
        );

        final bars = _barsOf(_record(tester), AppColors.energyDraw);
        expect(bars, hasLength(slots), reason: 'width $width, $profile');

        final right = bars.last.shape.center.dx + profile.width / 2;
        expect(
          right,
          lessThanOrEqualTo(width + 0.001),
          reason: 'last bar overflows at width $width, $profile',
        );

        // One more slot would not have fitted, so the count is not short.
        expect(
          AppSizes.chartAxisGutter + profile.contentWidth(slots + 1),
          greaterThan(width),
          reason: 'count is short at width $width, $profile',
        );
      }
    }
  });

  testWidgets('the first time slot starts at the left edge of the plot', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 2), EnergyBar(value: 3), EnergyBar(value: 4)],
        ),
        width: 500,
      ),
    );

    final first = _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).first.shape.center.dx;
    expect(first, AppSizes.chartAxisGutter + AppSizes.chartBarWidth / 2);
  });

  testWidgets('an empty bucket can keep an x-axis label', (tester) async {
    await tester.pumpWidget(
      _host(
        EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          slotCount: 25,
          xTicks: const [
            ChartXTick(position: 0, label: '08:00'),
            ChartXTick(position: 10 / 25, label: '08:25'),
            ChartXTick(position: 20 / 25, label: '08:50'),
          ],
          bars: const [
            EnergyBar(value: 2),
            EnergyBar(value: 3),
            EnergyBar(value: 4),
            EnergyBar(value: 5),
            EnergyBar(value: 6),
            EnergyBar(value: 7),
            EnergyBar(value: 8),
            EnergyBar(value: 7),
            EnergyBar(value: 6),
            EnergyBar(value: 5),
            EnergyBar(value: 4),
            EnergyBar(value: 3),
            EnergyBar(value: double.nan),
          ],
        ),
        width: 700,
      ),
    );

    final labels = _xLabelsOf(_record(tester), 300);
    expect(labels, hasLength(3));
    final middle = labels[1];
    expect(
      middle.offset.dx + middle.paragraph.maxIntrinsicWidth / 2,
      closeTo(
        AppSizes.chartAxisGutter +
            AppSizes.chartBarWidth / 2 +
            10 * AppSizes.chartBarProfile.pitch,
        1,
      ),
    );
  });

  testWidgets('tooltip stays inside the plot at both content edges', (
    tester,
  ) async {
    const tooltipKey = ValueKey('tooltip');
    Widget build(int selected) => _host(
      EnergyBarChart(
        animate: false,
        ticks: _signedTicks,
        bars: List.filled(8, const EnergyBar(value: 5)),
        selectedIndex: selected,
        tooltipBuilder: (context, index) => Container(
          key: tooltipKey,
          width: 100,
          height: 60,
          color: AppColors.inverseSurface,
        ),
      ),
      width: 200,
    );

    for (final selected in [0, 7]) {
      await tester.pumpWidget(build(selected));
      final chart = tester.getRect(find.byType(EnergyBarChart));
      final tooltip = tester.getRect(find.byKey(tooltipKey));
      expect(
        tooltip.left,
        greaterThanOrEqualTo(chart.left + AppSizes.chartAxisGutter),
      );
      expect(tooltip.right, lessThanOrEqualTo(chart.right));
      expect(
        tooltip.top,
        greaterThanOrEqualTo(chart.top + AppSizes.chartOverlayDot / 2),
      );
      expect(
        tooltip.bottom,
        lessThanOrEqualTo(chart.bottom - AppSizes.chartLabelBand),
      );
      final markerX =
          chart.left +
          AppSizes.chartAxisGutter +
          AppSizes.chartBarWidth / 2 +
          selected * AppSizes.chartBarProfile.pitch;
      if (selected == 0) {
        expect(
          tooltip.left,
          greaterThanOrEqualTo(
            markerX + AppSizes.chartSelectionDot / 2 + AppSizes.tooltipCaret,
          ),
        );
      } else {
        expect(
          tooltip.right,
          lessThanOrEqualTo(
            markerX - AppSizes.chartSelectionDot / 2 - AppSizes.tooltipCaret,
          ),
        );
      }
    }
  });

  testWidgets('caret survives repeated rebuilds of the selected bucket', (
    tester,
  ) async {
    const caretKey = ValueKey('energy-chart-tooltip-caret');
    Widget build() => _host(
      EnergyBarChart(
        animate: false,
        ticks: _signedTicks,
        bars: const [EnergyBar(id: 'selected', value: 5)],
        selectedIndex: 0,
        tooltipBuilder: (context, index) =>
            Container(width: 100, height: 60, color: AppColors.inverseSurface),
      ),
    );

    int caretPaths() {
      final paint = tester.widget<CustomPaint>(find.byKey(caretKey));
      final recorder = _Recorder();
      paint.painter!.paint(recorder, tester.getSize(find.byKey(caretKey)));
      return recorder.paths
          .where((path) => path.argb == AppColors.inverseSurface.toARGB32())
          .length;
    }

    await tester.pumpWidget(build());
    expect(caretPaths(), 1);

    // Drag updates can rebuild while the finger remains inside the same bucket.
    await tester.pumpWidget(build());
    expect(caretPaths(), 1);
  });

  testWidgets('selection marker is 24px and follows a valid overlay sample', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 2), EnergyBar(value: 4)],
          overlay: [8, 6],
          selectedIndex: 0,
        ),
      ),
    );

    final selection = tester
        .widgetList<ChartPinAnnotation>(find.byType(ChartPinAnnotation))
        .singleWhere((pin) => pin.dotSize == AppSizes.chartSelectionDot);
    expect(selection.dotSize, 24);
    expect(selection.dotOffset, closeTo(0.1, 0.001));
  });

  testWidgets('a data-grid reset clears the controlled selection', (
    tester,
  ) async {
    int? selected = 0;
    Widget build(EnergyBar bar) => _host(
      EnergyBarChart(
        animate: false,
        ticks: _signedTicks,
        bars: [bar],
        selectedIndex: selected,
        onSelected: (value) => selected = value,
      ),
    );

    await tester.pumpWidget(
      build(const EnergyBar(id: 'same-bucket', value: 2)),
    );
    await tester.pumpWidget(
      build(const EnergyBar(id: 'same-bucket', value: 4)),
    );
    expect(selected, 0, reason: 'a normal live update keeps the pinned bucket');
    expect(
      tester
          .widgetList<ChartPinAnnotation>(find.byType(ChartPinAnnotation))
          .where((pin) => pin.dotSize == AppSizes.chartSelectionDot),
      hasLength(1),
    );

    await tester.pumpWidget(
      build(const EnergyBar(id: 'replacement-bucket', value: 4)),
    );
    expect(selected, isNull);
    expect(find.byType(ChartPinAnnotation), findsNothing);
  });

  testWidgets('a counter segment draws on its own side of zero', (
    tester,
  ) async {
    // A drive minute both spends and recovers energy. Both are true of the same
    // minute, so the bar carries three segments rather than netting them into
    // one shorter column.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 6, base: 2, counter: -4)],
        ),
      ),
    );

    final recorder = _record(tester);
    final draw = _barsOf(recorder, AppColors.energyDraw).single.shape.outerRect;
    final base = _barsOf(
      recorder,
      AppColors.energyDrawSubtle,
    ).single.shape.outerRect;
    final gain = _barsOf(recorder, AppColors.energyGain).single.shape.outerRect;

    // The base sits at the zero end and the main segment continues past it.
    expect(base.bottom, greaterThan(draw.bottom));
    expect(draw.bottom, closeTo(base.top, 0.001));
    // The counter starts at the rule and runs the other way, standing off it by
    // the same gap the base does on its side.
    expect(gain.top - base.bottom, closeTo(AppSizes.chartZeroGap * 2, 0.001));
    expect(gain.bottom, greaterThan(gain.top));
    // All three share the column.
    expect(gain.center.dx, closeTo(draw.center.dx, 0.001));
  });

  testWidgets('the axis reaches a counter no other segment would', (
    tester,
  ) async {
    // With a single tick the axis is derived from the bars, so this is the case
    // where the counter has to be counted: without it a regenerating minute
    // would be clipped against the plot floor instead of scaling the chart.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: [ChartTick(value: 0, label: '0')],
          bars: [EnergyBar(value: 1, counter: -40)],
        ),
        height: 300,
      ),
    );

    final gain = _barsOf(
      _record(tester),
      AppColors.energyGain,
    ).single.shape.outerRect;

    expect(gain.height, greaterThan(0));
    expect(gain.bottom, lessThanOrEqualTo(300));
  });

  testWidgets('a bar with no counter is unchanged', (tester) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: [EnergyBar(value: 6, base: 2)],
        ),
      ),
    );

    expect(_barsOf(_record(tester), AppColors.energyGain), isEmpty);
  });

  testWidgets('the counter stays drawn while the chart animates', (
    tester,
  ) async {
    // The counter used to be left out of the tween, so it fell to zero for the
    // whole animation and snapped back at the end. On a live series that
    // restarts the animation every second, that reads as the regeneration bars
    // flashing on and off.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          ticks: _signedTicks,
          bars: [EnergyBar(value: 6, counter: -4)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          ticks: _signedTicks,
          bars: [EnergyBar(value: 8, counter: -4)],
        ),
      ),
    );
    // Mid-flight, where the gap used to be.
    await tester.pump(const Duration(milliseconds: 110));

    expect(_barsOf(_record(tester), AppColors.energyGain), hasLength(1));
  });

  testWidgets('an identified column keeps its height when the series slides', (
    tester,
  ) async {
    // A sliding window drops a column at the front and gains one at the back.
    // Matched by position, every surviving column would tween from its
    // neighbour's height — bars already on screen visibly re-drawing.
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          ticks: _signedTicks,
          bars: [
            EnergyBar(id: 'a', value: 2),
            EnergyBar(id: 'b', value: 6),
            EnergyBar(id: 'c', value: 10),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final settled = _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).map((bar) => bar.shape.outerRect.top).toList();

    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          ticks: _signedTicks,
          bars: [
            EnergyBar(id: 'b', value: 6),
            EnergyBar(id: 'c', value: 10),
            EnergyBar(id: 'd', value: 4),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 110));

    final moving = _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).map((bar) => bar.shape.outerRect.top).toList();
    await tester.pumpAndSettle();
    final arrived = _barsOf(
      _record(tester),
      AppColors.energyDraw,
    ).map((bar) => bar.shape.outerRect.top).toList();

    // `b` and `c` did not change, so mid-animation they are already where they
    // settle — no motion at all for a column the reader can already see.
    expect(moving[0], closeTo(settled[1], 0.01));
    expect(moving[1], closeTo(settled[2], 0.01));
    expect(moving[0], closeTo(arrived[0], 0.01));
    expect(moving[1], closeTo(arrived[1], 0.01));
    // Only the genuinely new column is still on its way up. A column grows
    // upward, so a top still below its final one means it has not arrived.
    expect(moving[2], greaterThan(arrived[2] + 1));
  });

  testWidgets('touching away from the chart closes an open reading', (
    tester,
  ) async {
    int? selected = 3;
    var calls = 0;
    Widget build() => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              width: 500,
              height: 200,
              child: EnergyBarChart(
                animate: false,
                ticks: _signedTicks,
                bars: List.filled(8, const EnergyBar(value: 5)),
                selectedIndex: selected,
                onSelected: (value) {
                  calls += 1;
                  selected = value;
                },
                tooltipBuilder: (context, index) =>
                    const SizedBox(key: ValueKey('tooltip'), width: 40),
              ),
            ),
            const SizedBox(key: ValueKey('elsewhere'), width: 500, height: 200),
          ],
        ),
      ),
    );

    await tester.pumpWidget(build());
    expect(find.byKey(const ValueKey('tooltip')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pump();

    expect(selected, isNull);
    await tester.pumpWidget(build());
    expect(find.byKey(const ValueKey('tooltip')), findsNothing);

    // With nothing open, a touch elsewhere reports nothing. Every tap in the
    // app reaches this, so a chart at rest must not rebuild its screen on
    // each one.
    final before = calls;
    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pump();
    expect(calls, before);
  });

  testWidgets('touching the axis gutter closes an open reading', (
    tester,
  ) async {
    int? selected = 3;
    await tester.pumpWidget(
      _host(
        EnergyBarChart(
          animate: false,
          ticks: _signedTicks,
          bars: List.filled(8, const EnergyBar(value: 5)),
          selectedIndex: selected,
          onSelected: (value) => selected = value,
          tooltipBuilder: (context, index) => const SizedBox(width: 40),
        ),
      ),
    );

    // The gutter carries the axis labels, not columns. It is beside the plot,
    // and it answers like anywhere else beside it.
    final chart = tester.getRect(find.byType(EnergyBarChart));
    await tester.tapAt(
      Offset(chart.left + AppSizes.chartAxisGutter / 2, chart.center.dy),
    );
    await tester.pump();

    expect(selected, isNull);
  });

  test('the identity takes part in bar equality', () {
    // Two columns with the same height are still different intervals, and the
    // chart has to notice the swap to re-key its animation.
    expect(
      const EnergyBar(id: 'a', value: 1),
      isNot(const EnergyBar(id: 'b', value: 1)),
    );
  });

  test('the counter takes part in bar equality', () {
    // `shouldRepaint` compares bars by value; a counter that changed without
    // being compared would leave a stale chart on screen.
    expect(
      const EnergyBar(value: 1, counter: -2),
      isNot(const EnergyBar(value: 1, counter: -3)),
    );
    expect(
      const EnergyBar(value: 1, counter: -2),
      const EnergyBar(value: 1, counter: -2),
    );
  });

  testWidgets('a guide stops short of the columns it meets', (tester) async {
    await tester.pumpWidget(
      _host(
        const EnergyBarChart(
          animate: false,
          ticks: [
            ChartTick(value: 10, label: '10'),
            ChartTick(value: 5, label: '5'),
            ChartTick(value: 0, label: '0'),
          ],
          bars: [EnergyBar(value: 1), EnergyBar(value: 8), EnergyBar(value: 1)],
        ),
      ),
    );

    final recorder = _record(tester);
    final columns = recorder.rrects;
    expect(columns, hasLength(3));

    List<({Offset from, Offset to, double strokeWidth, int argb})> guideAt(
      double y,
    ) => [
      for (final line in recorder.lines)
        if ((line.from.dy - y).abs() < 0.5) line,
    ];

    // No guide is ever drawn through a column, whichever guide and whichever
    // column: the grid runs behind the data.
    for (final line in recorder.lines) {
      for (final column in columns) {
        // Only where the guide and the column share a height. A bar that never
        // reaches this value is not in the way of it.
        if (line.from.dy < column.shape.top ||
            line.from.dy > column.shape.bottom) {
          continue;
        }
        expect(
          line.to.dx <= column.shape.left - AppSizes.chartGridHalo ||
              line.from.dx >= column.shape.right + AppSizes.chartGridHalo,
          isTrue,
          reason: 'a guide ran into a column',
        );
      }
    }

    // Halfway up, only the tall middle column is in the way, so that guide is
    // cut in two and picks up again on the far side of it.
    final middle = columns[1];
    final halfway = [
      for (final line in recorder.lines)
        if (line.from.dy > middle.shape.top &&
            line.from.dy < middle.shape.bottom)
          line,
    ]..sort((a, b) => a.from.dx.compareTo(b.from.dx));
    expect(halfway, hasLength(2));
    expect(halfway.first.to.dx, lessThanOrEqualTo(middle.shape.left));
    expect(halfway.last.from.dx, greaterThanOrEqualTo(middle.shape.right));

    // The top guide clears every column, so nothing cuts it.
    expect(guideAt(AppSizes.chartOverlayDot / 2), hasLength(1));
  });

  test('the axis clears the peak and lands on a round number', () {
    // A column that ends exactly on the top guide reads as a value that ran
    // out of chart. The scale steps past it instead — and to a number a reader
    // can hold, because that guide carries a label.
    expect(energyAxisTop(1.0), closeTo(1.2, 1e-9));
    expect(energyAxisTop(0.5), closeTo(0.6, 1e-9));
    expect(energyAxisTop(2.4), closeTo(3.0, 1e-9));
    expect(energyAxisTop(9.5), closeTo(12.0, 1e-9));

    // A window with nothing in it still needs a scale to divide by.
    expect(energyAxisTop(0), 1);
    expect(energyAxisTop(double.nan), 1);
  });
}
