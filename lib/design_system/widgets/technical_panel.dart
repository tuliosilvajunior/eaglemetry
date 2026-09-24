import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';

/// Bordered technical surface used across automotive panels.
///
/// Replaces the repeated `Container` + `BoxDecoration` pattern built from
/// [AutomotiveColors.surfaceContainer], [AutomotiveColors.outlineVariant],
/// [AutomotiveRadii.lgRadius] and [AutomotiveSpacing.panelPadding].
class TechnicalPanel extends StatelessWidget {
  const TechnicalPanel({
    required this.child,
    this.padding = AutomotiveSpacing.panelPadding,
    this.color,
    this.borderColor,
    this.borderRadius,
    this.margin,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final BorderRadiusGeometry? borderRadius;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AutomotiveColors.surfaceContainer,
        border: Border.all(
          color: borderColor ?? AutomotiveColors.outlineVariant,
        ),
        borderRadius: borderRadius ?? AutomotiveRadii.lgRadius,
      ),
      child: child,
    );
  }
}
