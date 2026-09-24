import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

void main() {
  group('sliding indicator', () {
    testWidgets('sits on the selected pill once measured', (tester) async {
      final state = await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();
      expect(_indicatorRect(tester), _pillRect(tester, 'Carga'));
      expect(state.selected, 2);
    });

    testWidgets('is one shape, not one per tab', (tester) async {
      await _pumpBar(tester);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(PillTabBar<int>),
          matching: find.byType(DecoratedBox),
        ),
        findsOneWidget,
      );
    });

    testWidgets('travels between the two pills instead of jumping', (
      tester,
    ) async {
      await _pumpBar(tester);
      await tester.pumpAndSettle();
      final from = _pillRect(tester, 'Viagens');
      final to = _pillRect(tester, 'Config');

      await tester.tap(find.text('Config'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));

      final travelling = _indicatorRect(tester);
      expect(travelling.left, greaterThan(from.left));
      expect(travelling.left, lessThan(to.left));
      // The row's labels differ in width, so a real travel resizes the pill on
      // the way. A shape that only translated would keep `Viagens`' width.
      expect(travelling.width, isNot(closeTo(from.width, 0.5)));

      await tester.pumpAndSettle();
      expect(_indicatorRect(tester), to);
    });

    testWidgets('an interrupted travel bends from where the pill is', (
      tester,
    ) async {
      await _pumpBar(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Config'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      final interrupted = _indicatorRect(tester);

      await tester.tap(find.text('Agora'));
      // The retarget frame itself, before any time passes. The pill has to
      // still be exactly where the interrupted travel left it: a slide that
      // restarted from the tab it was heading for would snap forward to
      // 'Config' here first and walk back, which is the visible bug.
      await tester.pump();
      expect(_indicatorRect(tester).left, closeTo(interrupted.left, 0.01));

      await tester.pump(const Duration(milliseconds: 16));
      final bending = _indicatorRect(tester);
      expect(bending.left, lessThan(interrupted.left));
      expect(bending.left, greaterThan(_pillRect(tester, 'Agora').left));

      await tester.pumpAndSettle();
      expect(_indicatorRect(tester), _pillRect(tester, 'Agora'));
    });

    testWidgets('passes through the tabs between, not around them', (
      tester,
    ) async {
      // Driven rather than timed: the eased travel crosses the middle tab too
      // fast for a pump to land on it, and the claim here is about the path,
      // not about when the pill is where. Both paths read the same position.
      final position = ValueNotifier(0.0);
      addTearDown(position.dispose);
      await _pumpBar(tester, position: position);
      await tester.pumpAndSettle();

      // Every tab on the way is a waypoint the pill takes the exact shape of.
      // A straight lerp from the first rect to the last would be some blend of
      // 'Viagens' and 'Config' here instead.
      for (final tab in [1, 2, 3]) {
        position.value = tab.toDouble();
        await tester.pump();
        expect(_indicatorRect(tester), _pillRect(tester, _labels[tab]));
      }
    });
  });

  group('external position', () {
    testWidgets('follows the driver and runs no animation of its own', (
      tester,
    ) async {
      final position = ValueNotifier(0.0);
      addTearDown(position.dispose);
      await _pumpBar(tester, position: position);
      await tester.pumpAndSettle();
      final first = _pillRect(tester, 'Viagens');
      final second = _pillRect(tester, 'Agora');

      position.value = 0.5;
      await tester.pump();
      final half = _indicatorRect(tester);
      expect(half.left, closeTo((first.left + second.left) / 2, 0.5));
      expect(half.width, closeTo((first.width + second.width) / 2, 0.5));

      // No pending animation: the driver is the only clock.
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a selection change does not start an internal slide', (
      tester,
    ) async {
      final position = ValueNotifier(0.0);
      addTearDown(position.dispose);
      final state = await _pumpBar(tester, position: position);
      await tester.pumpAndSettle();

      state.select(3);
      await tester.pump();
      // The driver has not moved, so neither has the pill.
      expect(_indicatorRect(tester), _pillRect(tester, 'Viagens'));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('PageTabPosition reads the controller live', (tester) async {
      final controller = PageController(initialPage: 2);
      addTearDown(controller.dispose);
      final position = PageTabPosition(controller);
      addTearDown(position.dispose);

      // Before a viewport is attached `page` would throw; the fallback is the
      // page the controller was built on.
      expect(position.value, 2);

      await tester.pumpWidget(
        MaterialApp(
          home: PageView(
            controller: controller,
            children: const [
              SizedBox.shrink(),
              SizedBox.shrink(),
              SizedBox.shrink(),
            ],
          ),
        ),
      );
      expect(position.value, 2);

      var notified = 0;
      position.addListener(() => notified++);
      unawaitedJump(controller, 0);
      await tester.pumpAndSettle();
      expect(position.value, 0);
      expect(notified, greaterThan(0));
    });
  });

  group('the masked label copy', () {
    testWidgets('is not a second Text, so find.text stays exact', (
      tester,
    ) async {
      await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();
      for (final label in _labels) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('lays out identically to the row it masks', (tester) async {
      await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();
      // Two `RichText`s per label: the one `Text` builds, and the mask copy.
      // The mask is only correct while they are the same size.
      final sizes = tester
          .renderObjectList<RenderBox>(find.byType(RichText))
          .map((box) => box.size)
          .toList();
      expect(sizes, hasLength(_labels.length * 2));
      for (var i = 0; i < _labels.length; i++) {
        expect(sizes[i], sizes[i + _labels.length], reason: _labels[i]);
      }
    });

    testWidgets('is not announced twice', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();
      for (final label in _labels) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      handle.dispose();
    });

    testWidgets('does not swallow taps meant for the row under it', (
      tester,
    ) async {
      final state = await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();
      // The mask covers this pill completely, so a tap has to pass through it.
      await tester.tap(find.text('Carga'));
      await tester.pumpAndSettle();
      expect(state.selected, 2);

      await tester.tap(find.text('Config'));
      await tester.pumpAndSettle();
      expect(state.selected, 3);
    });
  });

  group('re-measuring', () {
    testWidgets('follows the labels when the text scale changes', (
      tester,
    ) async {
      await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();
      final before = _indicatorRect(tester);

      // Driven from the platform, the way the real thing arrives: nothing above
      // the bar rebuilds, so the only route to a re-measure is the bar's own
      // dependency on the text scaler. Setting it through a widget above would
      // rebuild the bar and prove nothing.
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      final after = _indicatorRect(tester);

      expect(after.width, greaterThan(before.width));
      expect(after, _pillRect(tester, 'Carga'));
    });

    testWidgets('follows the labels when a locale changes them', (
      tester,
    ) async {
      final state = await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();

      state.relabel(const ['Trips', 'Now', 'Charging is longer now', 'Config']);
      await tester.pumpAndSettle();
      expect(
        _indicatorRect(tester),
        _pillRect(tester, 'Charging is longer now'),
      );
    });

    testWidgets('keeps the pill on the selected tab when one is removed', (
      tester,
    ) async {
      final state = await _pumpBar(tester, selected: 3);
      await tester.pumpAndSettle();

      state.relabel(const ['Viagens', 'Carga', 'Config']);
      await tester.pumpAndSettle();
      expect(_indicatorRect(tester), _pillRect(tester, 'Config'));
    });
  });

  group('inside a horizontal scroll view', () {
    testWidgets('the pill scrolls with its labels', (tester) async {
      await _pumpBar(tester, selected: 3, width: 240);
      await tester.pumpAndSettle();
      expect(_indicatorRect(tester), _pillRect(tester, 'Config'));

      await tester.drag(find.byType(PillTabBar<int>), const Offset(-80, 0));
      await tester.pumpAndSettle();
      // Both rects are read off the screen, so this only holds if the offset
      // moved the pill and the labels by the same amount.
      expect(_indicatorRect(tester), _pillRect(tester, 'Config'));
    });
  });

  group('reduced motion', () {
    testWidgets('jumps to the new tab instead of travelling', (tester) async {
      await _pumpBar(tester, reduceMotion: true);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Config'));
      // One frame, no elapsed time: the pill is already there. `pump` with a
      // duration would let a slide run and hide the difference, and
      // `hasRunningAnimations` cannot stand in for it here because the tap
      // itself starts an ink splash.
      await tester.pump();
      expect(_indicatorRect(tester), _pillRect(tester, 'Config'));
    });
  });

  group('semantics', () {
    testWidgets('the selected tab is announced as selected', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpBar(tester, selected: 2);
      await tester.pumpAndSettle();

      final selected = [
        for (final node in tester.semantics.simulatedAccessibilityTraversal())
          if (node.flagsCollection.isSelected == Tristate.isTrue) node.label,
      ];
      expect(selected, ['Carga']);
      handle.dispose();
    });
  });
}

const _labels = ['Viagens', 'Agora', 'Carga', 'Config'];

/// Jumps without awaiting: `animateToPage`'s future only completes after the
/// scroll settles, which needs pumps this helper cannot run.
void unawaitedJump(PageController controller, int page) {
  controller.jumpToPage(page);
}

Rect _indicatorRect(WidgetTester tester) {
  final finder = find
      .descendant(
        of: find.byType(PillTabBar<int>),
        matching: find.byType(DecoratedBox),
      )
      .first;
  return tester.getRect(finder);
}

/// The on-screen box of one tab, which is exactly what the bar measures its
/// pill from. Read off the real row only — the mask copy has no [InkWell], and
/// paints through `RichText` rather than `Text`, so neither finder reaches it.
Rect _pillRect(WidgetTester tester, String label) {
  return tester.getRect(
    find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
  );
}

Future<_HostState> _pumpBar(
  WidgetTester tester, {
  int selected = 0,
  ValueListenable<double>? position,
  bool reduceMotion = false,
  double width = 1000,
}) async {
  await tester.pumpWidget(
    _Host(
      selected: selected,
      position: position,
      reduceMotion: reduceMotion,
      width: width,
    ),
  );
  return tester.state<_HostState>(find.byType(_Host));
}

class _Host extends StatefulWidget {
  const _Host({
    required this.selected,
    required this.position,
    required this.reduceMotion,
    required this.width,
  });

  final int selected;
  final ValueListenable<double>? position;
  final bool reduceMotion;
  final double width;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int selected = widget.selected;
  List<String> labels = _labels;

  void select(int value) => setState(() => selected = value);

  void relabel(List<String> value) {
    setState(() {
      labels = value;
      if (selected >= value.length) selected = value.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bar = Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: widget.width,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: PillTabBar<int>(
            items: [
              for (var i = 0; i < labels.length; i++)
                TabItem(value: i, label: labels[i]),
            ],
            selected: selected,
            onSelected: select,
            position: widget.position,
          ),
        ),
      ),
    );
    return MaterialApp(
      // The reduced-motion override is applied only when it is asked for, and
      // from a `Builder` rather than from here. Reading `MediaQuery.of` in this
      // build method would make *this* widget rebuild whenever the platform
      // text scale changes, which would hand `PillTabBar` a fresh widget and
      // re-measure it through `didUpdateWidget` — hiding whether the bar
      // notices a scale change on its own.
      home: Scaffold(
        body: !widget.reduceMotion
            ? bar
            : Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true),
                  child: bar,
                ),
              ),
      ),
    );
  }
}
