import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../tokens/app_spacing.dart';

enum _DragAxis { vertical, horizontal }

/// Drives the drag-to-fullscreen gesture for one card in an
/// `ExpandableCardStage`.
///
/// Generic on purpose: the gesture math has nothing card-specific in it, only
/// the stage's layout does. Two independent values, each backed by its own
/// [AnimationController] so they can be driven directly during a drag (no
/// easing — a position under a finger must never lag it) and eased with
/// `AppMotion.curve` on release:
///
/// - [expansion]: 0 docked, 1 fullscreen. Vertical drag while not fullscreen.
/// - [peek]: -1..1, only meaningful once [isFullscreen]. Horizontal drag once
///   fullscreen, showing a neighbour card at the dragged-from edge — which
///   neighbour depends on sign, since a card in the middle of a row has one on
///   each side. Always springs back to 0 on release: a peek previews, it does
///   not commit.
///
/// One physical pan gesture can carry both: drag up past the fullscreen
/// threshold, keep the same finger down, and drag sideways. The axis is
/// decided once per gesture, like `PageView`/`Scrollable` axis locking, but
/// only after the drag has travelled [_axisSlop] and only counting motion that
/// could actually mean something — see [dragUpdate].
///
/// ## Ownership
///
/// Own this above whichever widget hosts the stage, not inside it: expanding a
/// card normally has to hide chrome (a tab bar, a header) that lives outside
/// the stage's own subtree, and that chrome has to move on the same clock. One
/// instance can be shared by several screens as long as only one of them is
/// visible at a time — call [collapse] when navigating between them, or a card
/// left mid-gesture strands the chrome hidden with nothing left to collapse it.
///
/// Whoever creates it must [dispose] it, and must keep [reduceMotion] in sync
/// with `MediaQuery.disableAnimations`. `ExpandableCardStage` does the latter
/// for you.
class CardStageController extends ChangeNotifier {
  CardStageController({
    required TickerProvider vsync,
    this.expandDistance = AppSizes.cardStageExpandDistance,
    this.peekDistance = AppSizes.cardStagePeekDistance,
  }) : _expansion = AnimationController(vsync: vsync, duration: AppMotion.slow),
       _peek = AnimationController(
         vsync: vsync,
         // Explicit, and load-bearing: `AnimationController` starts at
         // `lowerBound` when no value is given, so a -1..1 controller would sit
         // at -1 — a fully-engaged peek — from its very first frame, before any
         // gesture. The stage reads `peek` unconditionally, so that renders the
         // expandable card shoved most of a screen off its own edge, with a
         // neighbour revealed beside it, until something calls [collapse].
         value: 0,
         duration: AppMotion.base,
         lowerBound: -1,
         upperBound: 1,
       ) {
    _expansion.addListener(notifyListeners);
    _peek.addListener(notifyListeners);
  }

  /// Drag distance, in logical pixels, that carries [expansion] from 0 to 1.
  final double expandDistance;

  /// Drag distance that carries [peek] from 0 to 1.
  final double peekDistance;

  /// How far a fullscreen drag must travel before it commits to an axis.
  /// Without it the very first post-fullscreen frame decides, so a half-pixel
  /// of diagonal jitter could pick the wrong one for the rest of the gesture.
  static const _axisSlop = kTouchSlop;

  final AnimationController _expansion;
  final AnimationController _peek;
  _DragAxis? _axis;

  /// Motion accumulated since the gesture reached fullscreen, held until it
  /// clears [_axisSlop] and picks [_axis]. Applied in full on the frame that
  /// commits, so the slop is a threshold rather than a swallowed dead zone.
  Offset _pending = Offset.zero;

  /// Where the peek gesture has travelled, before resistance. Equal to [peek]
  /// whenever the dragged-toward side has a neighbour; ahead of it when the
  /// side is empty and [_resist] is holding the card back. Kept separately
  /// because the resisted value alone cannot say how much finger travel it
  /// took to get there, so a drag back out would not retrace its own path.
  double _rawPeek = 0;

  bool _hasPrevious = false;
  bool _hasNext = false;

  /// Whether settling animations are suppressed, per
  /// `MediaQuery.disableAnimations`. `ExpandableCardStage` keeps this in sync;
  /// a screen driving the controller without one has to set it itself.
  ///
  /// This deliberately does *not* affect the drag. Following a finger is
  /// direct manipulation, not decoration — freezing it would make the card
  /// unusable rather than calmer, the same rule `LimitSlider` follows for its
  /// knob. What it suppresses is everything the gesture hands off to: the peek
  /// springing back, the settle after release, [expand] and [collapse].
  bool reduceMotion = false;

  double get expansion => _expansion.value;

  /// -1..1. Positive reveals the previous (left) slot, negative the next
  /// (right) one.
  ///
  /// This is always what is actually on screen, resistance included — never
  /// raw finger travel. A card dragged toward an edge with nothing behind it
  /// gets [AppSizes.cardStagePeekResistance] of travel at most, so consumers
  /// reading this to move something else (chrome, an indicator) stay in step
  /// with the card instead of overshooting it.
  double get peek => _peek.value;

  bool get isFullscreen => _expansion.value >= 0.999;

  /// How much of the surrounding chrome should show. Inverse of [expansion] so
  /// a header is fully hidden exactly when the card has fully taken over.
  double get chromeVisibility => 1 - _expansion.value;

  /// Told by the stage which sides actually have a slot to reveal, so a peek
  /// toward an empty edge can push back instead of sliding freely.
  ///
  /// Presence means a slot *exists* at that index, not that it currently has
  /// width: a card collapsed to nothing by a permanent resize is still a real
  /// card, and previewing it is a reasonable way to find it again.
  void setPeekNeighbours({required bool previous, required bool next}) {
    _hasPrevious = previous;
    _hasNext = next;
  }

  /// Maps peek travel to displayed peek. Identity toward a side that has a
  /// neighbour; asymptotic resistance toward one that does not.
  ///
  /// `limit * x / (x + limit)` starts at exactly 1:1 — the first pixel of a
  /// gesture always tracks the finger, so the edge never feels dead — then
  /// falls away, approaching `limit` and never reaching it. The card gives a
  /// little, keeps giving less, and springs back on release: the standard
  /// overscroll conversation, which is what the row is really saying here.
  static double _resist(double magnitude) {
    const limit = AppSizes.cardStagePeekResistance;
    return limit * magnitude / (magnitude + limit);
  }

  /// Inverse of [_resist], for resuming a gesture mid-spring-back.
  static double _unresist(double magnitude) {
    const limit = AppSizes.cardStagePeekResistance;
    if (magnitude >= limit) return 1;
    return limit * magnitude / (limit - magnitude);
  }

  bool _hasNeighbourToward(double raw) => raw > 0 ? _hasPrevious : _hasNext;

  double _displayPeek(double raw) {
    if (raw == 0 || _hasNeighbourToward(raw)) return raw;
    final resisted = _resist(raw.abs());
    return raw.isNegative ? -resisted : resisted;
  }

  double _travelPeek(double display) {
    if (display == 0 || _hasNeighbourToward(display)) return display;
    final travel = _unresist(display.abs());
    return display.isNegative ? -travel : travel;
  }

  void _settle(AnimationController controller, double target) {
    if (reduceMotion) {
      controller.value = target;
      return;
    }
    controller.animateTo(target, curve: AppMotion.curve);
  }

  void dragStart() {
    _axis = null;
    _pending = Offset.zero;
    // A finger landing during the spring-back has to pick the card up from
    // where it visibly is, so recover the travel that produced the current
    // position rather than assuming the gesture starts from rest.
    _rawPeek = _travelPeek(_peek.value);
  }

  void dragUpdate(DragUpdateDetails details) {
    final delta = details.delta;
    if (!isFullscreen) {
      _expansion.value = (_expansion.value - delta.dy / expandDistance).clamp(
        0.0,
        1.0,
      );
      return;
    }
    var effective = delta;
    if (_axis == null) {
      // Upward travel is dropped from the decision, not just from the slop:
      // at fullscreen `expansion` is already clamped at 1, so dragging further
      // up cannot mean anything. It is also, unavoidably, what the finger is
      // doing on the frames right after it crosses the threshold — counting
      // those is what used to lock every expanding gesture to `vertical` and
      // make "expand, then slide sideways without lifting" impossible.
      _pending += Offset(delta.dx, delta.dy > 0 ? delta.dy : 0);
      if (_pending.distance < _axisSlop) return;
      _axis = _pending.dx.abs() > _pending.dy.abs()
          ? _DragAxis.horizontal
          : _DragAxis.vertical;
      effective = _pending;
      _pending = Offset.zero;
    }
    if (_axis == _DragAxis.horizontal) {
      // Travel is clamped, not the displayed value, so dragging far past the
      // resistance limit and back retraces instead of spending the return
      // trip on slack the card never showed.
      _rawPeek = (_rawPeek + effective.dx / peekDistance).clamp(-1.0, 1.0);
      _peek.value = _displayPeek(_rawPeek);
    } else {
      _expansion.value = (_expansion.value - effective.dy / expandDistance)
          .clamp(0.0, 1.0);
    }
  }

  void dragEnd(DragEndDetails details) {
    _pending = Offset.zero;
    if (_axis == _DragAxis.horizontal) {
      _rawPeek = 0;
      _settle(_peek, 0);
      _axis = null;
      return;
    }
    final flingDy = details.velocity.pixelsPerSecond.dy;
    final target = flingDy < -AppSizes.cardStageFlingVelocity
        ? 1.0
        : flingDy > AppSizes.cardStageFlingVelocity
        ? 0.0
        : (_expansion.value > 0.5 ? 1.0 : 0.0);
    _settle(_expansion, target);
    _axis = null;
  }

  /// Takes the card fullscreen without a gesture. Backs the stage's semantics
  /// action, so the affordance is reachable by rotary and keyboard traversal
  /// rather than by pan alone.
  void expand() {
    _axis = null;
    _pending = Offset.zero;
    if (_expansion.value == 1) return;
    _settle(_expansion, 1);
  }

  /// Programmatic collapse — used when navigating away from a screen while a
  /// card is expanded, so returning to it (or to another screen sharing this
  /// controller) starts from a clean slate.
  void collapse() {
    _axis = null;
    _pending = Offset.zero;
    _rawPeek = 0;
    if (_expansion.value == 0 && _peek.value == 0) return;
    _settle(_expansion, 0);
    _settle(_peek, 0);
  }

  @override
  void dispose() {
    _expansion.dispose();
    _peek.dispose();
    super.dispose();
  }
}
