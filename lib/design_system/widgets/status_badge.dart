import 'package:flutter/material.dart';

import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// Small status pill with a semantic color (active/warning/complete/fault).
///
/// Replaces the inline colored badge built in trip session cards. The color is
/// treated as a runtime semantic value, so the badge is intentionally not
/// created as a `const` widget.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    required this.label,
    required this.color,
    this.fontSize = 10,
    super.key,
  });

  final String label;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.x1,
        vertical: AutomotiveSpacing.x0_5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: AutomotiveTextStyles.labelCaps.copyWith(
          color: color,
          fontSize: fontSize,
        ),
      ),
    );
  }
}
