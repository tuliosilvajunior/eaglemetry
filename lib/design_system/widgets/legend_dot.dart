import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// Chart legend entry: a small color swatch followed by a caps label.
class LegendDot extends StatelessWidget {
  const LegendDot({required this.color, required this.label, super.key});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, color: color),
        const SizedBox(width: AutomotiveSpacing.x0_5),
        Text(
          label,
          style: AutomotiveTextStyles.labelCaps.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}
