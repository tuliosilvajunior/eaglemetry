import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Circular info affordance in a card header.
///
/// Deliberately borderless and unfilled — it is the lowest-priority thing on
/// the card and should read as a glyph, not as a button.
class InfoIconButton extends StatelessWidget {
  const InfoIconButton({
    required this.onPressed,
    this.tooltip,
    this.selected = false,
    super.key,
  });

  final VoidCallback? onPressed;

  /// Screens must pass a localized string; the component never supplies copy.
  final String? tooltip;

  /// Uses the filled inverse state while an anchored information panel is
  /// open.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final enabled = onPressed != null;
    final button = SizedBox.square(
      dimension: AppSizes.minTouchTarget,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.fast,
              width: AppSizes.statusBadge,
              height: AppSizes.statusBadge,
              decoration: BoxDecoration(
                color: selected && enabled
                    ? colors.selectionFill
                    : AppColors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                selected ? Icons.info : Icons.info_outline,
                size: AppSizes.iconMd,
                color: !enabled
                    ? colors.inkSubtle
                    : selected
                    ? colors.onSelection
                    : colors.ink,
              ),
            ),
          ),
        ),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Filled square icon button used beside a metric (the range-unit swap).
///
/// Distinct from [InfoIconButton]: this one performs an action on the value
/// next to it, so it carries a [AppColors.control] fill to look pressable.
///
/// The fill is [AppSizes.squareIconButton] but the widget occupies — and
/// accepts touches across — [AppSizes.minTouchTarget], per the automotive
/// minimum in `DESIGN.md`.
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.selected = false,
    this.size = AppSizes.squareIconButton,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Side of the visible square. The hit target never shrinks below the
  /// automotive minimum, so a larger square grows the button and a smaller one
  /// only floats inside it.
  ///
  /// Pass `AppSizes.minTouchTarget` when the button stands beside the tab row:
  /// a pill is that tall, and a gear that is shorter reads as a smaller
  /// control rather than a peer of the tabs.
  final double size;

  /// Keeps the button on the selection fill while a floating surface it opened
  /// is visible, so the source of that surface stays clear.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final enabled = onPressed != null;
    final active = enabled && selected;
    final button = SizedBox.square(
      dimension: math.max(size, AppSizes.minTouchTarget),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.mdRadius,
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.fast,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: active ? colors.selectionFill : colors.control,
                borderRadius: AppRadii.mdRadius,
              ),
              child: Icon(
                icon,
                // The glyph keeps its share of the square, so a larger button
                // is a larger icon rather than the same icon with more space
                // around it.
                size: AppSizes.iconMd * size / AppSizes.squareIconButton,
                color: !enabled
                    ? colors.inkSubtle
                    : active
                    ? colors.onSelection
                    : colors.ink,
              ),
            ),
          ),
        ),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
