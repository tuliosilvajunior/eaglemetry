import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Filled grey action row inside a card (`Open charge port`, `Stop charging`).
///
/// Semantic color goes on the [icon] via [iconColor], never on the label or the
/// fill: a destructive action shows a `critical` glyph beside an `ink` label.
/// Tinting the whole row overstates the action and breaks the grey rhythm of
/// the card (see `DESIGN.md`).
///
/// When [onPressed] is null the tile renders disabled — the fill stays put and
/// both glyph and label drop to [AppColors.inkSubtle], which is what the
/// reference does for an unavailable action rather than hiding it.
class SoftActionTile extends StatelessWidget {
  const SoftActionTile({
    required this.label,
    required this.onPressed,
    this.icon,
    this.leading,
    this.iconColor,
    this.centered = false,
    this.selected = false,
    this.height = AppSizes.actionRowHeight,
    super.key,
  }) : assert(icon == null || leading == null);

  /// Localized label.
  final String label;

  final VoidCallback? onPressed;
  final IconData? icon;

  /// Custom leading glyph for symbols that are not in Flutter's [Icons] font.
  final Widget? leading;

  /// Overrides the glyph color. Use for semantic actions only.
  final Color? iconColor;

  /// Centers the content. Use for the narrow side-by-side variant
  /// (`Outlets` / `48 Amps`); leave false for full-width rows.
  final bool centered;

  /// Keeps the action on the dark selection fill. Use while a control opened
  /// by this action is visible, so the source of the floating surface remains
  /// clear.
  final bool selected;

  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final enabled = onPressed != null;
    final active = enabled && selected;
    final foreground = !enabled
        ? colors.inkSubtle
        : active
        ? colors.onSelection
        : colors.ink;
    final glyphColor = !enabled
        ? colors.inkSubtle
        : active
        ? colors.onSelection
        : (iconColor ?? colors.ink);

    return Material(
      color: active ? colors.selectionFill : colors.control,
      borderRadius: AppRadii.mdRadius,
      animationDuration: AppMotion.fast,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.mdRadius,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
            child: Row(
              mainAxisAlignment: centered
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
              children: [
                if (icon != null || leading != null) ...[
                  if (leading != null)
                    IconTheme(
                      data: IconThemeData(
                        size: AppSizes.iconMd,
                        color: glyphColor,
                      ),
                      child: leading!,
                    )
                  else
                    Icon(icon, size: AppSizes.iconMd, color: glyphColor),
                  const SizedBox(width: AppSpacing.x3),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: AppText.bodyStrong.copyWith(color: foreground),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
