import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'floating_surface.dart';

/// Preferred side of the trigger that receives an anchored tooltip.
///
/// An explicit side flips when it cannot contain the complete panel and the
/// opposite side can. [auto] selects the side with more usable space.
enum AnchoredTooltipSide { auto, left, right }

typedef AnchoredTooltipTriggerBuilder =
    Widget Function(BuildContext context, bool isOpen, VoidCallback open);

/// Owns the anchor, modal route, and open state for a reusable tooltip.
///
/// The [builder] receives [isOpen] so the trigger can keep its selected visual
/// while the tooltip is visible. The source button and tooltip content stay
/// independent of this behavior layer.
class AnchoredTooltipTrigger extends StatefulWidget {
  const AnchoredTooltipTrigger({
    required this.builder,
    required this.tooltipBuilder,
    required this.barrierLabel,
    this.side = AnchoredTooltipSide.auto,
    this.caretAlignment = 0.5,
    this.anchorInsets = EdgeInsets.zero,
    super.key,
  }) : assert(caretAlignment >= 0 && caretAlignment <= 1);

  final AnchoredTooltipTriggerBuilder builder;
  final WidgetBuilder tooltipBuilder;
  final String barrierLabel;
  final AnchoredTooltipSide side;

  /// Preferred caret position from the top of the tooltip, from 0 to 1.
  /// The caret always targets the vertical center of the trigger itself.
  final double caretAlignment;

  /// Shrinks the trigger render box to its visible anchor. This keeps a 64px
  /// hit target while a smaller visual, such as a 32px info circle, receives
  /// the caret.
  final EdgeInsets anchorInsets;

  @override
  State<AnchoredTooltipTrigger> createState() => _AnchoredTooltipTriggerState();
}

class _AnchoredTooltipTriggerState extends State<AnchoredTooltipTrigger> {
  bool _isOpen = false;

  Future<void> _open(BuildContext anchorContext) async {
    if (_isOpen) return;
    setState(() => _isOpen = true);
    try {
      await showAnchoredTooltip(
        context: context,
        anchorContext: anchorContext,
        side: widget.side,
        caretAlignment: widget.caretAlignment,
        anchorInsets: widget.anchorInsets,
        barrierLabel: widget.barrierLabel,
        tooltipBuilder: widget.tooltipBuilder,
      );
    } finally {
      if (mounted) setState(() => _isOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (anchorContext) =>
          widget.builder(anchorContext, _isOpen, () => _open(anchorContext)),
    );
  }
}

/// Shows arbitrary tooltip content beside [anchorContext].
Future<void> showAnchoredTooltip({
  required BuildContext context,
  required BuildContext anchorContext,
  required WidgetBuilder tooltipBuilder,
  required String barrierLabel,
  AnchoredTooltipSide side = AnchoredTooltipSide.auto,
  double caretAlignment = 0.5,
  EdgeInsets anchorInsets = EdgeInsets.zero,
}) {
  assert(caretAlignment >= 0 && caretAlignment <= 1);

  final anchorBox = anchorContext.findRenderObject()! as RenderBox;
  assert(anchorInsets.horizontal < anchorBox.size.width);
  assert(anchorInsets.vertical < anchorBox.size.height);
  final renderRect = anchorBox.localToGlobal(Offset.zero) & anchorBox.size;
  final anchorRect = Rect.fromLTRB(
    renderRect.left + anchorInsets.left,
    renderRect.top + anchorInsets.top,
    renderRect.right - anchorInsets.right,
    renderRect.bottom - anchorInsets.bottom,
  );

  return showFloatingSurface<void>(
    context: context,
    barrierLabel: barrierLabel,
    pageBuilder: (context, animation, secondaryAnimation) {
      return _AnchoredTooltipOverlay(
        anchorRect: anchorRect,
        side: side,
        caretAlignment: caretAlignment,
        child: tooltipBuilder(context),
      );
    },
  );
}

/// Standard themed surface for content shown by [AnchoredTooltipTrigger].
class AnchoredTooltipSurface extends StatelessWidget {
  const AnchoredTooltipSurface({
    required this.child,
    this.width = AppSizes.anchoredTooltipWidth,
    this.height,
    super.key,
  });

  final Widget child;
  final double width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return SizedBox(
      key: const Key('anchored-tooltip-surface'),
      width: width,
      height: height,
      child: Material(
        color: colors.surface,
        borderRadius: AppRadii.mdRadius,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

class _AnchoredTooltipOverlay extends StatelessWidget {
  const _AnchoredTooltipOverlay({
    required this.anchorRect,
    required this.side,
    required this.caretAlignment,
    required this.child,
  });

  final Rect anchorRect;
  final AnchoredTooltipSide side;
  final double caretAlignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.paddingOf(context);
    return CustomMultiChildLayout(
      delegate: _AnchoredTooltipLayoutDelegate(
        anchorRect: anchorRect,
        preferredSide: side,
        caretAlignment: caretAlignment,
        safePadding: safePadding,
      ),
      children: [
        LayoutId(
          id: _TooltipSlot.leftCaret,
          child: _TooltipCaret(
            key: const Key('anchored-tooltip-caret-left'),
            pointsLeft: false,
          ),
        ),
        LayoutId(
          id: _TooltipSlot.rightCaret,
          child: _TooltipCaret(
            key: const Key('anchored-tooltip-caret-right'),
            pointsLeft: true,
          ),
        ),
        LayoutId(id: _TooltipSlot.panel, child: child),
      ],
    );
  }
}

enum _TooltipSlot { leftCaret, rightCaret, panel }

class _AnchoredTooltipLayoutDelegate extends MultiChildLayoutDelegate {
  _AnchoredTooltipLayoutDelegate({
    required this.anchorRect,
    required this.preferredSide,
    required this.caretAlignment,
    required this.safePadding,
  });

  final Rect anchorRect;
  final AnchoredTooltipSide preferredSide;
  final double caretAlignment;
  final EdgeInsets safePadding;

  @override
  void performLayout(Size size) {
    final panelSize = layoutChild(
      _TooltipSlot.panel,
      BoxConstraints(
        maxWidth: (size.width - safePadding.horizontal - AppSpacing.x12).clamp(
          0.0,
          double.infinity,
        ),
        maxHeight: (size.height - safePadding.vertical - AppSpacing.x12).clamp(
          0.0,
          double.infinity,
        ),
      ),
    );
    final leftCaretSize = layoutChild(
      _TooltipSlot.leftCaret,
      const BoxConstraints.tightFor(
        width: AppSizes.anchoredTooltipCaret,
        height: AppSizes.anchoredTooltipCaret,
      ),
    );
    final rightCaretSize = layoutChild(
      _TooltipSlot.rightCaret,
      const BoxConstraints.tightFor(
        width: AppSizes.anchoredTooltipCaret,
        height: AppSizes.anchoredTooltipCaret,
      ),
    );
    final minLeft = safePadding.left + AppSpacing.screenPadding.left;
    final maxRight =
        size.width - safePadding.right - AppSpacing.screenPadding.right;
    final minTop = safePadding.top + AppSpacing.screenPadding.top;
    final maxBottom =
        size.height - safePadding.bottom - AppSpacing.screenPadding.bottom;
    const caretReach =
        AppSizes.anchoredTooltipCaret - AppSizes.anchoredTooltipCaretOverlap;
    final availableLeft = anchorRect.left - caretReach - minLeft;
    final availableRight = maxRight - anchorRect.right - caretReach;
    final side = _resolveSide(
      panelWidth: panelSize.width,
      availableLeft: availableLeft,
      availableRight: availableRight,
    );
    final desiredLeft = switch (side) {
      AnchoredTooltipSide.left =>
        anchorRect.left - caretReach - panelSize.width,
      AnchoredTooltipSide.right => anchorRect.right + caretReach,
      AnchoredTooltipSide.auto => throw StateError('auto must resolve'),
    };
    final left = desiredLeft
        .clamp(minLeft, maxRight - panelSize.width)
        .toDouble();
    final preferredCaret = (panelSize.height * caretAlignment)
        .clamp(
          AppRadii.md + AppSizes.anchoredTooltipCaret / 2,
          panelSize.height - AppRadii.md - AppSizes.anchoredTooltipCaret / 2,
        )
        .toDouble();
    final desiredTop = anchorRect.center.dy - preferredCaret;
    final top = desiredTop
        .clamp(minTop, maxBottom - panelSize.height)
        .toDouble();
    positionChild(_TooltipSlot.panel, Offset(left, top));

    final caretSize = side == AnchoredTooltipSide.left
        ? leftCaretSize
        : rightCaretSize;
    final caretLeft = switch (side) {
      AnchoredTooltipSide.left => left + panelSize.width,
      AnchoredTooltipSide.right => left - caretSize.width,
      AnchoredTooltipSide.auto => throw StateError('auto must resolve'),
    };
    final minCaretCenter = top + AppRadii.md + caretSize.height / 2;
    final maxCaretCenter =
        top + panelSize.height - AppRadii.md - caretSize.height / 2;
    final caretCenter = anchorRect.center.dy
        .clamp(minCaretCenter, maxCaretCenter)
        .toDouble();
    final activeCaret = side == AnchoredTooltipSide.left
        ? _TooltipSlot.leftCaret
        : _TooltipSlot.rightCaret;
    final inactiveCaret = side == AnchoredTooltipSide.left
        ? _TooltipSlot.rightCaret
        : _TooltipSlot.leftCaret;
    positionChild(
      activeCaret,
      Offset(caretLeft, caretCenter - caretSize.height / 2),
    );
    positionChild(inactiveCaret, Offset(-size.width, -size.height));
  }

  AnchoredTooltipSide _resolveSide({
    required double panelWidth,
    required double availableLeft,
    required double availableRight,
  }) {
    final leftFits = availableLeft >= panelWidth;
    final rightFits = availableRight >= panelWidth;

    return switch (preferredSide) {
      AnchoredTooltipSide.auto =>
        availableRight >= availableLeft
            ? AnchoredTooltipSide.right
            : AnchoredTooltipSide.left,
      AnchoredTooltipSide.left when !leftFits && rightFits =>
        AnchoredTooltipSide.right,
      AnchoredTooltipSide.right when !rightFits && leftFits =>
        AnchoredTooltipSide.left,
      _ => preferredSide,
    };
  }

  @override
  bool shouldRelayout(_AnchoredTooltipLayoutDelegate oldDelegate) {
    return anchorRect != oldDelegate.anchorRect ||
        preferredSide != oldDelegate.preferredSide ||
        caretAlignment != oldDelegate.caretAlignment ||
        safePadding != oldDelegate.safePadding;
  }
}

class _TooltipCaret extends StatelessWidget {
  const _TooltipCaret({required this.pointsLeft, super.key});

  final bool pointsLeft;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return ClipPath(
      clipper: _HorizontalCaretClipper(pointsLeft: pointsLeft),
      child: ColoredBox(
        color: colors.surface,
        child: const SizedBox.square(dimension: AppSizes.anchoredTooltipCaret),
      ),
    );
  }
}

class _HorizontalCaretClipper extends CustomClipper<Path> {
  const _HorizontalCaretClipper({required this.pointsLeft});

  final bool pointsLeft;

  @override
  Path getClip(Size size) {
    if (pointsLeft) {
      return Path()
        ..moveTo(size.width, 0)
        ..lineTo(0, size.height / 2)
        ..lineTo(size.width, size.height)
        ..close();
    }
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_HorizontalCaretClipper oldClipper) =>
      oldClipper.pointsLeft != pointsLeft;
}
