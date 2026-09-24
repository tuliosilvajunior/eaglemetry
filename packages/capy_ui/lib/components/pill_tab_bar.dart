import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One entry in a tab component.
class TabItem<T> {
  const TabItem({required this.value, required this.label});

  final T value;

  /// Localized label.
  final String label;
}

/// Page-level tab bar: the selected tab is a filled [AppColors.selectionFill]
/// pill, unselected tabs are bare [AppColors.ink] labels on the canvas.
///
/// One of three tab components that must not be substituted for each other —
/// see `DESIGN.md`. This one sits above the card grid and switches the whole
/// screen.
///
/// The selected pill is **one shape that slides** between tab positions, and
/// every label inverts pixel-for-pixel with it: wherever the fill currently
/// covers a letter that letter is [AppColors.onSelection], everywhere else it
/// is [AppColors.ink]. The boundary comes from the same [Rect] that positions
/// the fill, not from a per-item selected flag, so the fill and the text read
/// as one surface even mid-slide, when the fill covers only part of a label.
///
/// Pill rects are measured per item through [GlobalKey]s rather than computed,
/// because labels are localized and so have no proportional grid to divide —
/// unlike `ExpandableCardStage`, which does. Measuring is also what makes the
/// bar correct inside the horizontal scroll view `AppJourneyScaffold` wraps it
/// in: every rect is measured against the [Stack] that holds both the pill and
/// the labels, and that whole stack is the scrolled child, so a scroll offset
/// moves the pill and its labels together and never enters the arithmetic.
///
/// ## Where the slide comes from
///
/// By default the bar animates itself: [selected] changes, and the pill travels
/// to the new tab over [AppMotion.base]. Retargeting mid-flight is continuous —
/// a second tap starts from wherever the pill currently is, not from the tab it
/// left.
///
/// [position] replaces that with an external driver, and exists for one reason:
/// a shell whose bodies *roll* sideways between tabs has to keep the pill in
/// step with the cards underneath it. Give it the roll's own continuous
/// position — `PageController.page`, wrapped in a [ValueListenable] — and the
/// pill cannot drift from the cards, because there is no second animation to
/// drift with. A shell that cuts between bodies (an `IndexedStack`) has no such
/// value and should leave this null.
class PillTabBar<T> extends StatefulWidget {
  const PillTabBar({
    required this.items,
    required this.selected,
    required this.onSelected,
    this.position,
    super.key,
  });

  final List<TabItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;

  /// External driver for the pill, as a continuous fractional index into
  /// [items] — `1.5` sits halfway between the second and third tabs.
  ///
  /// Null means the bar animates itself off [selected]. When it is set, the bar
  /// never runs its own animation, and reduced motion is the driver's business
  /// rather than this widget's.
  final ValueListenable<double>? position;

  @override
  State<PillTabBar<T>> createState() => _PillTabBarState<T>();
}

class _PillTabBarState<T> extends State<PillTabBar<T>>
    with SingleTickerProviderStateMixin {
  final _stackKey = GlobalKey();
  late List<GlobalKey> _pillKeys;

  /// One measured rect per item, indexed like [PillTabBar.items].
  ///
  /// Every rect, not only the selected one: a jump spanning several tabs passes
  /// continuously through each tab in between, so each one is a waypoint the
  /// pill has to interpolate through rather than a corner it cuts.
  late List<Rect?> _rects;

  late final AnimationController _slide;

  /// The fractional index the pill travels between while [_slide] runs.
  double _from = 0;
  double _to = 0;

  bool _reduceMotion = false;
  bool _measureScheduled = false;

  int get _selectedIndex =>
      widget.items.indexWhere((item) => item.value == widget.selected);

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: AppMotion.base,
      value: 1,
    );
    _resetMeasurements();
    final selected = _selectedIndex;
    _from = _to = selected < 0 ? 0 : selected.toDouble();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  }

  @override
  void didUpdateWidget(covariant PillTabBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) _resetMeasurements();
    final target = _selectedIndex;
    if (target < 0 || target.toDouble() == _to) return;
    // Retarget from where the pill actually is, so interrupting a slide bends
    // it toward the new tab instead of restarting it from the old one.
    _from = _position;
    _to = target.toDouble();
    if (_reduceMotion || widget.position != null) {
      _slide.value = 1;
    } else {
      _slide.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  void _resetMeasurements() {
    _pillKeys = List.generate(widget.items.length, (_) => GlobalKey());
    _rects = List<Rect?>.filled(widget.items.length, null);
  }

  /// Measures after the frame this build produces.
  ///
  /// Called from `build` rather than only from [didUpdateWidget], because the
  /// things that move a pill are not all widget changes: a text-scale change
  /// relays out the labels without changing a single field of this widget. That
  /// is also why `build` reads the text scaler — the read is what makes this
  /// widget rebuild when the scale changes.
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measure();
    });
  }

  void _measure() {
    if (!mounted) return;
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    final rects = List<Rect?>.filled(_pillKeys.length, null);
    var changed = false;
    for (var i = 0; i < _pillKeys.length; i++) {
      final pillBox =
          _pillKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (pillBox == null || !pillBox.hasSize) continue;
      rects[i] =
          pillBox.localToGlobal(Offset.zero, ancestor: stackBox) & pillBox.size;
      if (i >= _rects.length || _rects[i] != rects[i]) changed = true;
    }
    if (!changed) return;
    setState(() => _rects = rects);
  }

  double get _position {
    final external = widget.position;
    if (external != null) return external.value;
    final t = AppMotion.curve.transform(_slide.value);
    return _from + (_to - _from) * t;
  }

  /// The pill's rect for this frame: a lerp between the two measured tabs the
  /// current position sits between.
  Rect? get _indicator {
    if (_rects.isEmpty) return null;
    if (widget.position == null && _selectedIndex < 0) return null;
    final position = _position.clamp(0.0, (_rects.length - 1).toDouble());
    final low = position.floor();
    final high = position.ceil();
    if (_rects[low] == null || _rects[high] == null) return null;
    return Rect.lerp(_rects[low], _rects[high], position - low);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final painting = _LabelPainting.of(context);
    _scheduleMeasure();
    return AnimatedBuilder(
      animation: widget.position ?? _slide,
      builder: (context, _) {
        final indicator = _indicator;
        return Stack(
          key: _stackKey,
          clipBehavior: Clip.none,
          children: [
            if (indicator != null)
              Positioned.fromRect(
                rect: indicator,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.selectionFill,
                      borderRadius: AppRadii.mdRadius,
                    ),
                  ),
                ),
              ),
            _TabRow<T>(
              items: widget.items,
              painting: painting,
              textColor: colors.ink,
              pillKeys: _pillKeys,
              selectedIndex: _selectedIndex,
              onSelected: widget.onSelected,
            ),
            if (indicator != null)
              Positioned.fromRect(
                rect: indicator,
                // The mask is the same labels a second time. `ExcludeSemantics`
                // keeps a screen reader from announcing every tab twice;
                // `IgnorePointer` keeps the real row's taps reachable through
                // it.
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: 0,
                        maxWidth: double.infinity,
                        minHeight: indicator.height,
                        maxHeight: indicator.height,
                        child: Transform.translate(
                          offset: -indicator.topLeft,
                          child: _TabRow<T>(
                            items: widget.items,
                            painting: painting,
                            textColor: colors.onSelection,
                            mask: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Adapts a [PageController] to [PillTabBar.position], so a shell whose tab
/// bodies roll drives its pill off the roll itself.
///
/// Reads `page` live instead of caching it: the value is only ever asked for
/// while painting a frame the controller just notified about, and a cached copy
/// would be one frame stale for the whole slide.
///
/// Falls back to [PageController.initialPage] whenever `page` cannot be read —
/// before the controller is attached to a viewport, and while more than one
/// viewport is attached, when it is ambiguous. Both are transient, and both
/// would otherwise throw.
class PageTabPosition extends ChangeNotifier
    implements ValueListenable<double> {
  PageTabPosition(this.controller) {
    controller.addListener(notifyListeners);
  }

  final PageController controller;

  @override
  double get value {
    if (!controller.hasClients || controller.positions.length != 1) {
      return controller.initialPage.toDouble();
    }
    return controller.page ?? controller.initialPage.toDouble();
  }

  @override
  void dispose() {
    controller.removeListener(notifyListeners);
    super.dispose();
  }
}

/// Everything [Text] would resolve out of the enclosing context, captured once
/// so the mask copy can lay its glyphs out identically without being a [Text]
/// itself — see [_PillLabel] for why it must not be one.
@immutable
class _LabelPainting {
  const _LabelPainting({required this.style, required this.textScaler});

  factory _LabelPainting.of(BuildContext context) {
    final defaults = DefaultTextStyle.of(context);
    return _LabelPainting(
      style: defaults.style.merge(AppText.tabLabel),
      // Reading this here is deliberate: it is both what the mask copy needs
      // and the dependency that rebuilds the bar when the scale changes.
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

  final TextStyle style;
  final TextScaler textScaler;
}

/// The label row, built twice a frame — once as the real, interactive,
/// [AppColors.ink] row that owns the tap targets and is what the [GlobalKey]s
/// measure, once as the [AppColors.onSelection] row the sliding pill masks down
/// to its own bounds. Both go through this one widget, because the mask is only
/// correct while the two rows lay out identically.
class _TabRow<T> extends StatelessWidget {
  const _TabRow({
    required this.items,
    required this.painting,
    required this.textColor,
    this.pillKeys,
    this.selectedIndex,
    this.onSelected,
    this.mask = false,
  });

  final List<TabItem<T>> items;
  final _LabelPainting painting;
  final Color textColor;
  final List<GlobalKey>? pillKeys;
  final int? selectedIndex;
  final ValueChanged<T>? onSelected;
  final bool mask;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i != 0) const SizedBox(width: AppSpacing.x2),
          _PillLabel(
            key: pillKeys?[i],
            label: items[i].label,
            painting: painting,
            textColor: textColor,
            mask: mask,
            selected: selectedIndex == i,
            onPressed: onSelected == null
                ? null
                : () => onSelected!(items[i].value),
          ),
        ],
      ],
    );
  }
}

class _PillLabel extends StatelessWidget {
  const _PillLabel({
    required this.label,
    required this.painting,
    required this.textColor,
    required this.mask,
    required this.selected,
    this.onPressed,
    super.key,
  });

  final String label;
  final _LabelPainting painting;
  final Color textColor;
  final bool mask;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final style = painting.style.copyWith(color: textColor);
    // The mask copy paints through `RichText` instead of `Text` on purpose.
    // `find.text` matches `Text` widgets, so a second `Text` would make every
    // tab label match twice in any test that so much as builds a screen with
    // this bar in it. `Text` is a thin wrapper over `RichText`, so this paints
    // the same glyphs — as long as it is handed the same resolved style and
    // text scaler, which is what `_LabelPainting` is for.
    final Widget text = mask
        ? RichText(
            text: TextSpan(text: label, style: style),
            textScaler: painting.textScaler,
          )
        : Text(label, style: style);
    final content = Container(
      constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x6),
      child: text,
    );
    final onPressed = this.onPressed;
    if (onPressed == null) return content;
    return Semantics(
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.mdRadius,
          child: content,
        ),
      ),
    );
  }
}
