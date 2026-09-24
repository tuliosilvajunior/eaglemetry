import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'card_stage_controller.dart';

/// How wide a fully-engaged peek reveals its neighbour.
enum CardPeekWidth {
  /// Half the stage — a generous look at the neighbour.
  half,

  /// One stage unit — the same width as any other 1-unit slot in the row, so
  /// the peek matches the row's own proportions instead of an unrelated
  /// fraction of the screen.
  quarter,
}

/// How much room a card currently has, so its content can be laid out for it.
///
/// A card in this stage is not a two-state thing. A permanent resize moves it a
/// quarter at a time, so in a four-unit row it can rest at 0, 1, 2 or 3
/// quarters, and the drag gesture adds a fifth state that is not a fraction of
/// the row at all. Hence five cases rather than the three the resize alone
/// would suggest.
///
/// Handed to [CardStageSlot.builder] on every frame, derived from the slot's
/// *interpolated* width, so a card resizing from 1 to 2 units reports [compact]
/// until it passes the halfway mark and [regular] after.
/// [ExpandableCardStage] cross-fades between whatever the builder returns on
/// either side of that boundary, so the swap is a dissolve rather than a cut in
/// the middle of a resize.
enum CardSize {
  /// Collapsed to nothing — a sibling took this card's last quarter. Whatever
  /// the builder returns is clipped away to zero width; the case exists so a
  /// card can return something cheap instead of laying out a full body it
  /// cannot show.
  hidden,

  /// One unit. The narrowest a card is normally laid out at.
  compact,

  /// Two units.
  regular,

  /// Three units or more.
  wide,

  /// The drag gesture has taken this card over the entire stage. Only ever
  /// reported for [ExpandableCardStage.expandableIndex], and only once the
  /// drag has settled at `expansion == 1`.
  fullscreen,
}

/// One card in an [ExpandableCardStage], left to right.
class CardStageSlot {
  const CardStageSlot({required this.units, required this.builder})
    : sizeAware = true;

  /// The common case spelled declaratively: one layout per resting step,
  /// instead of a builder that switches on [CardSize] itself.
  ///
  /// [CardSize.hidden] falls back to [compact] and [CardSize.fullscreen] to
  /// [wide], since a card that has nothing special to say at those sizes still
  /// has to render something. All three widgets are constructed on every build
  /// even though only one is used — fine for cheap, mostly-const cards, but a
  /// card whose layouts are expensive to *describe* should use [builder]
  /// directly and build only the branch it needs.
  CardStageSlot.steps({
    required this.units,
    required Widget compact,
    required Widget regular,
    required Widget wide,
    Widget? fullscreen,
  }) : sizeAware = true,
       builder = ((CardSize size) => switch (size) {
         CardSize.hidden || CardSize.compact => compact,
         CardSize.regular => regular,
         CardSize.wide => wide,
         CardSize.fullscreen => fullscreen ?? wide,
       });

  /// One layout at every size — the card looks the same docked, resized and
  /// fullscreen.
  ///
  /// Not a convenience: it is the only safe way to stage a card that owns
  /// something a rebuild would destroy. A [sizeAware] slot is re-keyed on every
  /// [CardSize] change so [ExpandableCardStage] can cross-fade the two
  /// layouts, which means the old subtree is disposed — including the `State`
  /// of anything in it. For a card holding a platform resource (a `Texture`
  /// whose producer was handed out over a channel, a video player, a map
  /// controller) that is not a cross-fade, it is a teardown, and it fires at
  /// the worst possible moment: the swap to [CardSize.fullscreen], right as
  /// the user finishes the expand gesture.
  CardStageSlot.stable({required this.units, required Widget child})
    : sizeAware = false,
      builder = ((CardSize _) => child);

  /// Width at rest, in the stage's shared unit — `1`/`2`/`1` reads the same as
  /// the dashboard grid's 1/2/1. Any ratio works as long as every slot in the
  /// same stage shares the same unit.
  ///
  /// A `double`, not an `int`, so a screen can hand this a value that changes
  /// between builds — see `CardStageResize`. [ExpandableCardStage] animates
  /// docked layout between whatever it was handed last build and this one.
  final double units;

  /// Whether [builder] can return a different layout per [CardSize], and
  /// therefore whether the stage re-keys this slot to cross-fade between them.
  /// False for [CardStageSlot.stable], whose subtree is built once and updated
  /// in place for the life of the stage.
  final bool sizeAware;

  /// Builds this card's content for the room it currently has.
  ///
  /// This is what keeps a resizing card from simply being clipped by its own
  /// shrinking [Rect]: real content — a chart, a stat grid — has no continuous
  /// "half its own width" rendering, so it needs a genuinely different layout
  /// at each step rather than the same one squeezed. Returning a different
  /// widget for a different [CardSize] is how a card says so;
  /// [ExpandableCardStage] cross-fades between them.
  final Widget Function(CardSize size) builder;
}

/// Where the drag that takes a card fullscreen may start.
enum CardStageDragSource {
  /// Anywhere on the expandable card. The default, and right for a card whose
  /// content has no drag of its own.
  card,

  /// Only from a [CardStageDragHandle] the card places over its own content.
  ///
  /// For a card whose content owns every direction of drag itself — the
  /// projection surfaces, where a vertical drag scrolls the phone's list and a
  /// horizontal one pans its map. There, the card gesture and the content
  /// gesture mean different things and no arbitration can tell them apart, so
  /// they are separated in space instead: the grip drags, everywhere else
  /// reaches the phone.
  handle,
}

/// A row of cards, one of which ([expandableIndex]) can be dragged to fill the
/// whole stage.
///
/// Replaces `Row`/`Expanded` grids like `ThreeColumnLayout` for any screen that
/// wants this gesture — those have no geometry a card could grow beyond its own
/// slot to fill the screen. Every slot here is instead an interpolated [Rect]
/// in one [Stack], recomputed each frame from [stage].
///
/// Layout rule: slots on the side the expanding card is growing into are
/// chained a constant gutter behind whichever neighbour is nearer to it, so
/// gaps never grow or shrink mid-drag — each one reads as being shoved by the
/// one in front of it, all the way off its edge of the screen. A slot collapsed
/// to zero units takes its gutter with it, so a row that loses a card closes up
/// flush instead of keeping the space it used to occupy.
///
/// Peek, once fullscreen, follows drag sign like a carousel: dragging left
/// reveals the next slot from the right edge, dragging right reveals the
/// previous slot from the left edge. Dragging toward a side with no slot at all
/// meets resistance and springs back — see [CardStageController.peek]. The
/// revealed slot always keeps a full gutter between itself and the expanded
/// card, same as any two docked cards.
///
/// Two independent ways a card can change size, and they compose freely:
/// [stage]'s drag gesture is transient (fullscreen, springs back on release),
/// while each [CardStageSlot.units] is a *resting* ratio a screen can change
/// between builds, which the stage tweens rather than snaps. The docked
/// geometry the drag expands *from* is always whatever `units` currently
/// resolves to, so a card can be resized and dragged fullscreen in either
/// order.
///
/// ## Viewport
///
/// Like the grids it replaces, this has deliberately no narrow fallback: the
/// target is a landscape head unit, composed against 1280 logical px or wider
/// and supported down to a 960 px floor. It also does not scroll vertically —
/// a card is exactly as tall as the stage — so a screen whose cards need more
/// than about 700 px of height belongs in a scrollable, not here. Read the
/// layout section of `DESIGN.md` before adding a breakpoint.
class ExpandableCardStage extends StatefulWidget {
  const ExpandableCardStage({
    required this.stage,
    required this.slots,
    required this.expandableIndex,
    required this.expandSemanticsLabel,
    required this.collapseSemanticsLabel,
    this.peekWidth = CardPeekWidth.half,
    this.dragSource = CardStageDragSource.card,
    super.key,
  }) : assert(slots.length > 0),
       assert(expandableIndex >= 0 && expandableIndex < slots.length);

  final CardStageController stage;
  final List<CardStageSlot> slots;
  final int expandableIndex;

  /// Localized action names for taking the expandable card fullscreen and
  /// bringing it back.
  ///
  /// Required, and not optional for a reason: expanding is otherwise a pan
  /// gesture and nothing else, which makes it unreachable by the rotary
  /// controller and keyboard traversal that are real input methods on Android
  /// Automotive. These are exposed as custom semantics actions on the
  /// expandable slot, so assistive technology can offer them by name.
  final String expandSemanticsLabel;
  final String collapseSemanticsLabel;

  /// How much of the stage a fully-engaged peek reveals.
  final CardPeekWidth peekWidth;

  /// Where the expand drag may start. With [CardStageDragSource.handle] the
  /// stage attaches no gesture of its own, and the expandable slot's child is
  /// responsible for placing a [CardStageDragHandle] — without one, the card
  /// can still be expanded through its semantics action, but not by touch.
  final CardStageDragSource dragSource;

  @override
  State<ExpandableCardStage> createState() => _ExpandableCardStageState();
}

class _ExpandableCardStageState extends State<ExpandableCardStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _resize = AnimationController(
    vsync: this,
    duration: AppMotion.slow,
    value: 1,
  );
  late List<double> _from = _targetUnits;
  late List<double> _to = _targetUnits;
  bool _reduceMotion = false;

  List<double> get _targetUnits => [
    for (final slot in widget.slots) slot.units,
  ];

  /// Everything the controller cannot work out for itself: which sides have a
  /// neighbour to peek at (a layout fact, known only here) and whether motion
  /// is suppressed (a `MediaQuery` fact, and the controller has no context).
  void _configureStage() {
    widget.stage
      ..setPeekNeighbours(
        previous: widget.expandableIndex > 0,
        next: widget.expandableIndex < widget.slots.length - 1,
      )
      ..reduceMotion = _reduceMotion;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _configureStage();
  }

  @override
  void didUpdateWidget(covariant ExpandableCardStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configureStage();
    final target = _targetUnits;
    if (!listEquals(target, _to)) {
      // Snapshot wherever the interpolation currently sits, not `_to`, so a
      // resize interrupted mid-flight reverses smoothly instead of jumping
      // back to its start. Rebuilt to `target`'s length rather than copied
      // wholesale: a stage handed a different number of slots than it had last
      // build would otherwise leave `_from` shorter than `_to`, and every
      // later frame would index past its end. A slot that did not exist before
      // has nowhere to tween from, so it starts already at its target.
      final current = _currentUnits;
      _from = [
        for (var i = 0; i < target.length; i++)
          i < current.length ? current[i] : target[i],
      ];
      _to = target;
      if (_reduceMotion) {
        _resize.value = 1;
      } else {
        _resize
          ..value = 0
          ..animateTo(1, curve: AppMotion.curve);
      }
    }
  }

  List<double> get _currentUnits => [
    for (var i = 0; i < _to.length; i++)
      lerpDouble(_from[i], _to[i], _resize.value)!,
  ];

  @override
  void dispose() {
    _resize.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return AnimatedBuilder(
              animation: Listenable.merge([widget.stage, _resize]),
              builder: (context, _) => _layout(size),
            );
          },
        ),
      ),
    );
  }

  /// How much of a full gutter separates each slot from the one before it, as
  /// a fraction. Index 0 is always 0 — the row has no leading gutter.
  ///
  /// A gutter exists to separate two visible cards, so it belongs to a *pair*,
  /// not to a slot: it is there to the degree that this slot is present and
  /// something before it is too. Charging every boundary a full gutter — which
  /// is what `gutter * (slots.length - 1)` does — makes a row whose first card
  /// has collapsed to nothing start 24px inset from its own left edge, with a
  /// gap separating a card from a card that is not there.
  ///
  /// Continuous in `units` rather than a visible/hidden test, so a card
  /// shrinking to nothing takes its gutter with it over the same tween instead
  /// of the row jolting sideways when it crosses some threshold.
  static List<double> _gutterFractions(List<double> units) {
    final gaps = List<double>.filled(units.length, 0);
    var priorPresence = units[0].clamp(0.0, 1.0);
    for (var i = 1; i < units.length; i++) {
      final presence = units[i].clamp(0.0, 1.0);
      gaps[i] = math.min(presence, priorPresence);
      priorPresence = math.max(priorPresence, presence);
    }
    return gaps;
  }

  Widget _layout(Size size) {
    final stage = widget.stage;
    final slots = widget.slots;
    final expandableIndex = widget.expandableIndex;
    final peekWidth = widget.peekWidth;
    final units = _currentUnits;

    const gutter = AppSpacing.gridGutter;
    final gaps = _gutterFractions(units);
    final totalUnits = units.fold<double>(0, (sum, u) => sum + u);
    final gutterSpace = gaps.fold<double>(0, (sum, gap) => sum + gap) * gutter;
    // Every slot collapsed at once has no width to distribute. Guarded rather
    // than asserted: it is a legal, if odd, resting state, and dividing by it
    // would put NaN into every rect and take the whole frame down.
    final unit = totalUnits <= 0
        ? 0.0
        : (size.width - gutterSpace) / totalUnits;

    final docked = <Rect>[];
    var x = 0.0;
    for (var i = 0; i < slots.length; i++) {
      x += gaps[i] * gutter;
      final width = unit * units[i];
      docked.add(Rect.fromLTWH(x, 0, width, size.height));
      x += width;
    }

    final expansion = stage.expansion;
    final peek = stage.peek;
    final reveal = peek.abs().clamp(0.0, 1.0);
    final fullscreen = expansion >= 0.999;

    // The expanding slot's actual leading/trailing edges, without the peek
    // nudge — the shove chains below anchor to this, not to the displayed
    // (peek-shifted) rect, so a sideways peek never feeds back into how far
    // the offscreen siblings have travelled.
    final growth = Rect.lerp(
      docked[expandableIndex],
      Offset.zero & size,
      expansion,
    )!;

    final rects = List<Rect?>.filled(slots.length, null);

    var edge = growth.left;
    for (var i = expandableIndex - 1; i >= 0; i--) {
      final width = unit * units[i];
      final gap = gaps[i + 1] * gutter;
      final rect = Rect.fromLTWH(edge - gap - width, 0, width, size.height);
      rects[i] = rect;
      edge = rect.left;
    }
    edge = growth.right;
    for (var i = expandableIndex + 1; i < slots.length; i++) {
      final width = unit * units[i];
      final rect = Rect.fromLTWH(
        edge + gaps[i] * gutter,
        0,
        width,
        size.height,
      );
      rects[i] = rect;
      edge = rect.right;
    }

    // peek > 0: dragged right, reveal the previous (left) slot from the left
    // edge. peek < 0: dragged left, reveal the next (right) slot from the
    // right edge. Read unconditionally, which is why `CardStageController`
    // has to start `peek` at 0 explicitly rather than letting it default to
    // its own lower bound.
    final revealWidth = switch (peekWidth) {
      CardPeekWidth.half => size.width * 0.5,
      // Exactly one stage unit — the same width any ordinary 1-unit slot in
      // this row already has, so the peek reads as "a normal card sliding
      // in," not an arbitrary sliver.
      CardPeekWidth.quarter => unit,
    };
    // The expanded card makes room by the reveal's width plus one gutter, so
    // at full peek there is a real gutter between the two — not the reveal
    // sliding flush up against whatever the expanded card's edge happens to
    // land on.
    final expandShift = revealWidth + gutter;
    int? revealIndex;
    if (peek > 0 && expandableIndex - 1 >= 0) {
      revealIndex = expandableIndex - 1;
      rects[revealIndex] = Rect.fromLTWH(
        -revealWidth + reveal * revealWidth,
        0,
        revealWidth,
        size.height,
      );
    } else if (peek < 0 && expandableIndex + 1 < slots.length) {
      revealIndex = expandableIndex + 1;
      rects[revealIndex] = Rect.fromLTWH(
        size.width - reveal * revealWidth,
        0,
        revealWidth,
        size.height,
      );
    }

    rects[expandableIndex] = growth.translate(peek * expandShift, 0);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < slots.length; i++)
          Positioned.fromRect(
            rect: rects[i]!,
            child: i == expandableIndex
                ? _DraggableSlot(
                    stage: stage,
                    dragSource: widget.dragSource,
                    expandLabel: widget.expandSemanticsLabel,
                    collapseLabel: widget.collapseSemanticsLabel,
                    child: _SlotContent(
                      slot: slots[i],
                      size: fullscreen
                          ? CardSize.fullscreen
                          : _sizeFor(units[i]),
                      reduceMotion: _reduceMotion,
                    ),
                  )
                : _DockedSlot(
                    // A sibling shoved off the edge by an expanding card is
                    // gone as far as the user is concerned, and a revealed
                    // one is only there once it has actually come in.
                    // `IgnorePointer` takes it out of hit testing but leaves
                    // it in the semantics tree, where a screen reader would
                    // happily announce three off-screen cards sitting behind
                    // the fullscreen one.
                    inert: i == revealIndex ? reveal <= 0 : expansion > 0.001,
                    child: _SlotContent(
                      slot: slots[i],
                      size: _sizeFor(units[i]),
                      reduceMotion: _reduceMotion,
                    ),
                  ),
          ),
      ],
    );
  }

  /// Buckets a slot's live, interpolated width into a [CardSize]. Rounded to
  /// the nearest step rather than floored, so a card growing 1 → 2 swaps to
  /// its wider layout halfway through the resize instead of only once the
  /// animation lands — the cross-fade in [_SlotContent] then has the second
  /// half of the resize to run in, which is what keeps the swap from reading
  /// as a late jolt.
  static CardSize _sizeFor(double units) {
    if (units < 0.5) return CardSize.hidden;
    if (units < 1.5) return CardSize.compact;
    if (units < 2.5) return CardSize.regular;
    return CardSize.wide;
  }
}

/// One slot's content, cross-fading whenever its [CardSize] changes.
///
/// The alternative — swapping the layout outright — reads as a flicker in the
/// middle of an otherwise continuous resize. [AnimatedSwitcher] keeps the
/// outgoing layout around for the length of the fade, so the card dissolves
/// from one to the other while its box keeps moving underneath.
class _SlotContent extends StatelessWidget {
  const _SlotContent({
    required this.slot,
    required this.size,
    required this.reduceMotion,
  });

  final CardStageSlot slot;
  final CardSize size;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    // Nothing to cross-fade between, so no key and no switcher: the subtree is
    // built once and updated in place. Keeping the switcher here would re-key
    // the slot at every size change and dispose the layout it is fading out of
    // — for `CardStageSlot.stable` that is a teardown of state the card owns,
    // not a dissolve. `Positioned.fromRect` already constrains this tightly,
    // which is all the switcher's `layoutBuilder` was adding.
    if (!slot.sizeAware) return slot.builder(size);
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : AppMotion.base,
      switchInCurve: AppMotion.curve,
      switchOutCurve: AppMotion.curve,
      // `AnimatedSwitcher`'s default layout stacks its children *loosely*,
      // which would quietly undo the tight constraints `Positioned.fromRect`
      // hands each slot: a card would shrink-wrap its content instead of
      // filling its box, and one with no intrinsic size would collapse
      // outright. Expanding the stack gives both the outgoing and incoming
      // layout the slot's full rect, which is also what makes them cross-fade
      // in place rather than at two different sizes.
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [?currentChild, ...previousChildren],
      ),
      // Keyed on the size, not on what the builder happens to return: two
      // steps may legitimately return the same widget type, and without a key
      // `AnimatedSwitcher` would treat that as no change at all.
      child: KeyedSubtree(key: ValueKey(size), child: slot.builder(size)),
    );
  }
}

/// A slot that is not the expandable one: present, but taken out of both hit
/// testing and semantics whenever it has been shoved out of the way.
class _DockedSlot extends StatelessWidget {
  const _DockedSlot({required this.inert, required this.child});

  final bool inert;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      excluding: inert,
      child: IgnorePointer(ignoring: inert, child: child),
    );
  }
}

class _DraggableSlot extends StatelessWidget {
  const _DraggableSlot({
    required this.stage,
    required this.dragSource,
    required this.expandLabel,
    required this.collapseLabel,
    required this.child,
  });

  final CardStageController stage;
  final CardStageDragSource dragSource;
  final String expandLabel;
  final String collapseLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fullscreen = stage.isFullscreen;
    return Semantics(
      container: true,
      // A custom action rather than `onTap`: the card is full of its own
      // controls, and turning the whole thing into a button would swallow
      // them. This offers "expand"/"collapse" by name in the assistive
      // actions menu while everything inside keeps its own semantics.
      //
      // It stays here, and not on the handle, under either drag source: it is
      // the *card* that expands, and a rotary or screen-reader user should
      // find the action on the card rather than having to land on a grip.
      customSemanticsActions: {
        CustomSemanticsAction(label: fullscreen ? collapseLabel : expandLabel):
            fullscreen ? stage.collapse : stage.expand,
      },
      child: dragSource == CardStageDragSource.handle
          ? child
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => stage.dragStart(),
              onPanUpdate: (details) => stage.dragUpdate(details),
              onPanEnd: (details) => stage.dragEnd(details),
              child: child,
            ),
    );
  }
}

/// The grip that drags a card fullscreen when the stage's drag source is
/// [CardStageDragSource.handle].
///
/// A floating pill, not a bar: it is meant to be stacked *over* the card's
/// content, so it takes no layout height away from what it sits on. Place it
/// with a [Stack] and [Align] inside the expandable slot's child.
///
/// It carries the same three callbacks the whole-card gesture used, so the
/// motion is identical — only the area that starts it is different.
class CardStageDragHandle extends StatefulWidget {
  const CardStageDragHandle({
    required this.stage,
    required this.semanticsLabel,
    this.width = 96,
    super.key,
  });

  final CardStageController stage;

  /// Names the grip for assistive technology. The action itself lives on the
  /// card (see [_DraggableSlot]); this only says what the thing under the
  /// finger is.
  final String semanticsLabel;

  final double width;

  /// The pill's own height. The touch target around it is [_targetHeight],
  /// which is what the 64px automotive rule measures.
  static const double _pillHeight = 6;
  static const double _targetHeight = AppSizes.minTouchTarget;

  /// How much wider the pill gets while a finger is on it.
  static const double _pressedGrowth = 16;

  /// How long the grip stays at full strength after the last interaction.
  ///
  /// It sits over live video, so it cannot simply stay bright: the picture
  /// under it is the reason the card is there. It also cannot disappear — a
  /// control that has to be discovered twice is not a control — so it fades to
  /// [_idleOpacity] instead, which is still legible against both a light and a
  /// dark frame while what is behind it stays readable.
  static const idleDelay = Duration(seconds: 4);
  static const double _idleOpacity = 0.3;

  @override
  State<CardStageDragHandle> createState() => _CardStageDragHandleState();
}

class _CardStageDragHandleState extends State<CardStageDragHandle> {
  bool _pressed = false;
  bool _idle = false;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    // The stage itself counts as interaction: a card that is moving must not
    // fade out from under the finger that is moving it.
    widget.stage.addListener(_wake);
    _wake();
  }

  @override
  void didUpdateWidget(CardStageDragHandle old) {
    super.didUpdateWidget(old);
    if (old.stage != widget.stage) {
      old.stage.removeListener(_wake);
      widget.stage.addListener(_wake);
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    widget.stage.removeListener(_wake);
    super.dispose();
  }

  /// Brings the grip back to full strength and restarts the clock.
  void _wake() {
    _idleTimer?.cancel();
    _idleTimer = Timer(CardStageDragHandle.idleDelay, () => _setIdle(true));
    _setIdle(false);
  }

  void _setIdle(bool value) {
    if (mounted && _idle != value) setState(() => _idle = value);
  }

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final stage = widget.stage;
    // A pill alone says "something is here", not "this moves, and it moves
    // that way". The chevron names the direction, and it turns with the
    // expansion rather than snapping at the end, so the drag itself is what
    // confirms the reading. Nothing here animates on its own: a shape that
    // moves without being touched competes with the road.
    return Semantics(
      label: widget.semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanDown: (_) {
          _wake();
          _setPressed(true);
        },
        onPanCancel: () {
          _wake();
          _setPressed(false);
        },
        onPanStart: (_) => stage.dragStart(),
        onPanUpdate: (details) => stage.dragUpdate(details),
        onPanEnd: (details) {
          _setPressed(false);
          stage.dragEnd(details);
          // After the gesture, not before: the clock has to start from the
          // finger lifting, or a long drag would fade under it.
          _wake();
        },
        child: SizedBox(
          width:
              widget.width +
              CardStageDragHandle._pressedGrowth +
              AppSpacing.x6 * 2,
          height: CardStageDragHandle._targetHeight,
          child: AnimatedBuilder(
            animation: stage,
            builder: (context, _) {
              // Over video, and video is anything: a tone that reads on a
              // white map and on a black album cover has to bring its own
              // contrast rather than borrow the theme's. Hence the light ink
              // over a darker scrim of its own, both translucent.
              final ink = colors.onInverseSurface.withValues(
                alpha: _pressed ? 0.95 : 0.72,
              );
              final shadow = [
                BoxShadow(
                  color: colors.inverseSurface.withValues(alpha: 0.45),
                  blurRadius: 6,
                ),
              ];
              return AnimatedOpacity(
                // Slow on purpose. A quick fade is a blink at the edge of the
                // eye, which is exactly the movement a driving surface must
                // not make; over most of a second it is a thing settling.
                // A finger on it holds it awake regardless of the clock: a
                // grip held still for a moment mid-drag is being used, not
                // abandoned.
                opacity: _idle && !_pressed
                    ? CardStageDragHandle._idleOpacity
                    : 1.0,
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOut,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.rotate(
                      // Up while there is room to grow, down once it fills the
                      // screen. Halfway through a drag it points sideways, which
                      // is the honest reading of a card that is halfway.
                      angle: stage.expansion * math.pi,
                      child: Icon(
                        Icons.keyboard_arrow_up,
                        size: 20,
                        color: ink,
                        shadows: shadow,
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      width:
                          widget.width +
                          (_pressed ? CardStageDragHandle._pressedGrowth : 0),
                      height: CardStageDragHandle._pillHeight,
                      decoration: BoxDecoration(
                        color: ink,
                        borderRadius: BorderRadius.circular(
                          CardStageDragHandle._pillHeight / 2,
                        ),
                        boxShadow: shadow,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
