import 'package:flutter/material.dart';

import '../bodies/surface_capabilities.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// A named setting inside a section card: a title line, an explanation, and
/// whatever control operates it.
///
/// Promoted from `lib/screens_v2/settings/settings_pane.dart` so both the car
/// and the companion share one shape instead of private copies and ad-hoc
/// `Column`+`SizedBox` spacers. The companion `_MetricPill`/`_JourneyCard`
/// analogues were also replaced by `AppCard`+`StatColumn` combinations via
/// this shape.
class SettingsEntry extends StatelessWidget {
  const SettingsEntry({
    required this.title,
    required this.description,
    required this.child,
    super.key,
  });

  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppText.body.copyWith(color: colors.ink)),
        if (description.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.x1),
          Text(
            description,
            style: AppText.label.copyWith(color: colors.inkMuted),
          ),
        ],
        const SizedBox(height: AppSpacing.x3),
        child,
      ],
    );
  }
}

/// Stacks the sections of one pane with the grid gutter between them.
///
/// Kept for callers that need a plain vertical stack; the shared body prefers
/// [SettingsAdaptiveGrid] for viewport-reactive layout.
class SettingsSections extends StatelessWidget {
  const SettingsSections({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.gridGutter),
          children[i],
        ],
      ],
    );
  }
}

/// Stacks the rows inside one section card.
class SettingsRows extends StatelessWidget {
  const SettingsRows({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.x5),
          children[i],
        ],
      ],
    );
  }
}

/// Viewport-reactive grid for settings sections.
///
/// `compact` renders a single column. `medium` and `expanded` render a
/// two-column grid with [AppSpacing.gridGutter] between columns and rows.
/// Branching is on [SurfaceCapabilities.widthClass] only, never on `isCar`.
class SettingsAdaptiveGrid extends StatelessWidget {
  const SettingsAdaptiveGrid({
    required this.capabilities,
    required this.children,
    super.key,
  });

  final SurfaceCapabilities capabilities;
  final List<Widget> children;

  bool get _isSingleColumn =>
      capabilities.widthClass == SurfaceWidthClass.compact;

  @override
  Widget build(BuildContext context) {
    if (_isSingleColumn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.gridGutter),
            children[i],
          ],
        ],
      );
    }
    // Two-column grid for medium/expanded. Each child gets equal width;
    // rows are filled left-to-right, last row may have one child.
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      final left = children[i];
      final right = i + 1 < children.length ? children[i + 1] : null;
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: left),
              if (right != null) ...[
                const SizedBox(width: AppSpacing.gridGutter),
                Expanded(child: right),
              ] else
                const Spacer(),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.gridGutter),
          rows[i],
        ],
      ],
    );
  }
}
