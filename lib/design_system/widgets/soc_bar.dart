import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';

/// Horizontal battery/level bar from a 0..1 fraction.
///
/// Replaces the inline SoC bar in trip session cards. The fill color and track
/// are runtime values, so the widget is not `const`.
class SocBar extends StatelessWidget {
  const SocBar({
    required this.fraction,
    this.color,
    this.trackColor,
    this.height = 12,
    super.key,
  });

  final double fraction;
  final Color? color;
  final Color? trackColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fill = color ?? AutomotiveColors.secondary;
    final track = trackColor ?? AutomotiveColors.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: AutomotiveRadii.smRadius,
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: track),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0, 1),
              child: ColoredBox(color: fill),
            ),
          ],
        ),
      ),
    );
  }
}
