import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

class _Recorder implements Canvas {
  final rects = <({Rect rect, int argb})>[];
  final rrects =
      <({RRect shape, int argb, PaintingStyle style, double strokeWidth})>[];
  final clipRects = <Rect>[];
  final clipRRects = <RRect>[];
  final paths = <({Path path, int argb})>[];

  @override
  void drawRect(Rect rect, Paint paint) =>
      rects.add((rect: rect, argb: paint.color.toARGB32()));

  @override
  void drawRRect(RRect rrect, Paint paint) => rrects.add((
    shape: rrect,
    argb: paint.color.toARGB32(),
    style: paint.style,
    strokeWidth: paint.strokeWidth,
  ));

  @override
  void drawPath(Path path, Paint paint) =>
      paths.add((path: path, argb: paint.color.toARGB32()));

  @override
  void clipRect(
    Rect rect, {
    ClipOp clipOp = ClipOp.intersect,
    bool doAntiAlias = true,
  }) => clipRects.add(rect);

  @override
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) =>
      clipRRects.add(rrect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _host(Widget child, {double width = 500, bool reducedMotion = false}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

_Recorder _record(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(LimitSlider),
          matching: find.byType(CustomPaint),
        ),
      )
      .firstWhere((value) => value.painter != null);
  final recorder = _Recorder();
  paint.painter!.paint(recorder, const Size(500, AppSizes.limitSliderHeight));
  return recorder;
}

LimitSlider _slider({
  double value = 80,
  double? current = 40,
  ValueChanged<double>? onChanged,
  bool animate = false,
  bool isCharging = false,
  double? chargingPowerKw,
}) {
  return LimitSlider(
    value: value,
    current: current,
    currentLabel: current?.round().toString(),
    currentUnit: '%',
    valueLabel: value.round().toString(),
    valueUnit: '%',
    caption: 'Projected range',
    isCharging: isCharging,
    chargingPowerKw: chargingPowerKw,
    semanticsLabel: 'Charge limit',
    semanticsValue: '${value.round()} percent',
    increasedValue: '${(value + 5).clamp(0, 100).round()} percent',
    decreasedValue: '${(value - 5).clamp(0, 100).round()} percent',
    animate: animate,
    onChanged: onChanged ?? (_) {},
  );
}

void main() {
  testWidgets('active charging shows moving waves and a bolt beside SOC', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_slider(isCharging: true, chargingPowerKw: 11, animate: true)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey('limitSlider.chargingIcon')),
      findsOneWidget,
    );
    final recorder = _record(tester);
    expect(recorder.paths, hasLength(3));
    expect(recorder.clipRects, contains(const Rect.fromLTRB(0, 0, 200, 88)));
    for (final wave in recorder.paths) {
      expect(wave.path.getBounds().top, lessThanOrEqualTo(0));
      expect(wave.path.getBounds().bottom, greaterThanOrEqualTo(88));
    }
  });

  testWidgets(
    'charging bolt pushes SOC right and reverses when charging stops',
    (tester) async {
      var charging = false;
      late StateSetter setHostState;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return _slider(
                isCharging: charging,
                chargingPowerKw: charging ? 48 : null,
                animate: true,
              );
            },
          ),
        ),
      );

      double iconSpace() => tester
          .getSize(find.byKey(const ValueKey('limitSlider.chargingIconSpace')))
          .width;
      double socLeft() => tester.getRect(find.text('40')).left;

      final restingSocLeft = socLeft();
      expect(iconSpace(), 0);
      expect(
        find.byKey(const ValueKey('limitSlider.chargingIcon')),
        findsNothing,
      );

      setHostState(() => charging = true);
      await tester.pump();
      await tester.pump(AppMotion.base ~/ 2);
      expect(iconSpace(), inExclusiveRange(0, AppSizes.iconMd + AppSpacing.x2));
      expect(socLeft(), greaterThan(restingSocLeft));

      await tester.pump(AppMotion.base ~/ 2);
      expect(iconSpace(), closeTo(AppSizes.iconMd + AppSpacing.x2, 0.001));

      setHostState(() => charging = false);
      await tester.pump();
      await tester.pump(AppMotion.base ~/ 2);
      expect(iconSpace(), inExclusiveRange(0, AppSizes.iconMd + AppSpacing.x2));

      await tester.pump(AppMotion.base ~/ 2);
      expect(iconSpace(), closeTo(0, 0.001));
      expect(socLeft(), closeTo(restingSocLeft, 0.001));
      expect(
        find.byKey(const ValueKey('limitSlider.chargingIcon')),
        findsNothing,
      );
      expect(_record(tester).paths, isEmpty);
    },
  );

  testWidgets('higher charging power advances the flow with a capped cadence', (
    tester,
  ) async {
    Future<double> leadingWaveX(double powerKw) async {
      await tester.pumpWidget(
        _host(
          _slider(isCharging: true, chargingPowerKw: powerKw, animate: true),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      return _record(tester).paths.first.path.getBounds().center.dx;
    }

    final slowX = await leadingWaveX(0);
    await tester.pumpWidget(const SizedBox.shrink());
    final fastX = await leadingWaveX(80);
    await tester.pumpWidget(const SizedBox.shrink());
    final aboveCeilingX = await leadingWaveX(160);

    expect(fastX, greaterThan(slowX));
    expect(aboveCeilingX, closeTo(fastX, 0.001));
  });

  testWidgets('reduced motion keeps the charging bolt and stops the waves', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _slider(isCharging: true, chargingPowerKw: 80, animate: true),
        reducedMotion: true,
      ),
    );

    expect(
      find.byKey(const ValueKey('limitSlider.chargingIcon')),
      findsOneWidget,
    );
    expect(_record(tester).paths, isEmpty);
  });

  testWidgets(
    'three zones map to current and target with flat internal seams',
    (tester) async {
      await tester.pumpWidget(_host(_slider()));
      final recorder = _record(tester);

      final charged = recorder.rects.singleWhere(
        (entry) => entry.argb == AppColors.energyGain.toARGB32(),
      );
      final pending = recorder.rects.singleWhere(
        (entry) => entry.argb == AppColors.track.toARGB32(),
      );
      expect(charged.rect, const Rect.fromLTRB(0, 0, 200, 88));
      expect(pending.rect, const Rect.fromLTRB(200, 0, 373.6, 88));
      expect(charged.rect.right, pending.rect.left);

      // One rounded outer track supplies the caps. The two zones are plain
      // rectangles, so their shared boundary stays flat.
      expect(recorder.clipRRects.first.tlRadiusX, 44);

      final slider = tester.getRect(find.byType(LimitSlider));
      final knob = tester.getRect(
        find.byKey(const ValueKey('limitSlider.knob')),
      );
      expect(knob.center.dx - slider.left, closeTo(373.6, 0.001));
    },
  );

  testWidgets('beyond-target zone is an open clipped outline, not a fill', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_slider()));
    final recorder = _record(tester);
    final outline = recorder.rrects.singleWhere(
      (entry) => entry.argb == AppColors.divider.toARGB32(),
    );

    expect(outline.style, PaintingStyle.stroke);
    expect(outline.strokeWidth, AppSizes.limitSliderOutline);
    expect(outline.shape.outerRect, const Rect.fromLTRB(0, 0, 500, 88));
    expect(recorder.clipRects.single, const Rect.fromLTRB(373.6, 0, 500, 88));
    expect(recorder.rects.where((entry) => entry.rect.left >= 373.6), isEmpty);
  });

  testWidgets(
    'target below current cuts a background marker through the fill',
    (tester) async {
      await tester.pumpWidget(_host(_slider(value: 50, current: 52)));
      final recorder = _record(tester);

      final charged = recorder.rects.singleWhere(
        (entry) => entry.argb == AppColors.energyGain.toARGB32(),
      );
      expect(charged.rect, const Rect.fromLTRB(0, 0, 260, 88));
      expect(
        recorder.rects.where(
          (entry) => entry.argb == AppColors.track.toARGB32(),
        ),
        isEmpty,
      );

      final marker = recorder.rects.singleWhere(
        (entry) => entry.argb == AppColors.canvas.toARGB32(),
      );
      expect(marker.rect, const Rect.fromLTRB(246, 0, 254, 88));
      expect(recorder.clipRects.single, const Rect.fromLTRB(260, 0, 500, 88));
    },
  );

  testWidgets('10 percent guides stay inside the unfilled pill zone', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_slider(value: 50, current: 52)));
    expect(
      _record(tester).rrects.where(
        (entry) => entry.argb == AppChartColors.nowMarker.toARGB32(),
      ),
      isEmpty,
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('limitSlider.knob'))),
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await tester.pump(AppMotion.fast);
    final ticks = _record(tester).rrects
        .where((entry) => entry.argb == AppChartColors.nowMarker.toARGB32())
        .toList();

    expect(ticks, hasLength(5));
    expect(
      ticks.map((entry) => entry.shape.center.dx),
      orderedEquals([291.2, 332.4, 373.6, 414.8, 456.0]),
    );
    for (final tick in ticks) {
      expect(tick.shape.width, AppSizes.limitSliderTickWidth);
      expect(tick.shape.height, AppSizes.limitSliderTickHeight);
    }

    await gesture.up();
    await tester.pump();
    await tester.pump(AppMotion.fast);
    expect(
      _record(tester).rrects.where(
        (entry) => entry.argb == AppChartColors.nowMarker.toARGB32(),
      ),
      isEmpty,
    );
  });

  testWidgets('onDraggingChanged reports drag start and end', (tester) async {
    final draggingStates = <bool>[];
    await tester.pumpWidget(
      _host(
        LimitSlider(
          value: 50,
          current: 25,
          onChanged: (_) {},
          onDraggingChanged: draggingStates.add,
        ),
      ),
    );

    expect(draggingStates, isEmpty);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('limitSlider.knob'))),
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(draggingStates, [true]);

    await gesture.up();
    await tester.pump();
    expect(draggingStates, [true, false]);
  });

  testWidgets('step guides fade in and out instead of snapping', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_slider(value: 50, current: 52)));

    int alphaOf(int argb) => (argb >> 24) & 0xff;
    final nowRgb = AppChartColors.nowMarker.toARGB32() & 0x00ffffff;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('limitSlider.knob'))),
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await tester.pump(AppMotion.fast ~/ 2);

    final fading = _record(
      tester,
    ).rrects.where((entry) => (entry.argb & 0x00ffffff) == nowRgb).toList();
    expect(fading, isNotEmpty);
    for (final tick in fading) {
      expect(alphaOf(tick.argb), greaterThan(0));
      expect(alphaOf(tick.argb), lessThan(0xff));
    }

    await tester.pump(AppMotion.fast);
    await gesture.up();
    await tester.pump();
    await tester.pump(AppMotion.fast);
    expect(
      _record(
        tester,
      ).rrects.where((entry) => (entry.argb & 0x00ffffff) == nowRgb),
      isEmpty,
    );
  });

  testWidgets('tap jumps to the nearest configured step', (tester) async {
    var changed = -1.0;
    await tester.pumpWidget(
      _host(_slider(value: 50, onChanged: (value) => changed = value)),
    );

    final topLeft = tester.getTopLeft(find.byType(LimitSlider));
    await tester.tapAt(topLeft + const Offset(313, 110));
    expect(changed, 65);
  });

  testWidgets('default selectable range does not go below 50 percent', (
    tester,
  ) async {
    var changed = -1.0;
    await tester.pumpWidget(
      _host(_slider(value: 50, onChanged: (value) => changed = value)),
    );

    final topLeft = tester.getTopLeft(find.byType(LimitSlider));
    await tester.tapAt(topLeft + const Offset(100, 110));
    expect(changed, 50);
  });

  testWidgets('knob keeps a 64px hit box around its 52px visual', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_slider()));
    expect(
      tester.getSize(find.byKey(const ValueKey('limitSlider.knobHitTarget'))),
      const Size.square(AppSizes.minTouchTarget),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('limitSlider.knob'))),
      const Size.square(AppSizes.limitSliderKnob),
    );
  });

  testWidgets('knob grows while a pointer that started on it stays down', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_slider(value: 50, current: 52)));
    final scaleFinder = find.byKey(const ValueKey('limitSlider.knobScale'));
    final knobFinder = find.byKey(const ValueKey('limitSlider.knob'));

    AnimatedScale scale() => tester.widget<AnimatedScale>(scaleFinder);
    expect(scale().scale, 1);
    final normalRect = tester.getRect(knobFinder);

    final gesture = await tester.startGesture(tester.getCenter(knobFinder));
    await tester.pump();
    expect(scale().scale, AppSizes.limitSliderPressedScale);
    await tester.pump(AppMotion.fast);
    expect(
      tester.getRect(knobFinder).width,
      closeTo(normalRect.width * AppSizes.limitSliderPressedScale, 0.001),
    );

    await gesture.up();
    await tester.pump();
    expect(scale().scale, 1);
  });

  testWidgets('100 percent knob stays centered in the right pill cap', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_slider(value: 100)));

    final slider = tester.getRect(find.byType(LimitSlider));
    final knob = tester.getRect(find.byKey(const ValueKey('limitSlider.knob')));
    expect(
      knob.center.dx,
      closeTo(slider.right - AppSizes.limitSliderHeight / 2, 0.001),
    );
    expect(knob.right, lessThan(slider.right));

    final pending = _record(
      tester,
    ).rects.singleWhere((entry) => entry.argb == AppColors.track.toARGB32());
    expect(pending.rect.right, 500);
  });

  testWidgets('semantics expose slider values and increase/decrease actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final changes = <double>[];
    await tester.pumpWidget(_host(_slider(value: 85, onChanged: changes.add)));

    final node = tester.getSemantics(find.byType(LimitSlider));
    final data = node.getSemanticsData();
    expect(data.flagsCollection.isSlider, isTrue);
    expect(data.label, 'Charge limit');
    expect(data.value, '85 percent');
    expect(data.increasedValue, '90 percent');
    expect(data.decreasedValue, '80 percent');
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);

    tester.semantics.increase(find.semantics.byLabel('Charge limit'));
    await tester.pump();
    expect(changes, [90]);
    semantics.dispose();
  });

  testWidgets('external target changes animate from the displayed position', (
    tester,
  ) async {
    var value = 50.0;
    late StateSetter setHostState;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return LimitSlider(
              value: value,
              current: 25,
              duration: const Duration(milliseconds: 400),
              onChanged: (_) {},
            );
          },
        ),
      ),
    );

    Rect pending() => _record(tester).rects
        .singleWhere((entry) => entry.argb == AppColors.track.toARGB32())
        .rect;

    expect(pending().right, closeTo(250, 0.001));
    setHostState(() => value = 80);
    await tester.pump();
    expect(pending().right, closeTo(250, 0.001));

    await tester.pump(const Duration(milliseconds: 200));
    expect(pending().right, greaterThan(250));
    expect(pending().right, lessThan(373.6));

    await tester.pumpAndSettle();
    expect(pending().right, closeTo(373.6, 0.001));
  });

  testWidgets('direct drag uses one-percent steps without animation lag', (
    tester,
  ) async {
    var value = 50.0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => LimitSlider(
            value: value,
            current: 25,
            duration: const Duration(seconds: 2),
            onChanged: (next) => setState(() => value = next),
          ),
        ),
      ),
    );

    final origin = tester.getTopLeft(find.byType(LimitSlider));
    final gesture = await tester.startGesture(origin + const Offset(250, 110));
    await gesture.moveTo(origin + const Offset(400, 110));
    await tester.pump();

    final slider = tester.getRect(find.byType(LimitSlider));
    final knob = tester.getRect(find.byKey(const ValueKey('limitSlider.knob')));
    expect(value, 86);
    expect(knob.center.dx - slider.left, closeTo(398.32, 0.001));
    await gesture.up();
  });

  testWidgets('narrow current zone moves its label outside the fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        LimitSlider(
          value: 85,
          current: 5,
          currentLabel: '5',
          currentUnit: '%',
          valueLabel: '85',
          valueUnit: '%',
          onChanged: (_) {},
        ),
        width: 400,
      ),
    );

    final slider = tester.getRect(find.byType(LimitSlider));
    final currentLabel = tester.getRect(find.text('5'));
    expect(currentLabel.left, greaterThanOrEqualTo(slider.left + 20));

    await tester.pumpWidget(
      _host(
        LimitSlider(
          value: 85,
          current: 67,
          currentLabel: '67',
          currentUnit: '%',
          valueLabel: '85',
          valueUnit: '%',
          onChanged: (_) {},
        ),
        width: 400,
      ),
    );
    final wideLabel = tester.getRect(find.text('67'));
    expect(wideLabel.right, lessThan(slider.left + 268));
  });

  testWidgets('target readout stays within the track at both extremes', (
    tester,
  ) async {
    for (final value in [50.0, 100.0]) {
      await tester.pumpWidget(
        _host(
          LimitSlider(
            value: value,
            valueLabel: value.round().toString(),
            valueUnit: '%',
            caption: 'Projected range',
            onChanged: (_) {},
          ),
          width: 300,
        ),
      );
      final slider = tester.getRect(find.byType(LimitSlider));
      final readout = tester.getRect(
        find.byKey(const ValueKey('limitSlider.targetReadout')),
      );
      expect(readout.left, greaterThanOrEqualTo(slider.left));
      expect(readout.right, lessThanOrEqualTo(slider.right));
    }
  });

  testWidgets('reduced motion renders an external update immediately', (
    tester,
  ) async {
    var value = 50.0;
    late StateSetter setHostState;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return LimitSlider(value: value, onChanged: (_) {});
          },
        ),
        reducedMotion: true,
      ),
    );

    setHostState(() => value = 80);
    await tester.pump();
    final pending = _record(
      tester,
    ).rects.singleWhere((entry) => entry.argb == AppColors.track.toARGB32());
    expect(pending.rect.right, closeTo(373.6, 0.001));
  });
}
