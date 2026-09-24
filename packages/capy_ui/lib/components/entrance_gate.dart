import 'package:flutter/material.dart';

/// Whether widgets in this subtree may mount yet, and therefore whether their
/// entrance animations may play.
///
/// The rule this exists to express is "an entrance plays once, on the frame its
/// screen finishes arriving — and never again." Two things make that awkward to
/// say directly:
///
///  * An entrance is normally started by the animating widget's own
///    `initState` (`EnergyBarChart` and `SegmentedDonut` both do
///    `_controller.forward(from: 0)` there), so the entrance is really a
///    property of *when the widget mounts*, not of a flag it reads. There is no
///    parameter to set.
///  * `MediaQuery.disableAnimations` — the obvious lever — does the opposite of
///    what is wanted: it clamps an animated widget's paint to its *final*
///    frame (see `EnergyBarChart.build`'s `shouldAnimate`), so a screen
///    suppressed that way transitions in fully drawn. It is also an
///    accessibility setting, and forging it over a subtree makes the real one
///    stop meaning what it says.
///
/// So the gate does not try to freeze anything: it decides whether the widget
/// is *built at all*. Closed, [guard] holds the footprint open and empty, which
/// is how a screen should read while it is still moving. Open, the widget
/// mounts for the first time and animates in from zero on its own, with no
/// changes on its side.
///
/// Make the gate one-way — open it and never take it back — and the "never
/// again" half follows for free: the subtree stays mounted, so returning to it
/// shows the settled state instead of replaying. Whoever owns the gate is
/// responsible for that; nothing here enforces it.
///
/// ```dart
/// EntranceGate(
///   open: _arrived.contains(destination),
///   child: MyScreen(),
/// )
/// ```
///
/// Two things this deliberately does *not* do:
///
///  * **It gates the entrance only.** Once mounted, a widget keeps animating
///    its own value changes — a live chart still waves new bars in. That is a
///    different animation and the gate has nothing to do with it.
///  * **It has no reduced-motion branch.** Mounting is not an animation, and
///    the widget being gated already honours `MediaQuery.disableAnimations`
///    itself (`DESIGN.md`, Motion). Holding it back is about not showing a
///    half-arrived screen, which is just as true when motion is off.
class EntranceGate extends InheritedWidget {
  const EntranceGate({required this.open, required super.child, super.key});

  /// Whether the subtree may mount its animated content yet.
  final bool open;

  /// The default footprint [guard] holds open while the gate is closed: as
  /// much room as the slot gives it, drawing nothing.
  static const defaultPlaceholder = SizedBox.expand();

  /// Whether there is an open gate above [context].
  ///
  /// True when there is no gate at all, so a widget dropped into the gallery, a
  /// test, or any screen that does not gate its entrances just draws normally.
  /// Prefer [guard] — read this directly only when the closed state cannot be
  /// expressed as a replacement widget.
  static bool isOpen(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EntranceGate>()?.open ?? true;

  /// Builds [child] once the gate is open, and renders [placeholder] until
  /// then.
  ///
  /// [child] is a callback rather than a widget so a closed gate does not pay
  /// to describe what it is not going to show.
  ///
  /// [placeholder] defaults to [defaultPlaceholder], which fills whatever room
  /// the caller already reserved. Pass something else when that is the wrong
  /// shape — a card whose chart is one row of a `Column` wants the chart's own
  /// height, not everything left over. Whatever is passed should occupy the
  /// same space the real content will, or the surrounding layout jumps at the
  /// moment the gate opens, which is exactly the flicker this is here to avoid.
  /// It should also stay out of the semantics tree: a screen reader announcing
  /// an empty box is worse than announcing nothing.
  static Widget guard(
    BuildContext context,
    Widget Function() child, {
    Widget placeholder = defaultPlaceholder,
  }) => isOpen(context) ? child() : placeholder;

  @override
  bool updateShouldNotify(EntranceGate oldWidget) => open != oldWidget.open;
}
