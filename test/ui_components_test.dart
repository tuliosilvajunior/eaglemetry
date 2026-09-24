import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/gallery/pages/energy_bar_chart_page.dart';
import 'package:capy_ui/gallery/pages/limit_slider_page.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Center(child: child),
    ),
  );
}

void main() {
  testWidgets('action tile keeps its fill when disabled and drops both '
      'glyph and label to the subtle ink', (tester) async {
    var taps = 0;

    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            SoftActionTile(
              icon: Icons.bolt,
              label: 'Disabled',
              onPressed: null,
            ),
          ],
        ),
      ),
    );

    final material = tester.widget<Material>(
      find
          .ancestor(of: find.text('Disabled'), matching: find.byType(Material))
          .first,
    );
    expect(material.color, AppColors.control);

    final icon = tester.widget<Icon>(find.byIcon(Icons.bolt));
    expect(icon.color, AppColors.inkSubtle);

    final label = tester.widget<Text>(find.text('Disabled'));
    expect(label.style?.color, AppColors.inkSubtle);

    await tester.tap(find.text('Disabled'));
    expect(taps, 0);
  });

  testWidgets('a semantic action tints only the glyph, not the label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SoftActionTile(
          icon: Icons.flash_off,
          label: 'Stop charging',
          iconColor: AppColors.critical,
          onPressed: () {},
        ),
      ),
    );

    expect(
      tester.widget<Icon>(find.byIcon(Icons.flash_off)).color,
      AppColors.critical,
    );
    expect(
      tester.widget<Text>(find.text('Stop charging')).style?.color,
      AppColors.ink,
    );
  });

  testWidgets('metric and unit are separate runs sharing a baseline', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const MetricValue(value: '202', unit: 'mi')));

    expect(find.text('202'), findsOneWidget);
    expect(find.text('mi'), findsOneWidget);

    final value = tester.widget<Text>(find.text('202'));
    final unit = tester.widget<Text>(find.text('mi'));
    expect(value.style?.fontSize, greaterThan(unit.style!.fontSize!));
    expect(value.style?.fontFeatures?.map((f) => f.feature), contains('tnum'));
  });

  testWidgets('the three tab kinds use opposite selected fills', (
    tester,
  ) async {
    const items = [
      TabItem(value: 0, label: 'First'),
      TabItem(value: 1, label: 'Second'),
    ];

    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PillTabBar<int>(items: items, selected: 0, onSelected: (_) {}),
            TrackSegmentedControl<int>(
              items: items,
              selected: 0,
              onSelected: (_) {},
            ),
          ],
        ),
      ),
    );

    // Page-level: the selected pill is the near-black selection fill. It is
    // one sliding shape rather than a decoration on the selected item, so it
    // is only in the tree once the first frame has been measured.
    await tester.pump();
    await tester.pump();
    final pill = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(PillTabBar<int>),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect((pill.decoration as BoxDecoration).color, AppColors.selectionFill);

    // In-card filter: selected segment is white on the grey track — the
    // visual inverse.
    final segment = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byType(TrackSegmentedControl<int>),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect((segment.decoration! as BoxDecoration).color, AppColors.surface);
  });

  testWidgets('short text tabs keep the automotive minimum width', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        TextTabBar<int>(
          items: const [TabItem(value: 0, label: 'I')],
          selected: 0,
          onSelected: (_) {},
        ),
      ),
    );

    final touchTarget = find
        .ancestor(of: find.text('I'), matching: find.byType(InkWell))
        .first;
    expect(
      tester.getSize(touchTarget).width,
      greaterThanOrEqualTo(AppSizes.minTouchTarget),
    );
  });

  testWidgets('preset tile inverts to the selection fill when picked', (
    tester,
  ) async {
    var picked = -1;

    await tester.pumpWidget(
      _host(
        Row(
          children: [
            Expanded(
              child: SelectableTile(
                value: '85%',
                label: 'Extended',
                selected: true,
                onPressed: () => picked = 0,
              ),
            ),
            Expanded(
              child: SelectableTile(
                value: '100%',
                label: 'Max',
                selected: false,
                onPressed: () => picked = 1,
              ),
            ),
          ],
        ),
      ),
    );

    Material materialFor(String text) => tester.widget<Material>(
      find.ancestor(of: find.text(text), matching: find.byType(Material)).first,
    );

    expect(materialFor('Extended').color, AppColors.selectionFill);
    expect(materialFor('Max').color, AppColors.control);
    expect(
      tester.widget<Text>(find.text('Extended')).style?.color,
      AppColors.onSelection,
    );

    await tester.tap(find.text('Max'));
    expect(picked, 1);
  });

  testWidgets('interactive controls meet the automotive touch minimum', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SoftActionTile(label: 'Row', onPressed: () {}),
            SquareIconButton(icon: Icons.swap_horiz, onPressed: () {}),
            InfoIconButton(onPressed: () {}),
            PillTabBar<int>(
              items: const [TabItem(value: 0, label: 'Tab')],
              selected: 0,
              onSelected: (_) {},
            ),
          ],
        ),
      ),
    );

    for (final text in ['Row', 'Tab']) {
      expect(
        tester.getSize(find.text(text)).height,
        lessThanOrEqualTo(64),
        reason: 'label should fit inside the target',
      );
    }
    expect(
      tester.getSize(find.byType(SquareIconButton)).height,
      greaterThanOrEqualTo(64),
    );
    expect(
      tester.getSize(find.byType(InfoIconButton)).height,
      greaterThanOrEqualTo(64),
    );
    expect(
      tester.getSize(find.widgetWithText(SoftActionTile, 'Row')).height,
      greaterThanOrEqualTo(64),
    );
  });

  testWidgets('a sized square icon button stands as tall as a pill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PillTabBar<int>(
              items: const [TabItem(value: 0, label: 'Tab')],
              selected: 0,
              onSelected: (_) {},
            ),
            SquareIconButton(
              icon: Icons.settings,
              size: AppSizes.minTouchTarget,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    // The gear beside the tab row is a peer of the tabs, so its visible square
    // is the pill's height and not the smaller default.
    final square = tester.getSize(
      find.descendant(
        of: find.byType(SquareIconButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(square.height, AppSizes.minTouchTarget);
    expect(square.width, AppSizes.minTouchTarget);
    // And the glyph grows with the square, instead of keeping its old size in
    // the middle of a bigger button.
    final glyph = tester.widget<Icon>(find.byIcon(Icons.settings));
    expect(glyph.size, greaterThan(AppSizes.iconMd));
  });

  testWidgets('gallery lays out on an automotive landscape viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const LimitSliderGalleryPage(),
      ),
    );
    await tester.pump(AppMotion.slow);

    expect(tester.takeException(), isNull);
    expect(find.byType(LimitSlider), findsOneWidget);

    await tester.tap(find.text('7 kW'));
    await tester.pump(AppMotion.base);
    expect(
      tester.widget<LimitSlider>(find.byType(LimitSlider)).chargingPowerKw,
      7,
    );

    await tester.tap(find.text('80 kW'));
    await tester.pump(AppMotion.fast);
    expect(
      tester.widget<LimitSlider>(find.byType(LimitSlider)).chargingPowerKw,
      80,
    );
    expect(
      find.byKey(const ValueKey('limitSlider.chargingIcon')),
      findsOneWidget,
    );
  });

  testWidgets('gallery energy demo rebuckets after its final slot completes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const EnergyBarChartGalleryPage(),
      ),
    );
    await tester.pump(AppMotion.slow);
    await tester.ensureVisible(find.text('Add bar'));
    await tester.pump();

    EnergyBarChart energyChart() =>
        tester.widgetList<EnergyBarChart>(find.byType(EnergyBarChart)).first;

    final initial = energyChart();
    final initialLabels = initial.xTicks.map((tick) => tick.label).toList();
    expect(initial.bars, hasLength(initial.slotCount! - 3));

    await tester.tap(find.widgetWithText(SoftActionTile, 'Add bar'));
    await tester.pump(AppMotion.base);
    expect(energyChart().bars, hasLength(initial.bars.length + 1));

    await tester.tap(find.widgetWithText(SoftActionTile, 'Add bar'));
    await tester.pump(AppMotion.base);
    await tester.tap(find.widgetWithText(SoftActionTile, 'Add bar'));
    await tester.pump(AppMotion.base);

    final rebucketed = energyChart();
    expect(rebucketed.bars.length, lessThan(initial.bars.length));
    expect(rebucketed.xTicks.map((tick) => tick.position), [0, 0.4, 0.8]);
    expect(
      rebucketed.xTicks.map((tick) => tick.label),
      isNot(equals(initialLabels)),
    );
    expect(find.textContaining('2 min buckets'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery drag keeps Custom selected over a named preset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const LimitSliderGalleryPage(),
      ),
    );
    await tester.pump(AppMotion.slow);

    bool tileSelected(String label) => tester
        .widget<SelectableTile>(find.widgetWithText(SelectableTile, label))
        .selected;

    // Extended (85%) is the selected preset at start.
    expect(tileSelected('Extended'), isTrue);
    expect(tileSelected('Custom'), isFalse);

    // Drag far past the right edge so the value clamps to 100 (Max) while the
    // pointer is still down: Custom must stay selected for the whole gesture.
    final origin = tester.getCenter(
      find.byKey(const ValueKey('limitSlider.knob')),
    );
    final gesture = await tester.startGesture(origin);
    await gesture.moveTo(origin + const Offset(600, 0));
    await tester.pump();
    expect(tileSelected('Custom'), isTrue);
    expect(tileSelected('Max'), isFalse);

    await gesture.up();
    await tester.pump();
    expect(tileSelected('Max'), isTrue);
    expect(tileSelected('Custom'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
