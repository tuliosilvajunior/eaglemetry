import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Circular filled glyph that prefixes a card title to state what the card is
/// currently doing (`⚡ Charging`).
///
/// The badge is the only place a series color is allowed to fill a shape that
/// is not data: it reads as a status light, not as a selection.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    required this.icon,
    this.color,
    this.iconColor = AppColors.onSelection,
    super.key,
  });

  final IconData icon;

  /// Null takes the theme's gain hue, which is what a healthy status light is.
  final Color? color;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppSizes.statusBadge,
      height: AppSizes.statusBadge,
      decoration: BoxDecoration(
        color: color ?? AppThemeColors.of(context).energy.gain,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: AppSizes.iconSm, color: iconColor),
    );
  }
}
