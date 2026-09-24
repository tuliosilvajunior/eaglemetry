import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// Outlined caps-label action button used in screen control bars.
///
/// Replaces the `_TechnicalButton` previously duplicated by the debug and
/// diagnostic screens. Set [accentIcon] to color the icon with the secondary
/// (active/positive) semantic color.
class TechnicalButton extends StatelessWidget {
  const TechnicalButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accentIcon = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool accentIcon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(
          icon,
          color: accentIcon
              ? AutomotiveColors.secondary
              : AutomotiveColors.onSurface,
          size: 18,
        ),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          backgroundColor: AutomotiveColors.surfaceContainerHighest,
          foregroundColor: AutomotiveColors.onSurface,
          side: BorderSide(color: AutomotiveColors.technicalBorder),
          padding: const EdgeInsets.symmetric(horizontal: AutomotiveSpacing.x2),
          textStyle: AutomotiveTextStyles.labelCaps,
        ),
      ),
    );
  }
}
