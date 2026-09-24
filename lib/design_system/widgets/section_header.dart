import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// Caps section title with an optional leading accent icon, used to group
/// panels inside a screen (e.g. the settings sections).
class SectionHeader extends StatelessWidget {
  const SectionHeader({required this.label, this.icon, super.key});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, color: AutomotiveColors.secondary, size: 18),
          const SizedBox(width: AutomotiveSpacing.x1),
        ],
        Flexible(
          child: Text(
            label.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: AutomotiveColors.outline,
            ),
          ),
        ),
      ],
    );
  }
}
