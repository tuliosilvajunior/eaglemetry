import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// Label + value readout cell.
///
/// Matches the layout previously duplicated by `_MetricTile` in the trip
/// sessions screen. Use [accent] to color the value with the secondary
/// (active/positive) semantic color.
class MetricReadout extends StatelessWidget {
  const MetricReadout({
    required this.label,
    required this.value,
    this.accent = false,
    this.labelFontSize = 10,
    this.valueFontSize = 15,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    super.key,
  });

  final String label;
  final String value;
  final bool accent;
  final double labelFontSize;
  final double valueFontSize;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: AutomotiveTextStyles.labelCaps.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
            fontSize: labelFontSize,
          ),
        ),
        const SizedBox(height: AutomotiveSpacing.x0_5),
        Text(
          value,
          overflow: TextOverflow.ellipsis,
          style: AutomotiveTextStyles.unitLabel.copyWith(
            color: accent
                ? AutomotiveColors.secondary
                : AutomotiveColors.onSurface,
            fontSize: valueFontSize,
          ),
        ),
      ],
    );
  }
}
