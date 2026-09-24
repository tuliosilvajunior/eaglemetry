import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';

/// Horizontal control strip below a [ScreenHeaderBar]-style header, hosting
/// actions and filters. Scrolls horizontally so dense chrome never overflows
/// on narrow viewports.
///
/// Children are rendered as-is; callers control the gaps between them
/// (`x1` between related buttons, `x3` between groups).
class ControlsBar extends StatelessWidget {
  const ControlsBar({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.marginScreen,
        vertical: AutomotiveSpacing.unit,
      ),
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: AutomotiveColors.outlineVariant),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: children),
      ),
    );
  }
}
