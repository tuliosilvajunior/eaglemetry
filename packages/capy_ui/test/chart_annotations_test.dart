import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

/// Canvas stub. The painters here are geometry, not pixels, so the assertions
/// read back the shapes that were requested rather than comparing images —
/// a golden would fail on a font change and say nothing about the caret.
class _Recorder implements Canvas {
  final paths = <Path>[];
  final circles = <({Offset center, double radius, int argb})>[];
  final lines = <({Offset from, Offset to, double width, int argb})>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add(path);

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((center: c, radius: radius, argb: paint.color.toARGB32()));

  @override
  void drawLine(Offset from, Offset to, Paint paint) => lines.add((
    from: from,
    to: to,
    width: paint.strokeWidth,
    argb: paint.color.toARGB32(),
  ));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The first painting `CustomPaint` under [of]. Both components keep their
/// painter private, so tests reach it through the widget tree.
CustomPainter _painterUnder(WidgetTester tester, Finder of) {
  final paints = tester.widgetList<CustomPaint>(
    find.descendant(of: of, matching: find.byType(CustomPaint)),
  );
  return paints.firstWhere((p) => p.painter != null).painter!;
}

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('ChartTooltip', () {
    testWidgets('a caret reserves its own room in the layout', (tester) async {
      const content = ChartTooltip(
        value: '10.8',
        unit: 'kW',
        side: ChartTooltipSide.none,
      );
      await _pump(tester, content);
      final bare = tester.getSize(find.byType(ChartTooltip));

      await _pump(tester, const ChartTooltip(value: '10.8', unit: 'kW'));
      final withCaret = tester.getSize(find.byType(ChartTooltip));

      expect(withCaret.width, bare.width);
      expect(withCaret.height, bare.height + AppSizes.tooltipCaret);
    });

    testWidgets('bubble and caret are drawn as one path', (tester) async {
      await _pump(tester, const ChartTooltip(value: '48%'));
      final painter = _painterUnder(tester, find.byType(ChartTooltip));
      final recorder = _Recorder();
      painter.paint(recorder, const Size(200, 80));

      // Two overlapping draws of the same opaque color would leave an
      // antialiasing seam along the edge the caret grows out of.
      expect(recorder.paths, hasLength(1));
    });

    testWidgets('caret points at the datum it is aligned to', (tester) async {
      const size = Size(200, 80);
      for (final (alignment, expected) in [
        (0.0, size.width / 2),
        (-1.0, AppRadii.md + AppSizes.tooltipCaretWidth / 2),
        (1.0, size.width - AppRadii.md - AppSizes.tooltipCaretWidth / 2),
      ]) {
        await _pump(
          tester,
          ChartTooltip(value: '48%', caretAlignment: alignment),
        );
        final recorder = _Recorder();
        _painterUnder(tester, find.byType(ChartTooltip)).paint(recorder, size);

        // Probe just inside the tip: the triangle has narrowed to a couple of
        // pixels there, so this pins the apex rather than the whole caret.
        final tip = size.height - 1;
        final path = recorder.paths.single;
        expect(path.contains(Offset(expected, tip)), isTrue);
        expect(path.contains(Offset(expected - 3, tip)), isFalse);
        expect(path.contains(Offset(expected + 3, tip)), isFalse);
      }
    });

    testWidgets('caret alignment clamps onto the flat edge', (tester) async {
      const size = Size(200, 80);
      await _pump(tester, const ChartTooltip(value: '48%', caretAlignment: 5));
      final recorder = _Recorder();
      _painterUnder(tester, find.byType(ChartTooltip)).paint(recorder, size);

      // Never on the rounded corner, no matter what the chart passes.
      final limit = size.width - AppRadii.md - AppSizes.tooltipCaretWidth / 2;
      final path = recorder.paths.single;
      expect(path.contains(Offset(limit, size.height - 1)), isTrue);
      expect(path.contains(Offset(limit + 3, size.height - 1)), isFalse);
    });

    testWidgets('side puts the caret on the matching edge', (tester) async {
      const size = Size(200, 80);
      await _pump(
        tester,
        const ChartTooltip(value: '48%', side: ChartTooltipSide.right),
      );
      final recorder = _Recorder();
      _painterUnder(tester, find.byType(ChartTooltip)).paint(recorder, size);

      final path = recorder.paths.single;
      expect(path.contains(Offset(size.width - 1, size.height / 2)), isTrue);
      expect(
        path.contains(Offset(size.width - 1, size.height / 2 + 3)),
        isFalse,
      );
    });

    testWidgets('rows carry a swatch and a right-hand value', (tester) async {
      await _pump(
        tester,
        const ChartTooltip(
          title: '14:00',
          value: '10.8',
          unit: 'kW',
          rows: [
            ChartTooltipRow(
              label: 'Consumed',
              value: '55.6 kWh',
              color: AppColors.energyDraw,
            ),
            ChartTooltipRow(label: 'No swatch'),
          ],
        ),
      );

      expect(find.text('14:00'), findsOneWidget);
      expect(find.text('Consumed'), findsOneWidget);
      expect(find.text('55.6 kWh'), findsOneWidget);

      // One swatch for two rows: the second row asked for none.
      final swatches = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(ChartTooltip),
          matching: find.byType(Container),
        ),
      );
      expect(swatches, hasLength(1));
      expect(
        (swatches.single.decoration! as BoxDecoration).color,
        AppColors.energyDraw,
      );
    });

    testWidgets('long labels wrap instead of widening past maxWidth', (
      tester,
    ) async {
      await _pump(
        tester,
        const ChartTooltip(
          value: '10.8',
          maxWidth: 200,
          rows: [
            ChartTooltipRow(
              label: 'A supporting line long enough to need more than one row',
            ),
          ],
        ),
      );

      expect(
        tester.getSize(find.byType(ChartTooltip)).width,
        lessThanOrEqualTo(200),
      );
    });

    testWidgets('a wrapped tooltip measures as tall as it draws', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 520,
              child: Align(
                child: ChartTooltip(
                  title: '14:00',
                  value: '10.8',
                  unit: 'kW',
                  maxWidth: 200,
                  rows: [
                    ChartTooltipRow(
                      label:
                          'A supporting line long enough to need more than one row',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      // A parent that measures the tooltip — an IntrinsicHeight row, a
      // scrollable — must be told the wrapped height, not the height the text
      // would have on one line. Getting this wrong lays the tooltip out shorter
      // than it paints and overflows whatever measured it.
      final box = tester.renderObject<RenderBox>(find.byType(ChartTooltip));
      expect(box.getMaxIntrinsicHeight(520), box.size.height);
    });
  });

  group('ChartPinAnnotation', () {
    const size = Size(AppSizes.chartPinDot, 200);

    _Recorder record(WidgetTester tester) {
      final recorder = _Recorder();
      _painterUnder(
        tester,
        find.byType(ChartPinAnnotation),
      ).paint(recorder, size);
      return recorder;
    }

    testWidgets('dot rides dotOffset down the rule', (tester) async {
      await _pump(
        tester,
        const ChartPinAnnotation(height: 200, dotOffset: 0.25),
      );
      final recorder = record(tester);

      expect(recorder.circles, hasLength(2));
      for (final circle in recorder.circles) {
        expect(circle.center, const Offset(AppSizes.chartPinDot / 2, 50));
      }
    });

    testWidgets('the ring sits under the dot, not beside it', (tester) async {
      await _pump(tester, const ChartPinAnnotation(height: 200));
      final recorder = record(tester);

      // Painted ring first, fill second, so the ring stays behind the center.
      final ring = recorder.circles.first;
      final dot = recorder.circles.last;
      expect(ring.argb, AppColors.ink.toARGB32());
      expect(dot.argb, AppColors.surface.toARGB32());
      expect(ring.radius, AppSizes.chartPinDot / 2);
      expect(ring.radius - dot.radius, AppSizes.chartPinRing);
    });

    testWidgets('the rule runs under the dot to the axis', (tester) async {
      await _pump(
        tester,
        const ChartPinAnnotation(height: 200, dotOffset: 0.4),
      );
      final recorder = record(tester);

      final rule = recorder.lines.single;
      expect(rule.from.dy, 0);
      expect(rule.to.dy, size.height);
      expect(rule.width, AppSizes.chartPinRule);
      expect(rule.argb, AppChartColors.nowMarker.toARGB32());
    });

    testWidgets('extendAboveDot false hangs the rule off the dot', (
      tester,
    ) async {
      await _pump(
        tester,
        const ChartPinAnnotation(
          height: 200,
          dotOffset: 0.4,
          extendAboveDot: false,
        ),
      );

      expect(record(tester).lines.single.from.dy, closeTo(80, 0.001));
    });

    testWidgets('showDot false leaves a bare rule', (tester) async {
      await _pump(
        tester,
        const ChartPinAnnotation(height: 200, showDot: false),
      );
      final recorder = record(tester);

      expect(recorder.circles, isEmpty);
      expect(recorder.lines.single.from.dy, 0);
    });

    testWidgets('dotOffset clamps to the plot', (tester) async {
      await _pump(tester, const ChartPinAnnotation(height: 200, dotOffset: 3));

      expect(record(tester).circles.first.center.dy, size.height);
    });

    testWidgets('occupies a fixed width so a chart can center it', (
      tester,
    ) async {
      await _pump(tester, const ChartPinAnnotation(height: 200));

      expect(
        tester.getSize(find.byType(ChartPinAnnotation)),
        const Size(ChartPinAnnotation.width, 200),
      );
    });
  });
}
