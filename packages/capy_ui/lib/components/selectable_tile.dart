import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Two-line preset tile from a single-select group (`85%` / `Extended`).
///
/// Selected state inverts to [AppColors.selectionFill], which is the system's
/// one signal for "the user picked this". A preset is never marked selected
/// with a series color, even when the value it sets is charge related.
class SelectableTile extends StatelessWidget {
  const SelectableTile({
    required this.value,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.height = AppSizes.presetTileHeight,
    super.key,
  });

  /// Localized/formatted top line (`85%`, `--`).
  final String value;

  /// Localized bottom line (`Extended`).
  final String label;

  final bool selected;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final valueColor = selected ? colors.onSelection : colors.ink;
    final labelColor = selected ? colors.onSelection : colors.inkMuted;

    return Material(
      color: selected ? colors.selectionFill : colors.control,
      borderRadius: AppRadii.mdRadius,
      animationDuration: AppMotion.fast,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.mdRadius,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: AppText.bodyStrong.copyWith(color: valueColor),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.x1),
                Text(
                  label,
                  style: AppText.body.copyWith(color: labelColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
