import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// Compact read-only chip showing a small caption label and a mono value.
///
/// Used in screen headers for counts such as stored rows or live writes.
class TechnicalChip extends StatelessWidget {
  const TechnicalChip({
    required this.label,
    required this.value,
    this.minHeight = 36,
    super.key,
  });

  final String label;
  final String value;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.x1_5,
        vertical: AutomotiveSpacing.x0_5,
      ),
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainerHigh,
        border: Border.all(color: AutomotiveColors.technicalBorder),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: AutomotiveColors.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x1),
          Text(
            value,
            style: AutomotiveTextStyles.unitLabel.copyWith(
              color: AutomotiveColors.secondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
