import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

/// The stage's own cover, independent of any screen that uses it. Every case
/// here was either broken at some point or is a rule that is invisible until
/// you look for it: a gutter charged for a card that is not there, a gesture
/// axis that locks on a frame the user did not mean, an edge that slides half a
/// screen to uncover nothing.
void main() {
  group('CardStageController', () {
    testWidgets('peek rests at 0 before any gesture', (tester) async {
      final stage = await _pumpStage(tester);
      // A -1..1 AnimationController defaults to its lower bound, which would
      // read as a fully-engaged peek on the very first frame.
      expect(stage.controller.peek, 0.0);
    });

    testWidgets('one gesture can expand and then peek sideways', (
      tester,
    ) async {
      final stage = await _pumpStage(tester);
      final gesture = await _expandFully(tester, const Offset(400, 300));
      expect(stage.controller.isFullscreen, isTrue);
      // Same finger, never lifted. The frames right after the threshold are
      // still travelling upward; they must not decide the axis.
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump();
      }
      expect(stage.controller.peek, lessThan(-0.5));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stage.controller.peek, 0.0, reason: 'a peek always springs back');
    });

    testWidgets('sub-slop jitter does not decide the axis', (tester) async {
      final stage = await _pumpStage(tester);
      var gesture = await _expandFully(tester, const Offset(400, 300));
      await gesture.up();
      await tester.pumpAndSettle();

      gesture = await tester.startGesture(const Offset(400, 300));
      // A half-pixel diagonal twitch used to lock `vertical` for good.
      await gesture.moveBy(const Offset(0.4, 0.5));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump();
      }
      expect(stage.controller.peek, lessThan(-0.5));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a downward drag still collapses', (tester) async {
      final stage = await _pumpStage(tester);
      var gesture = await _expandFully(tester, const Offset(400, 300));
      await gesture.up();
      await tester.pumpAndSettle();

      gesture = await tester.startGesture(const Offset(400, 300));
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stage.controller.expansion, 0.0);
    });
  });

  group('peek resistance', () {
    testWidgets('an edge with no neighbour gives a little and no more', (
      tester,
    ) async {
      // Slot 0 is the expandable one, so there is nothing to its left.
      final stage = await _pumpStage(tester, expandableIndex: 0);
      final gesture = await _expandFully(tester, const Offset(90, 300));

      // 320px is well past a full peek distance (220): unresisted this would
      // be pinned at 1.0, sliding the card most of a screen sideways to
      // uncover a card that does not exist.
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
      }
      expect(stage.controller.peek, greaterThan(0));
      expect(stage.controller.peek, lessThan(0.1));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(stage.controller.peek, 0.0);
    });

    testWidgets('the same drag toward a real neighbour is unresisted', (
      tester,
    ) async {
      final stage = await _pumpStage(tester, expandableIndex: 0);
      final gesture = await _expandFully(tester, const Offset(90, 300));
      // Dragging the other way reveals slot 1, which does exist.
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump();
      }
      expect(stage.controller.peek, -1.0);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('resistance is not free travel — dragging back retraces', (
      tester,
    ) async {
      final stage = await _pumpStage(tester, expandableIndex: 0);
      final gesture = await _expandFully(tester, const Offset(90, 300));

      // Exactly half a peek distance into the empty side.
      await gesture.moveBy(const Offset(110, 0));
      await tester.pump();
      final held = stage.controller.peek;
      expect(held, greaterThan(0));

      // The same distance back. If resistance were applied to the displayed
      // value instead of to travel, the return trip would overshoot straight
      // past zero into a peek toward the other side.
      await gesture.moveBy(const Offset(-110, 0));
      await tester.pump();
      expect(stage.controller.peek, closeTo(0, 0.0001));

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('gutters', () {
    testWidgets('a resting row spends one gutter per boundary', (tester) async {
      await _pumpStage(tester);
      const unit = (800 - _gutter * 2) / 4;
      expect(_rect(tester, Colors.red), _slot(0, unit));
      expect(_rect(tester, Colors.blue), _slot(unit + _gutter, unit * 2));
      expect(_rect(tester, Colors.green), _slot(unit * 3 + _gutter * 2, unit));
    });

    testWidgets('a collapsed leading card takes its gutter with it', (
      tester,
    ) async {
      final stage = await _pumpStage(tester);
      stage.setUnits(const [0, 3, 1]);
      await tester.pumpAndSettle();

      // One boundary left, not two: the row must start flush at its own left
      // edge rather than 24px inset by a gutter separating the second card
      // from a card that is not there.
      const unit = (800 - _gutter) / 4;
      expect(_rect(tester, Colors.blue), _slot(0, unit * 3));
      expect(_rect(tester, Colors.green), _slot(unit * 3 + _gutter, unit));
      // And the row still ends exactly at the right edge instead of
      // overflowing by the gutter it over-reserved.
      expect(_rect(tester, Colors.green).right, closeTo(800, 0.01));
    });

    testWidgets('a collapsed trailing card leaves no gap behind it', (
      tester,
    ) async {
      final stage = await _pumpStage(tester);
      stage.setUnits(const [2, 2, 0]);
      await tester.pumpAndSettle();

      const unit = (800 - _gutter) / 4;
      expect(_rect(tester, Colors.red), _slot(0, unit * 2));
      expect(_rect(tester, Colors.blue).right, closeTo(800, 0.01));
    });

    testWidgets('a collapsed middle card still separates its neighbours', (
      tester,
    ) async {
      final stage = await _pumpStage(tester);
      stage.setUnits(const [2, 0, 2]);
      await tester.pumpAndSettle();

      const unit = (800 - _gutter) / 4;
      expect(_rect(tester, Colors.red), _slot(0, unit * 2));
      expect(_rect(tester, Colors.green), _slot(unit * 2 + _gutter, unit * 2));
    });

    testWidgets('every slot collapsed at once does not produce NaN', (
      tester,
    ) async {
      final stage = await _pumpStage(tester);
      stage.setUnits(const [0, 0, 0]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_rect(tester, Colors.red).width, 0);
    });
  });

  group('ExpandableCardStage', () {
    testWidgets('survives being handed more slots than it had', (tester) async {
      final stage = await _pumpStage(tester);
      stage.setSlotCount(4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });

  group('CardSize', () {
    testWidgets('each slot is built for the room it actually has', (
      tester,
    ) async {
      final stage = await _pumpStage(tester);
      // Resting 1/2/1.
      expect(_sizes(tester), [
        CardSize.compact,
        CardSize.regular,
        CardSize.compact,
      ]);

      // 0/3/1: the middle card takes the left one's only quarter.
      stage.setUnits(const [0, 3, 1]);
      await tester.pumpAndSettle();
      expect(_sizes(tester), [
        CardSize.hidden,
        CardSize.wide,
        CardSize.compact,
      ]);
    });

    testWidgets('both layouts are alive while the swap cross-fades', (
      tester,
    ) async {
      final stage = await _pumpStage(tester);
      stage.setUnits(const [0, 3, 1]);
      await tester.pump();
      // Partway through the resize the middle slot has crossed the 2.5-unit
      // boundary but the fade has not finished, so `wide` is fading in over a
      // `regular` that is still on screen.
      await tester.pump(const Duration(milliseconds: 260));
      final live = _sizes(tester);
      expect(live, contains(CardSize.wide));
      expect(live, contains(CardSize.regular));
      await tester.pumpAndSettle();
      expect(_sizes(tester), isNot(contains(CardSize.regular)));
    });

    testWidgets('the expandable slot reports fullscreen once settled', (
      tester,
    ) async {
      await _pumpStage(tester);
      final gesture = await _expandFully(tester, const Offset(400, 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_sizes(tester), contains(CardSize.fullscreen));
    });

    testWidgets('a stable slot is not rebuilt by a size change', (
      tester,
    ) async {
      _Probe.mounts.clear();
      final key = GlobalKey<_MixedStageState>();
      await tester.pumpWidget(MaterialApp(home: _MixedStage(key: key)));
      await tester.pumpAndSettle();
      expect(_Probe.mounts, {'stable': 1, 'aware': 1});

      // Both cards change size. The size-aware one is re-keyed and mounts a
      // second time — that is the cross-fade working. The stable one must not,
      // because its `State` is the whole point: a card holding a platform
      // resource (`CarplayV2Screen` hands the OEM renderer back on dispose)
      // loses it to a rebuild the user only asked to resize.
      key.currentState!.setUnits(const [3, 1]);
      await tester.pumpAndSettle();

      expect(_Probe.mounts['aware'], greaterThan(1));
      expect(_Probe.mounts['stable'], 1);
    });

    testWidgets('a stable slot survives the swap to fullscreen', (
      tester,
    ) async {
      _Probe.mounts.clear();
      final key = GlobalKey<_MixedStageState>();
      await tester.pumpWidget(MaterialApp(home: _MixedStage(key: key)));
      await tester.pumpAndSettle();

      key.currentState!.controller.expand();
      await tester.pumpAndSettle();

      // `CardSize.fullscreen` is the size change that lands at the end of
      // every expand gesture, which made it the one that hurt most.
      expect(_Probe.mounts['stable'], 1);
    });

    test('CardStageSlot.steps falls back for hidden and fullscreen', () {
      final slot = CardStageSlot.steps(
        units: 1,
        compact: const Text('c'),
        regular: const Text('r'),
        wide: const Text('w'),
      );
      expect((slot.builder(CardSize.hidden) as Text).data, 'c');
      expect((slot.builder(CardSize.fullscreen) as Text).data, 'w');
    });
  });

  group('reduced motion', () {
    testWidgets('a resize lands on the next frame instead of tweening', (
      tester,
    ) async {
      final stage = await _pumpStage(tester, reduceMotion: true);
      stage.setUnits(const [0, 3, 1]);
      await tester.pump();

      // No `pumpAndSettle`: one frame is all a reduced-motion resize gets.
      const unit = (800 - _gutter) / 4;
      expect(_rect(tester, Colors.blue), _slot(0, unit * 3));
    });

    testWidgets('a released drag settles without an animation', (tester) async {
      final stage = await _pumpStage(tester, reduceMotion: true);
      final gesture = await _expandFully(tester, const Offset(400, 300));
      await gesture.up();
      await tester.pump();
      expect(stage.controller.expansion, 1.0);
    });

    testWidgets('the drag itself still follows the finger', (tester) async {
      final stage = await _pumpStage(tester, reduceMotion: true);
      final gesture = await tester.startGesture(const Offset(400, 300));
      await gesture.moveBy(const Offset(0, -130));
      await tester.pump();
      // Direct manipulation is not decoration: freezing this would make the
      // card unusable rather than calmer.
      expect(stage.controller.expansion, closeTo(0.5, 0.01));
      await gesture.up();
      await tester.pump();
    });
  });

  group('semantics', () {
    testWidgets('the expandable card offers expand and collapse by name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final stage = await _pumpStage(tester);

      // The gesture is a pan and nothing else, so without this the card is
      // unreachable by the rotary controller and keyboard traversal that are
      // real input methods on a head unit.
      _invoke(tester, _expandLabel);
      await tester.pumpAndSettle();
      expect(stage.controller.isFullscreen, isTrue);

      _invoke(tester, _collapseLabel);
      await tester.pumpAndSettle();
      expect(stage.controller.expansion, 0.0);
      handle.dispose();
    });

    testWidgets('cards shoved off-screen are not announced', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpStage(tester);
      expect(_announced(tester), containsAll(['left', 'middle', 'right']));

      final gesture = await _expandFully(tester, const Offset(400, 300));
      await gesture.up();
      await tester.pumpAndSettle();

      // `IgnorePointer` alone would leave a screen reader happily announcing
      // two cards sitting off the edge behind the fullscreen one.
      expect(_announced(tester), ['middle']);
      handle.dispose();
    });
  });

  group('CardStageResize', () {
    test('resting units are the base levels', () {
      expect(const CardStageResize([1, 2, 1]).units, [1.0, 2.0, 1.0]);
    });

    test('a focused slot takes a quarter from the smallest sibling', () {
      expect(const CardStageResize([1, 2, 1]).toggled(1).units, [
        0.0,
        3.0,
        1.0,
      ]);
      expect(const CardStageResize([1, 2, 1]).toggled(0).units, [
        2.0,
        2.0,
        0.0,
      ]);
    });

    test('toggling the focused slot again returns to rest', () {
      const base = CardStageResize([1, 2, 1]);
      expect(base.toggled(1).toggled(1).units, base.units);
    });

    test('moving focus recomputes from rest rather than compounding', () {
      const base = CardStageResize([1, 2, 1]);
      expect(base.toggled(1).toggled(0).units, base.toggled(0).units);
    });

    test('a row with nothing left to give is returned unchanged', () {
      const collapsed = CardStageResize([0, 3, 0]);
      expect(identical(collapsed.toggled(1), collapsed), isTrue);
    });

    test('quarterDonorFor ties toward the lowest index', () {
      expect(quarterDonorFor([1, 2, 1], 1), 0);
      expect(quarterDonorFor([1, 2, 1], 0), 2);
      expect(quarterDonorFor([2, 1, 1], 0), 1);
    });

    test('quarterDonorFor is null when no sibling has a quarter left', () {
      // Not an assert: an assert is compiled out of a release build and the
      // caller would index with -1 instead of no-opping.
      expect(quarterDonorFor([0, 3, 0], 1), isNull);
      expect(quarterDonorFor([4], 0), isNull);
    });
  });

  group('CardStageDragHandle', () {
    testWidgets('the chevron turns with the expansion, not at the end of it', (
      tester,
    ) async {
      final stage = await _pumpStage(
        tester,
        expandableIndex: 0,
        withGrip: true,
      );
      double angle() => tester
          .widget<Transform>(
            find.ancestor(
              of: find.byIcon(Icons.keyboard_arrow_up),
              matching: find.byType(Transform),
            ),
          )
          .transform
          .getRotation()
          .storage[0]; // cos of the angle: 1 up, -1 down.

      // Collapsed: it points the way the card can go, which is up.
      expect(angle(), closeTo(1, 0.01));

      // Halfway through a drag it is already halfway round, so the grip
      // reports the state of the card and not the state of the gesture.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CardStageDragHandle)),
      );
      await gesture.moveBy(const Offset(0, -kTouchSlop));
      await tester.pump();
      await gesture.moveBy(Offset(0, -stage.controller.expandDistance / 2));
      await tester.pump();
      expect(angle(), closeTo(0, 0.35));

      await gesture.moveBy(Offset(0, -stage.controller.expandDistance));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stage.controller.isFullscreen, isTrue);
      expect(angle(), closeTo(-1, 0.01), reason: 'fullscreen points back down');
    });

    testWidgets('it fades back once it is left alone, and never to nothing', (
      tester,
    ) async {
      await _pumpStage(tester, expandableIndex: 0, withGrip: true);
      double opacity() => tester.widget<AnimatedOpacity>(_gripFade).opacity;

      expect(opacity(), 1.0);

      await tester.pump(CardStageDragHandle.idleDelay + _aBit);
      await tester.pumpAndSettle();
      // Faded, because it sits over live video and the video is the point —
      // but still there, because a control that has to be found twice is not
      // a control.
      expect(opacity(), lessThan(0.5));
      expect(opacity(), greaterThan(0));

      // A touch brings it back at once.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CardStageDragHandle)),
      );
      await tester.pump();
      expect(opacity(), 1.0);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a drag in progress does not fade under the finger', (
      tester,
    ) async {
      final stage = await _pumpStage(
        tester,
        expandableIndex: 0,
        withGrip: true,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CardStageDragHandle)),
      );
      await gesture.moveBy(const Offset(0, -kTouchSlop));
      await tester.pump();

      // Held still, past the idle delay, with the finger down. The stage's own
      // movement counts as interaction and so does the press.
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(Offset(0, -stage.controller.expandDistance / 6));
        await tester.pump(CardStageDragHandle.idleDelay);
      }
      // Scoped to the grip: the stage cross-fades its own slots, so a bare
      // `byType` picks up opacity that has nothing to do with this.
      expect(tester.widget<AnimatedOpacity>(_gripFade).opacity, 1.0);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}

const _aBit = Duration(milliseconds: 100);

final _gripFade = find.descendant(
  of: find.byType(CardStageDragHandle),
  matching: find.byType(AnimatedOpacity),
);
const _gutter = AppSpacing.gridGutter;
const _expandLabel = 'expand';
const _collapseLabel = 'collapse';

Future<_StageState> _pumpStage(
  WidgetTester tester, {
  int expandableIndex = 1,
  bool reduceMotion = false,
  bool withGrip = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: _Stage(expandableIndex: expandableIndex, withGrip: withGrip),
        ),
      ),
    ),
  );
  return tester.state<_StageState>(find.byType(_Stage));
}

/// A stage with one [CardStageSlot.stable] slot and one ordinary one, each
/// wrapping a [_Probe] that records how many times it has been mounted.
class _MixedStage extends StatefulWidget {
  const _MixedStage({super.key});

  @override
  State<_MixedStage> createState() => _MixedStageState();
}

class _MixedStageState extends State<_MixedStage>
    with TickerProviderStateMixin {
  late final CardStageController controller = CardStageController(vsync: this);
  List<double> _units = const [1, 3];

  void setUnits(List<double> units) => setState(() => _units = units);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExpandableCardStage(
      stage: controller,
      expandableIndex: 0,
      expandSemanticsLabel: _expandLabel,
      collapseSemanticsLabel: _collapseLabel,
      slots: [
        CardStageSlot.stable(
          units: _units[0],
          child: const _Probe(name: 'stable'),
        ),
        CardStageSlot(
          units: _units[1],
          builder: (_) => const _Probe(name: 'aware'),
        ),
      ],
    );
  }
}

/// Counts its own mounts by name, so a test can tell a rebuilt subtree from
/// one that was merely updated in place.
class _Probe extends StatefulWidget {
  const _Probe({required this.name});

  static final mounts = <String, int>{};

  final String name;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.mounts.update(widget.name, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.grey);
}

/// Drags [start] up far enough to cross the fullscreen threshold, leaving the
/// finger down so the caller can keep going in the same gesture.
Future<TestGesture> _expandFully(WidgetTester tester, Offset start) async {
  final gesture = await tester.startGesture(start);
  for (var i = 0; i < 12; i++) {
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
  }
  return gesture;
}

/// Performs a custom semantics action by label, the way assistive technology
/// would, rather than asserting that one merely exists.
///
/// The stage's expandable slot is the only node in this tree carrying custom
/// actions, so that is enough to find it — it deliberately has no label of its
/// own, since the card's real content is what should be announced.
void _invoke(WidgetTester tester, String label) {
  tester.semantics.performAction(
    find.semantics.byAction(SemanticsAction.customAction),
    SemanticsAction.customAction,
    args: CustomSemanticsAction.getIdentifier(
      CustomSemanticsAction(label: label),
    ),
  );
}

/// Labels in the *compiled* semantics tree — what assistive technology would
/// actually read out.
///
/// Not `find.bySemanticsLabel`, which reads each widget's own semantics config
/// off the widget tree and so reports a label that an ancestor `ExcludeSemantics`
/// has already dropped.
List<String> _announced(WidgetTester tester) => [
  for (final node in tester.semantics.simulatedAccessibilityTraversal())
    if (node.label.isNotEmpty) node.label,
];

/// The [CardSize] every currently-mounted slot body was built for, read off
/// the keys `_SlotContent` stamps on them.
List<CardSize> _sizes(WidgetTester tester) => [
  for (final e in find.byType(KeyedSubtree, skipOffstage: false).evaluate())
    if ((e.widget as KeyedSubtree).key case ValueKey<CardSize>(:final value))
      value,
];

Rect _rect(WidgetTester tester, Color color) => tester.getRect(
  find.byWidgetPredicate((w) => w is ColoredBox && w.color == color),
);

Rect _slot(double left, double width) => Rect.fromLTWH(left, 0, width, 600);

class _Stage extends StatefulWidget {
  const _Stage({this.expandableIndex = 1, this.withGrip = false});

  final int expandableIndex;

  /// Puts the drag on a [CardStageDragHandle] over the expandable card, the
  /// way the projection surfaces do.
  final bool withGrip;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> with TickerProviderStateMixin {
  late final CardStageController controller = CardStageController(vsync: this);
  static const _colors = [Colors.red, Colors.blue, Colors.green, Colors.amber];
  static const _labels = ['left', 'middle', 'right', 'extra'];
  List<double> _units = const [1, 2, 1];

  void setUnits(List<double> units) => setState(() => _units = units);

  void setSlotCount(int count) =>
      setState(() => _units = [for (var i = 0; i < count; i++) 1.0]);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExpandableCardStage(
      stage: controller,
      expandableIndex: widget.expandableIndex,
      expandSemanticsLabel: _expandLabel,
      collapseSemanticsLabel: _collapseLabel,
      dragSource: widget.withGrip
          ? CardStageDragSource.handle
          : CardStageDragSource.card,
      slots: [
        for (var i = 0; i < _units.length; i++)
          // Stable when it carries a grip, the way the projection cards are:
          // a size-aware slot is re-keyed on every CardSize change, so both
          // subtrees — and both grips — exist during the cross-fade.
          if (widget.withGrip && i == widget.expandableIndex)
            CardStageSlot.stable(
              units: _units[i],
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Semantics(
                      label: _labels[i],
                      child: ColoredBox(color: _colors[i]),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: CardStageDragHandle(
                      stage: controller,
                      semanticsLabel: 'grip',
                    ),
                  ),
                ],
              ),
            )
          else
            CardStageSlot(
              units: _units[i],
              builder: (_) => Stack(
                children: [
                  Positioned.fill(
                    child: Semantics(
                      label: _labels[i],
                      child: ColoredBox(color: _colors[i]),
                    ),
                  ),
                  if (widget.withGrip && i == widget.expandableIndex)
                    Align(
                      alignment: Alignment.topCenter,
                      child: CardStageDragHandle(
                        stage: controller,
                        semanticsLabel: 'grip',
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}
